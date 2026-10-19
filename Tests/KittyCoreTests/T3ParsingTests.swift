import XCTest
@testable import KittyCore

private func fullRecord(_ payload: [UInt8]) -> [UInt8] {
    let length = payload.count
    var out: [UInt8] = [0, 0, 0, 0, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), 1]
    out.append(contentsOf: payload)
    return out
}

final class T3ParsingTests: XCTestCase {

    // MARK: - Low-level utilities

    func testFindMatchesNeedle() {
        let haystack = Array("xxneedleXy".utf8)
        XCTAssertEqual(T3Parsing.find(haystack, Array("needle".utf8)), 2)
        XCTAssertNil(T3Parsing.find(haystack, Array("absent".utf8)))
        XCTAssertNil(T3Parsing.find([], [1]))
    }

    func testJsonObjectBytesHandlesNestingAndEscapes() {
        let text = #"prefix {"a":{"b":"x\"y}z"},"c":1}" suffix"#
        let bytes = Array(text.utf8)
        let expected = Array(#"{"a":{"b":"x\"y}z"},"c":1}"#.utf8)
        XCTAssertEqual(T3Parsing.jsonObjectBytes(bytes), expected)
        XCTAssertNil(T3Parsing.jsonObjectBytes(Array("no braces".utf8)))
        XCTAssertNil(T3Parsing.jsonObjectBytes(Array(#"{"open": 1"#.utf8)))
    }

    // MARK: - LevelDB framing

    func testLogicalRecordsWithFullRecords() {
        var bytes = fullRecord(Array("hello".utf8))
        bytes.append(contentsOf: fullRecord(Array("world".utf8)))
        let records = T3Parsing.logicalRecords(bytes)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0], Array("hello".utf8))
        XCTAssertEqual(records[1], Array("world".utf8))
    }

    func testLogicalRecordsReassemblesFragmentedRecord() {
        let blockSize = 32768
        let partA = [UInt8](repeating: 0x41, count: blockSize - 7)
        let partB = [UInt8](repeating: 0x42, count: 10)

        var bytes: [UInt8] = [0, 0, 0, 0, UInt8(partA.count & 0xFF), UInt8((partA.count >> 8) & 0xFF), 2]
        bytes.append(contentsOf: partA)
        bytes.append(contentsOf: [0, 0, 0, 0, UInt8(partB.count & 0xFF), UInt8((partB.count >> 8) & 0xFF), 4])
        bytes.append(contentsOf: partB)

        let records = T3Parsing.logicalRecords(bytes)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].count, partA.count + partB.count)
    }

    func testLogicalRecordsStopsAtZeroPadding() {
        var bytes = fullRecord(Array("real".utf8))
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0])
        bytes.append(contentsOf: Array("junk".utf8))
        let records = T3Parsing.logicalRecords(bytes)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0], Array("real".utf8))
    }

    // MARK: - Sanitization

    func testCleanStripsInvisibleCharacters() {
        XCTAssertEqual(T3Parsing.clean("Fix \u{202E}rm issue"), "Fix rm issue")
        XCTAssertEqual(T3Parsing.clean("bell\u{0007}case"), "bellcase")
        XCTAssertEqual(T3Parsing.clean("soft\u{00AD}hyphen"), "softhyphen")
        XCTAssertEqual(T3Parsing.clean("bom\u{FEFF}end"), "bomend")
        XCTAssertEqual(T3Parsing.clean(" isolate \u{2066}test\u{2069} "), "isolate test")
    }

    func testCleanKeepsUsefulWhitespaceAndZWJ() {
        XCTAssertEqual(T3Parsing.clean("line1\nline2\rline3"), "line1 line2 line3")
        XCTAssertEqual(T3Parsing.clean("family 👨\u{200D}👩\u{200D}👧"), "family 👨\u{200D}👩\u{200D}👧")
        XCTAssertEqual(T3Parsing.clean("tab\tinside"), "tab\tinside")
        XCTAssertEqual(T3Parsing.clean("  padded  "), "padded")
    }

    // MARK: - Dates and snooze

    func testParseDate() {
        XCTAssertNotNil(T3Parsing.parseDate("2026-01-01T00:00:00.123Z"))
        XCTAssertNotNil(T3Parsing.parseDate("2026-01-01T00:00:00Z"))
        XCTAssertNil(T3Parsing.parseDate(""))
        XCTAssertNil(T3Parsing.parseDate("not-a-date"))
        XCTAssertNil(T3Parsing.parseDate(nil))
    }

    func testIsSnoozed() {
        XCTAssertTrue(T3Parsing.isSnoozed("2999-01-01T00:00:00Z"))
        XCTAssertFalse(T3Parsing.isSnoozed("2001-01-01T00:00:00Z"))
        XCTAssertFalse(T3Parsing.isSnoozed(nil))
    }

    func testParseVisitDate() {
        let iso = T3Parsing.parseVisitDate("2026-01-01T00:00:00Z")
        XCTAssertEqual(iso, T3Parsing.parseDate("2026-01-01T00:00:00Z"))

        let seconds = T3Parsing.parseVisitDate(NSNumber(value: 1_767_225_600))
        XCTAssertEqual(seconds, Date(timeIntervalSince1970: 1_767_225_600))

        let millis = T3Parsing.parseVisitDate(NSNumber(value: 1_767_225_600_000))
        XCTAssertEqual(millis, Date(timeIntervalSince1970: 1_767_225_600))

        XCTAssertNil(T3Parsing.parseVisitDate(nil))
        XCTAssertNil(T3Parsing.parseVisitDate(NSNull()))
        XCTAssertNil(T3Parsing.parseVisitDate("not-a-date"))
        XCTAssertNil(T3Parsing.parseVisitDate(NSNumber(value: -5)))
        XCTAssertNil(T3Parsing.parseVisitDate(NSNumber(value: true)))
    }

    // MARK: - Thread semantics

    private func snapshot(fromJSON json: String) throws -> T3Snapshot {
        let payload = [UInt8](json.utf8)
        let bytes = fullRecord([0x01, 0x00] + payload)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitty-test-\(UUID().uuidString).log")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let snapshot = T3Parsing.parseLog(at: url) else {
            XCTFail("parseLog returned nil")
            throw NSError(domain: "test", code: 1)
        }
        return snapshot
    }

    func testDecodeSnapshotEndToEnd() throws {
        let json = [
            #"{"schemaVersion":7,"environmentId":"env-1","snapshot":{"snapshotSequence":42,"projects":[{"id":"p1","title":"Repo Demo"}],"threads":["#,
            #"{"id":"t1","title":"Fix \u202Erm issue","projectId":"p1","updatedAt":"2026-01-01T00:00:00Z","session":{"status":"ready","lastError":""},"settledAt":"2026-01-02T00:00:00Z"},"#,
            #"{"id":"t2","title":"Run tests\n\u0007case","session":{"status":"running","lastError":"boom"},"hasPendingUserInput":true,"latestTurn":{"turnId":"turn-2","completedAt":"2026-01-01T00:00:05Z"},"updatedAt":"2026-01-01T00:00:05Z"},"#,
            #"{"id":"t3","title":"Archived","session":{"status":"ready"},"archivedAt":"2025-12-01T00:00:00Z"}"#,
            #"]}}"#,
        ].joined()
        let snapshot = try snapshot(fromJSON: json)

        XCTAssertEqual(snapshot.sequence, 42)
        XCTAssertEqual(snapshot.environmentId, "env-1")
        XCTAssertEqual(snapshot.threads.count, 2)

        let first = try XCTUnwrap(snapshot.threads.first { $0.id == "t1" })
        XCTAssertEqual(first.title, "Fix rm issue")
        XCTAssertEqual(first.projectTitle, "Repo Demo")
        XCTAssertTrue(first.settled)
        XCTAssertFalse(first.needsReview)

        let second = try XCTUnwrap(snapshot.threads.first { $0.id == "t2" })
        XCTAssertEqual(second.title, "Run tests case")
        XCTAssertTrue(second.isRunning)
        XCTAssertTrue(second.needsReview)
        XCTAssertTrue(second.hasError)
        XCTAssertFalse(second.isReviewedByVisit)
        XCTAssertEqual(second.alertKey, "t2#turn-2")
    }

    func testDecodeSnapshotReturnsOldestWhenGarbage() {
        XCTAssertNil(T3Parsing.decodeSnapshot(Array("complete garbage".utf8)))
        XCTAssertNil(T3Parsing.decodeSnapshot([0xFF, 0xFE, 0x00, 0x01]))
    }

    // MARK: - T3 Code Beta (schema v3) thread-level status

    func testDecodeSnapshotSchemaV3() throws {
        // v3 moves status to the thread, renames its vocabulary and nulls out
        // optional keys (JSON null -> NSNull, which must not read as "present").
        let json = [
            #"{"schemaVersion":3,"environmentId":"env-9","snapshot":{"snapshotSequence":99,"projects":[],"threads":["#,
            #"{"id":"a","title":"Done","status":"completed","lastError":null,"pendingRuntimeRequest":null,"activeRunId":null,"latestRunId":"run-1","latestRunCompletedAt":"2026-02-01T00:00:00Z","lastVisitedAt":"2026-02-01T00:00:01Z","updatedAt":"2026-02-01T00:00:00Z"},"#,
            #"{"id":"b","title":"Idle","status":"idle","lastError":null,"pendingRuntimeRequest":null,"activeRunId":null,"settledAt":"2026-02-01T00:00:00Z","updatedAt":"2026-02-01T00:00:00Z"},"#,
            #"{"id":"c","title":"Busy","status":"running","activeRunId":"run-9","lastError":null,"pendingRuntimeRequest":null,"updatedAt":"2026-02-01T00:00:02Z"},"#,
            #"{"id":"d","title":"Queued","status":"queued","lastError":null,"updatedAt":"2026-02-01T00:00:03Z"}"#,
            #"]}}"#,
        ].joined()
        let snapshot = try snapshot(fromJSON: json)

        XCTAssertEqual(snapshot.threads.count, 4)
        let a = try XCTUnwrap(snapshot.threads.first { $0.id == "a" })
        XCTAssertEqual(a.status, "ready")        // completed -> ready
        XCTAssertTrue(a.needsReview)
        XCTAssertTrue(a.isReviewedByVisit)        // visited after completion
        XCTAssertEqual(a.alertKey, "a#run-1")     // latestRunId as review key
        XCTAssertEqual(a.latestTurnCompletedAt, T3Parsing.parseDate("2026-02-01T00:00:00Z"))

        let b = try XCTUnwrap(snapshot.threads.first { $0.id == "b" })
        XCTAssertEqual(b.status, "stopped")       // idle -> stopped
        XCTAssertFalse(b.needsReview)

        let c = try XCTUnwrap(snapshot.threads.first { $0.id == "c" })
        XCTAssertTrue(c.isRunning)
        XCTAssertFalse(c.pendingApproval)         // null must not count as present

        let d = try XCTUnwrap(snapshot.threads.first { $0.id == "d" })
        XCTAssertTrue(d.isRunning)                // queued -> running
    }

    func testSchemaV3IdleButActiveRunCountsRunning() {
        // Lag case: status still "idle" while a run is in flight.
        let threadDict: [String: Any] = [
            "status": "idle",
            "activeRunId": "run-1",
        ]
        XCTAssertEqual(T3Parsing.normalizedStatus(thread: threadDict, session: [:]), "running")
    }

    func testParseLogPicksNewestRecord() throws {
        let older = fullRecord([UInt8](#"{"schemaVersion":1,"snapshot":{"snapshotSequence":1,"threads":[]}}"#.utf8))
        let newer = fullRecord([UInt8](#"{"schemaVersion":1,"snapshot":{"snapshotSequence":9,"threads":[]}}"#.utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitty-test-\(UUID().uuidString).log")
        try Data(older + newer).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try XCTUnwrap(T3Parsing.parseLog(at: url))
        XCTAssertEqual(snapshot.sequence, 9)
    }

    func testParseLogRejectsEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitty-test-\(UUID().uuidString).log")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(T3Parsing.parseLog(at: url))
    }

    // MARK: - Review logic

    private func thread(
        status: String = "ready",
        settled: Bool = false,
        snoozed: Bool = false,
        approval: Bool = false,
        completed: Date? = nil,
        visited: Date? = nil
    ) -> T3Thread {
        T3Thread(
            id: "t", title: "T", projectTitle: "", status: status,
            settled: settled, snoozed: snoozed,
            pendingApproval: approval, pendingInput: false,
            proposedPlan: false, hasError: false,
            updatedAt: completed, latestTurnId: "turn-1", latestTurnCompletedAt: completed,
            lastVisitedAt: visited
        )
    }

    func testReviewKeyFallsBackToThread() {
        let t = thread()
        XCTAssertEqual(t.reviewKey, "turn-1")
        XCTAssertEqual(t.alertKey, "t#turn-1")
    }

    func testNeedsReview() {
        XCTAssertTrue(thread().needsReview)
        XCTAssertTrue(thread(status: "running", approval: true).needsReview)
        XCTAssertFalse(thread(status: "running").needsReview)
        XCTAssertFalse(thread(settled: true).needsReview)
        XCTAssertFalse(thread(snoozed: true).needsReview)
    }

    func testReviewedByVisitTolerance() {
        let now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        XCTAssertTrue(thread(completed: now, visited: now.addingTimeInterval(0.5)).isReviewedByVisit)
        XCTAssertFalse(thread(completed: now, visited: now.addingTimeInterval(-2)).isReviewedByVisit)
        XCTAssertFalse(thread(approval: true, completed: now, visited: now.addingTimeInterval(5)).isReviewedByVisit)
        XCTAssertFalse(thread(completed: now, visited: nil).isReviewedByVisit)
    }
}
