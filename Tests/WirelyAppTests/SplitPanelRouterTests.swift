import Testing
@testable import WirelyApp

@MainActor
struct SplitPanelRouterTests {
    @Test func panelStartsClosedAndIsNotPersisted() {
        #expect(AppRouter(defaults: nil).splitPanel == false)
    }

    @Test func openingSettingsClosesPanel() {
        let router = AppRouter(defaults: nil)
        router.splitPanel = true
        router.openSettings(.general)
        #expect(router.splitPanel == false)
    }

    @Test func switchingToDevicesClosesPanel() {
        let router = AppRouter(defaults: nil)
        router.splitPanel = true
        router.mode = .devices
        #expect(router.splitPanel == false)
    }
}
