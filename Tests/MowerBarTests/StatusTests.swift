import XCTest
@testable import MowerBar

final class StatusTests: XCTestCase {
    private func mower(_ json: String, online: Int = 1) throws -> MowerState {
        let detail = try JSONDecoder().decode(DeviceDetail.self, from: Data(json.utf8))
        return MowerState(info: DeviceInfo(id: "test-mower", name: "Test mower", nickname: nil,
                                          model: "Luba2AWD3000", online: online), detail: detail)
    }

    func testLiveMowingResponseRestoresWorkingStateAndCommands() throws {
        // Sanitized shape observed from a Luba 2 on 2026-09-30.
        let response = try JSONDecoder().decode(APIResponse<DeviceDetail>.self, from: Data("""
        {"code":0,"msg":"Request success","data":{
          "id":"test-mower","model":"Luba2AWD3000","version":"1.30.29.26",
          "online":1,"status":"Mowing","batteryLevel":93,"chargeStatus":0,
          "network":{"usedNetwork":"1","wifiAvailable":true,"wifiRssi":-78,
                     "cellularAvailable":true,"cellularRssi":-75}
        }}
        """.utf8))
        let state = MowerState(info: DeviceInfo(id: "test-mower", name: "Test mower", nickname: nil,
                                               model: nil, online: 1), detail: try XCTUnwrap(response.data))
        XCTAssertEqual(state.status, .working)
        XCTAssertEqual(state.summary, "Working · 93%")
        XCTAssertEqual(state.health, .active)
        XCTAssertEqual(state.availableActions, [.pause, .stop, .returnToDock])
        XCTAssertFalse(state.allows(.cmdStart))
        XCTAssertNil(state.statusDiagnostic)
        XCTAssertEqual(state.dockLabel, "Off dock")
        XCTAssertEqual(state.detail?.network?.lines.count, 2)
    }

    func testStatusAliasesAndLegacyValues() {
        for raw in ["Mowing", "mowing", " MOWING\n", "Working", "WORKING"] {
            XCTAssertEqual(MowerStatus(raw), .working, raw)
        }
        for raw in ["Standby", "StandBy", " standby "] {
            XCTAssertEqual(MowerStatus(raw), .standby, raw)
        }
        for raw in ["TaskPaused", "taskpaused", " TASKPAUSED\n", "Paused"] {
            XCTAssertEqual(MowerStatus(raw), .paused, raw)
        }
        for status in [MowerStatus.paused, .mapping, .updating, .offline, .returning, .abnormal] {
            XCTAssertEqual(MowerStatus(status.label), status)
        }
        for raw in [nil, "", " \n", "NewFutureState"] {
            XCTAssertEqual(MowerStatus(raw), .unknown)
        }
    }

    func testOfflineResponseWithoutTelemetry() throws {
        let state = try mower(#"{"id":"test-mower","model":"Luba2AWD3000","online":0}"#)
        XCTAssertFalse(state.isOnline)
        XCTAssertFalse(state.isRemembered)
        XCTAssertEqual(state.status, .offline)
        XCTAssertEqual(state.summary, "Offline")
        XCTAssertEqual(state.health, .alert)
        XCTAssertNil(state.battery)
        XCTAssertEqual(state.dockLabel, "Dock state unavailable")
        XCTAssertTrue(state.availableActions.isEmpty)
    }

    func testOfflineFlagOverridesStaleWorkingTelemetry() throws {
        let state = try mower(#"{"id":"test-mower","online":0,"status":"Mowing","chargeStatus":1}"#)
        XCTAssertEqual(state.status, .offline)
        XCTAssertFalse(state.isCharging)
        XCTAssertTrue(state.availableActions.isEmpty)
        XCTAssertEqual(state.dockLabel, "Dock state unavailable")
    }

    func testOnlineWithMissingStatusStaysVisibleAsUnavailable() throws {
        let state = try mower(#"{"id":"test-mower","online":1,"batteryLevel":72}"#)
        XCTAssertTrue(state.isOnline)
        XCTAssertEqual(state.summary, "Status unavailable · 72%")
        XCTAssertEqual(state.health, .alert)
        XCTAssertEqual(state.statusDiagnostic, "Mower status was not returned")
        XCTAssertTrue(state.availableActions.isEmpty)
    }

    func testFutureStatusIsExposedWithoutEnablingCommands() throws {
        let state = try mower(#"{"id":"test-mower","online":1,"status":"EdgeCruising","batteryLevel":72}"#)
        XCTAssertEqual(state.status, .unknown)
        XCTAssertEqual(state.statusDiagnostic, "Unrecognized mower status: EdgeCruising")
        XCTAssertTrue(state.detailLines.contains("Unrecognized mower status: EdgeCruising"))
        XCTAssertEqual(state.health, .alert)
        XCTAssertFalse(state.allows(.resume))
        XCTAssertFalse(state.allows(.start, taskName: "Lawn"))
    }

    func testPausedOnDockIsChargingWithoutStallAlert() throws {
        for charge in [1, 2] {
            let state = try mower("""
            {"id":"test-mower","online":1,"status":"Paused","batteryLevel":17,"chargeStatus":\(charge)}
            """)
            XCTAssertTrue(state.isCharging)
            XCTAssertFalse(state.isStalled)
            XCTAssertEqual(state.stateLabel, "Charging")
            XCTAssertEqual(state.health, .charging)
            XCTAssertEqual(state.availableActions, [.resume, .stop])
        }
    }

    func testFullBatteryOnDock() throws {
        let state = try mower(#"{"id":"test-mower","online":1,"status":"Paused","batteryLevel":100,"chargeStatus":2}"#)
        XCTAssertEqual(state.stateLabel, "Docked")
    }

    func testTaskPausedAliasPreservesDockAndStallBehavior() throws {
        for charge in [0, 1, 2] {
            let state = try mower("""
            {"id":"test-mower","online":1,"status":"TaskPaused","batteryLevel":17,"chargeStatus":\(charge)}
            """)
            XCTAssertEqual(state.status, .paused)
            XCTAssertTrue(state.allows(.resume))
            XCTAssertFalse(state.allows(.cmdStart))
            XCTAssertEqual(state.isStalled, charge == 0)
            XCTAssertEqual(state.isCharging, charge != 0)
            XCTAssertEqual(state.health, charge == 0 ? .alert : .charging)
            let event = MowerEvent.between(MowerSnapshot(status: .working, charging: false),
                                          state.snapshot, mower: state)
            if charge == 0 {
                guard case .problem = event else { return XCTFail("TaskPaused off dock must notify") }
            } else {
                XCTAssertNil(event)
            }
        }
    }

    func testPausedOffDockStillAlerts() throws {
        let state = try mower(#"{"id":"test-mower","online":1,"status":"Paused","batteryLevel":50,"chargeStatus":0}"#)
        XCTAssertTrue(state.isStalled)
        XCTAssertEqual(state.health, .alert)
        XCTAssertEqual(state.availableActions, [.resume, .stop, .returnToDock])
        guard case .problem = MowerEvent.between(MowerSnapshot(status: .working, charging: false),
                                                 state.snapshot, mower: state) else {
            return XCTFail("A working mower pausing off dock must still notify")
        }
    }

    func testUnavailableStatusDoesNotAnnounceRecovery() throws {
        let state = try mower(#"{"id":"test-mower","online":1,"status":"FutureState"}"#)
        for status in [MowerStatus.paused, .offline, .abnormal] {
            XCTAssertNil(MowerEvent.between(MowerSnapshot(status: status, charging: false),
                                           state.snapshot, mower: state))
        }
    }

    func testMowingRecoveryAndChargingTransitions() throws {
        let working = try mower(#"{"id":"test-mower","online":1,"status":"Mowing","chargeStatus":0}"#)
        guard case .recovery = MowerEvent.between(MowerSnapshot(status: .paused, charging: false),
                                                  working.snapshot, mower: working) else {
            return XCTFail("Resuming mowing must count as recovery")
        }
        let charging = try mower(#"{"id":"test-mower","online":1,"status":"Paused","chargeStatus":2}"#)
        XCTAssertNil(MowerEvent.between(working.snapshot, charging.snapshot, mower: charging))
    }

    func testRememberedMowingAliasAndActionGating() {
        let record = RememberedMower(id: "test-mower", lastSeen: Date(), lastStatus: "Mowing",
                                    lastBattery: 64, lastStateAt: Date())
        let state = MowerState(info: DeviceInfo(id: record.id, name: "Test mower", nickname: nil,
                                               model: nil, online: 0), remembered: record)
        XCTAssertEqual(state.summary, "Working · 64% · last known")
        XCTAssertEqual(state.health, .alert)
        XCTAssertFalse(state.allows(.pause))
    }

    func testSavedTasksAndURLCommandsFollowSameRules() throws {
        var state = try mower(#"{"id":"test-mower","online":1,"status":"StandBy","chargeStatus":0}"#)
        state.tasks = [WorkTask(taskId: "1", taskName: "Lawn")]
        XCTAssertTrue(state.allows(.cmdStart))
        XCTAssertTrue(state.allows(.start, taskName: "Lawn"))
        XCTAssertFalse(state.allows(.start, taskName: "Missing plan"))
        XCTAssertFalse(state.allows(.start))
        XCTAssertFalse(state.allows(.pause))
        state.error = "Detail request failed"
        XCTAssertFalse(state.allows(.cmdStart))
        XCTAssertFalse(state.allows(.start, taskName: "Lawn"))
    }

    func testRTKFilteringUsesModelNotStatusPresence() {
        for model in ["RTK", "Luba2 RTK", "RefStation"] {
            XCTAssertFalse(DeviceInfo(id: "base", name: nil, nickname: nil, model: model, online: 1).looksLikeMower)
        }
        XCTAssertTrue(DeviceInfo(id: "mower", name: nil, nickname: nil, model: "Luba2AWD3000", online: 0).looksLikeMower)
    }

    func testOptionalWifiAddressAndExistingSignals() throws {
        let network = try JSONDecoder().decode(DeviceNetwork.self, from: Data(#"{"usedNetwork":"1","wifiAvailable":true,"wifiRssi":-70,"wifiIp":"192.168.1.100"}"#.utf8))
        XCTAssertEqual(network.lines, ["Wi‑Fi -70 dBm · 50%  (in use)", "Wi‑Fi IP: 192.168.1.100"])
        let empty = try JSONDecoder().decode(DeviceNetwork.self, from: Data(#"{"wifiIp":" "}"#.utf8))
        XCTAssertTrue(empty.lines.isEmpty)
    }
}
