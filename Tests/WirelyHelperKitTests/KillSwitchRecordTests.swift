import Testing
import Foundation
@testable import WirelyHelperKit
@testable import WirelyCore

@Test func killSwitchRecordDecodesWithoutSplitTable() throws {
    let old = #"{"token":"42","allowLAN":true,"endpoints":[{"host":"203.0.113.5","port":51820}]}"#
    let record = try JSONDecoder().decode(KillSwitchRecord.self, from: Data(old.utf8))
    #expect(record == KillSwitchRecord(token: "42", allowLAN: true, endpoints: [Endpoint(host: "203.0.113.5", port: 51820)]))
    #expect(record.splitTable == nil)
}

@Test func killSwitchRecordSplitTableRoundTrips() throws {
    let record = KillSwitchRecord(token: nil, allowLAN: false, endpoints: [], splitTable: ["198.51.100.9", "10.8.0.0/16"])
    let back = try JSONDecoder().decode(KillSwitchRecord.self, from: JSONEncoder().encode(record))
    #expect(back == record)
}

@Test func persistedStateWithOldKillSwitchStillDecodes() throws {
    let json = """
    {"tunnelName":"home","interface":"utun5","endpointRoutes":[],"dnsBackups":[],"dnsServers":[],"dnsSearch":[],
     "connectedAt":0,"ignoredKeys":[],"killSwitch":{"allowLAN":true,"endpoints":[]}}
    """
    let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
    #expect(state.killSwitch?.splitTable == nil)
    #expect(state.killSwitch?.allowLAN == true)
}

@Test func killSwitchRecordSplitExcludeRoundTripsAndOldRecordsDecode() throws {
    let old = #"{"token":"42","allowLAN":true,"endpoints":[],"splitTable":["198.51.100.9"]}"#
    let oldRecord = try JSONDecoder().decode(KillSwitchRecord.self, from: Data(old.utf8))
    #expect(oldRecord.splitExclude == nil)
    let record = KillSwitchRecord(token: nil, allowLAN: false, endpoints: [], splitTable: ["198.51.100.9"], splitExclude: true)
    let back = try JSONDecoder().decode(KillSwitchRecord.self, from: JSONEncoder().encode(record))
    #expect(back == record && back.splitExclude == true)
}
