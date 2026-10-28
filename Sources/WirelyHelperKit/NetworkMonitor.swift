import Foundation
import SystemConfiguration
import WirelyCore

/// Fires `onChange` (on `queue`) when the system's global network state changes.
/// SCDynamicStore events are debounced 1 s; a 10 s fallback timer fires only when default routes changed.
public final class NetworkMonitor {
    private let queue: DispatchQueue
    private let runner: CommandRunner
    private let onChange: () -> Void

    private var store: SCDynamicStore?
    private var debounce: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var lastRoutes: [String]?

    public init(queue: DispatchQueue, runner: CommandRunner, onChange: @escaping () -> Void) {
        self.queue = queue
        self.runner = runner
        self.onChange = onChange
    }

    public func start() {
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().storeChanged()
        }
        if let s = SCDynamicStoreCreate(nil, "wirely-helper" as CFString, callback, &context) {
            let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
            SCDynamicStoreSetNotificationKeys(s, keys, nil)
            if let source = SCDynamicStoreCreateRunLoopSource(nil, s, 0) {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            store = s
        }

        queue.async { [self] in lastRoutes = currentRoutes() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    // Runs on the main run loop.
    private func storeChanged() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.debounce === item, !item.isCancelled else { return }
            self.queue.async(execute: item)
        }
    }

    // Runs on `queue`.
    private func tick() {
        let now = currentRoutes()
        defer { lastRoutes = now }
        guard let last = lastRoutes, last != now else { return }
        onChange()
    }

    private func currentRoutes() -> [String] {
        [NetPlan.netstatCommand(.v4), NetPlan.netstatCommand(.v6)].map { cmd in
            let r = NetPlan.parseDefaultRoute(netstat: runner.run(cmd).stdout)
            return "\(r.gateway ?? "-")%\(r.interface ?? "-")"
        }
    }
}
