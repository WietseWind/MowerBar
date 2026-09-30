import AppKit
import XCTest
@testable import MowerBar

final class RecentEventsTests: XCTestCase {
    private func event(code: Int = 1005, milliseconds: Double? = 1_790_769_305_687) -> MowerHistoryEvent {
        MowerHistoryEvent(code: code, implication: "The battery is too low",
                          solution: "The robot will resume after charging.",
                          gmtCreate: milliseconds, createTime: nil)
    }

    func testDecodesRealResponseShapeIncludingNullSeverity() throws {
        let response = try JSONDecoder().decode(APIResponse<MowerHistoryPage>.self, from: Data("""
        {"code":0,"data":{"records":[
          {"code":1005,"implication":"The battery is too low",
           "solution":"The robot will resume after charging.",
           "gmtCreate":1790769305687,"createTime":1790769305820,
           "faultLevel":null,"priority":null,"imageList":[],"videoList":[]}
        ],"total":5,"pageNumber":1,"pageSize":10,"hasMore":false}}
        """.utf8))
        let record = try XCTUnwrap(response.data?.records.first)
        XCTAssertEqual(record.code, 1005)
        XCTAssertEqual(try XCTUnwrap(record.date).timeIntervalSince1970, 1_790_769_305.687, accuracy: 0.001)
        XCTAssertEqual(record.advice, "The robot will resume after charging.")
        XCTAssertTrue(record.details.contains("Event code: 1005"))
    }

    func testMissingFieldsAndTimestampFallback() throws {
        let json = #"{"code":1300,"implication":" \n ","solution":null,"gmtCreate":0,"createTime":1790769305820}"#
        let record = try JSONDecoder().decode(MowerHistoryEvent.self, from: Data(json.utf8))
        XCTAssertEqual(record.explanation, "Mower event 1300")
        XCTAssertNil(record.advice)
        XCTAssertEqual(try XCTUnwrap(record.date).timeIntervalSince1970, 1_790_769_305.820, accuracy: 0.001)
        let empty = try JSONDecoder().decode(MowerHistoryEvent.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.explanation, "Mower event")
        XCTAssertEqual(empty.timestamp, "Time unavailable")
        XCTAssertNil(empty.date)
    }

    func testLongMultilineExplanationIsOnlyShortenedInMenu() {
        let explanation = "Robot is outside the task area\nor inside a no-go zone and cannot continue mowing."
        let record = MowerHistoryEvent(code: 1100, implication: explanation,
                                      solution: "  Move the robot to a mowable area.\n\nThen try again.  ",
                                      gmtCreate: nil, createTime: nil)
        XCTAssertTrue(record.menuTitle.hasSuffix("…"))
        XCTAssertFalse(record.menuTitle.contains("\n"))
        XCTAssertEqual(record.explanation, explanation)
        XCTAssertEqual(record.advice, "Move the robot to a mowable area.\n\nThen try again.")
    }

    func testSearchBodyUsesLocalCalendarDaysAcrossDST() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-26T00:30:00Z"))
        let query = RecentEventsQuery(deviceId: "offline-mower", now: now,
                                      timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam")))
        let data = try JSONEncoder().encode(query)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["deviceId"] as? String, "offline-mower")
        XCTAssertEqual(body["pageNumber"] as? Int, 1)
        XCTAssertEqual(body["pageSize"] as? Int, 10)
        XCTAssertEqual(body["startDate"] as? String, "2026-09-27")
        XCTAssertEqual(body["endDate"] as? String, "2026-10-26")
    }

    @MainActor
    func testNewestFirstWithLimitAndMissingTimesLast() async {
        let records = (1...12).map { event(code: $0, milliseconds: Double($0 * 1000)) }
        let history = RecentEventsHistory { [self] in [event(milliseconds: nil)] + records }
        await history.refresh()
        XCTAssertEqual(history.events.compactMap(\.code), Array((3...12).reversed()))
        XCTAssertNotNil(history.lastUpdate)
        XCTAssertNil(history.error)
        XCTAssertFalse(history.isLoading)
    }

    @MainActor
    func testCacheExpiresAfterFiveMinutesAndManualRefreshBypassesIt() async {
        var requests = 0
        let history = RecentEventsHistory { requests += 1; return [] }
        let now = Date()
        await history.refresh(now: now)
        await history.refresh(now: now.addingTimeInterval(299))
        XCTAssertEqual(requests, 1)
        await history.refresh(now: now.addingTimeInterval(300))
        XCTAssertEqual(requests, 2)
        await history.refresh(force: true, now: now.addingTimeInterval(301))
        XCTAssertEqual(requests, 3)
    }

    @MainActor
    func testFailedRefreshKeepsLastGoodRecordsAndCanRecover() async {
        var fail = false
        var records = [event()]
        let history = RecentEventsHistory {
            if fail { throw APIError.api(code: 40200, message: "History unavailable") }
            return records
        }
        let now = Date()
        await history.refresh(now: now)
        fail = true
        await history.refresh(force: true, now: now.addingTimeInterval(10))
        XCTAssertEqual(history.events, records)
        XCTAssertEqual(history.lastUpdate, now)
        XCTAssertEqual(history.error, "History unavailable")
        XCTAssertFalse(history.isLoading)
        fail = false
        records = []
        await history.refresh(force: true, now: now.addingTimeInterval(20))
        XCTAssertTrue(history.events.isEmpty)
        XCTAssertNil(history.error)
        XCTAssertEqual(history.lastUpdate, now.addingTimeInterval(20))
    }

    @MainActor
    func testFailuresAreThrottledAndNotPresentedAsEmptyHistory() async {
        var requests = 0
        let history = RecentEventsHistory {
            requests += 1
            throw APIError.http(503)
        }
        let now = Date()
        await history.refresh(now: now)
        await history.refresh(now: now.addingTimeInterval(1))
        XCTAssertEqual(requests, 1)
        XCTAssertNil(history.lastUpdate)
        XCTAssertNotNil(history.error)
        let view = RecentEventsMenu(mowerName: "Test mower", history: history)
        XCTAssertTrue(view.menu.items.contains { $0.title == "Could not refresh events" })
        XCTAssertFalse(view.menu.items.contains { $0.title == "No events in the last 30 days" })
    }

    @MainActor
    func testConcurrentOpensDoNotDuplicateRequest() async {
        let started = expectation(description: "history request started")
        var requests = 0
        var pending: CheckedContinuation<[MowerHistoryEvent], Error>?
        let history = RecentEventsHistory {
            requests += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let first = Task { await history.refresh() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(history.isLoading)
        await history.refresh(force: true)
        XCTAssertEqual(requests, 1)
        pending?.resume(returning: [event()])
        await first.value
        XCTAssertFalse(history.isLoading)
        XCTAssertEqual(history.events.count, 1)
    }

    @MainActor
    func testHistoryIsLazyAndRefreshPreservesParentSubmenu() async {
        var requests = 0
        let record = event()
        let history = RecentEventsHistory { requests += 1; return [record] }
        let view = RecentEventsMenu(mowerName: "Test mower", history: history)
        let parent = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
        parent.submenu = view.menu
        XCTAssertEqual(requests, 0)
        await history.refresh()
        XCTAssertTrue(parent.submenu === view.menu)
        let rows = view.menu.items.filter { $0.representedObject is MowerHistoryEvent }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.representedObject as? MowerHistoryEvent, record)
        XCTAssertTrue(rows.first?.isEnabled == true)
    }

    @MainActor
    func testEmptyHistoryGetsAnExplicitEmptyState() async {
        let history = RecentEventsHistory { [] }
        let view = RecentEventsMenu(mowerName: "Test mower", history: history)
        await history.refresh()
        XCTAssertTrue(view.menu.items.contains { $0.title == "No events in the last 30 days" })
        XCTAssertFalse(view.menu.items.contains { $0.title == "Loading recent events…" })
    }
}
