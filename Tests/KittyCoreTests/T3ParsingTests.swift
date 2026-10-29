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

    func testFindEdgeCases() {
        XCTAssertEqual(T3Parsing.find(Array("abc".utf8), Array("abc".utf8)), 0)
        XCTAssertEqual(T3Parsing.find(Array("a".utf8), Array("a".utf8)), 0)
        XCTAssertEqual(T3Parsing.find(Array("ababababX".utf8), Array("abX".utf8)), 6)
        XCTAssertEqual(T3Parsing.find(Array("aXbXc".utf8), Array("Xc".utf8)), 3)
        XCTAssertEqual(T3Parsing.find(Array("xxab".utf8), Array("ab".utf8)), 2)
        XCTAssertNil(T3Parsing.find(Array("ab".utf8), Array("abc".utf8)))
        XCTAssertNil(T3Parsing.find(Array("abcdef".utf8), []))
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

// MARK: - IndexedDB value decoding (Chromium wrappers)

extension T3ParsingTests {

    // varint uncompressed length + one literal run + one copy: "hellohello"
    func testSnappyDecompressLiteralRun() {
        let stream: [UInt8] = [10, (5 - 1) << 2, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
                               (1 << 2) | 1, 5, // copy 5 bytes from distance 5
                               ]
        XCTAssertEqual(T3Parsing.snappyDecompress(stream), Array("hellohello".utf8))
    }

    func testSnappyDecompressRejectsBadStreams() {
        XCTAssertNil(T3Parsing.snappyDecompress([]))
        // Declared longer than the data provides.
        XCTAssertNil(T3Parsing.snappyDecompress([200, 1, (2 << 2), 0x61, 0x62]))
        // Copy distance larger than the output produced so far.
        XCTAssertNil(T3Parsing.snappyDecompress([4, (2 << 2), 0x61, 5, 0]))
    }

    // Real-world shape: Blink wraps the SSV of the shell snapshot as
    // `FF 11 02` + Snappy, and the JSON is a one-byte (Latin-1) V8 string.
    private var wrappedLatin1Value: [UInt8] { [
        0xe9, 0x22, 0xff, 0x11, 0x02, 0xb4, 0x01, 0xf0, 0xb3, 0xff, 0x15, 0xfe, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x10, 0x22, 0xa0,
        0x01, 0x7b, 0x22, 0x73, 0x63, 0x68, 0x65, 0x6d, 0x61, 0x56, 0x65, 0x72, 0x73, 0x69,
        0x6f, 0x6e, 0x22, 0x3a, 0x33, 0x2c, 0x22, 0x65, 0x6e, 0x76, 0x69, 0x72, 0x6f, 0x6e,
        0x6d, 0x65, 0x6e, 0x74, 0x49, 0x64, 0x22, 0x3a, 0x22, 0x65, 0x31, 0x22, 0x2c, 0x22,
        0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x22, 0x3a, 0x7b, 0x22, 0x73, 0x6e,
        0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x53, 0x65, 0x71, 0x75, 0x65, 0x6e, 0x63, 0x65,
        0x22, 0x3a, 0x34, 0x32, 0x2c, 0x22, 0x74, 0x68, 0x72, 0x65, 0x61, 0x64, 0x73, 0x22,
        0x3a, 0x5b, 0x7b, 0x22, 0x69, 0x64, 0x22, 0x3a, 0x22, 0x74, 0x31, 0x22, 0x2c, 0x22,
        0x74, 0x69, 0x74, 0x6c, 0x65, 0x22, 0x3a, 0x22, 0x70, 0x6f, 0x64, 0x72, 0xed, 0x61,
        0x20, 0xe1, 0x72, 0x62, 0x6f, 0x6c, 0x20, 0xf1, 0x22, 0x2c, 0x22, 0x73, 0x74, 0x61,
        0x74, 0x75, 0x73, 0x22, 0x3a, 0x22, 0x63, 0x6f, 0x6d, 0x70, 0x6c, 0x65, 0x74, 0x65,
        0x64, 0x22, 0x2c, 0x22, 0x73, 0x65, 0x73, 0x73, 0x69, 0x6f, 0x6e, 0x22, 0x3a, 0x6e,
        0x75, 0x6c, 0x6c, 0x7d, 0x5d, 0x7d, 0x7d,
    ] }

    func testDecodeSnapshotValueUnwrapsSnappyAndLatin1() {
        let snapshot = T3Parsing.decodeSnapshotValue(wrappedLatin1Value)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.sequence, 42)
        XCTAssertEqual(snapshot?.environmentId, "e1")
        XCTAssertEqual(snapshot?.threads.count, 1)
        XCTAssertEqual(snapshot?.threads.first?.title, "podría árbol ñ")
        XCTAssertEqual(snapshot?.threads.first?.status, "ready")
    }

    // Uncompressed one-byte (Latin-1) V8 string.
    func testDecodeSnapshotValueRawLatin1() {
        let raw = Array(wrappedLatin1Value.dropFirst(5 + 14)) // drop prefix, wrapper and snappy framing
        let value: [UInt8] = [
            0xff, 0x15, 0xfe,
        ] + .init(repeating: 0, count: 12) + [
            0xff, 0x10, 0x22, 0xa0, 0x01,
        ] + raw
        let snapshot = T3Parsing.decodeSnapshotValue(value)
        XCTAssertEqual(snapshot?.sequence, 42)
        XCTAssertEqual(snapshot?.threads.first?.title, "podría árbol ñ")
    }

    // Any character above U+00FF (emoji) makes V8 store the JSON as UTF-16LE.
    func testDecodeSnapshotValueUTF16() {
        let utf16JSON = Array("{\"schemaVersion\":3,\"environmentId\":\"e1\",\"snapshot\":{\"snapshotSequence\":7,\"threads\":[{\"id\":\"t2\",\"title\":\"hola 🐱\",\"status\":\"running\"}]}}".utf16)
        var value: [UInt8] = [0xff, 0x11, 0x02]
        let byteCount = utf16JSON.count * 2
        // Snappy: varint uncompressed length + one literal run.
        var length = UInt32(byteCount)
        while true {
            let byte = UInt8(length & 0x7F)
            length >>= 7
            if length == 0 { value.append(byte); break }
            value.append(byte | 0x80)
        }
        if byteCount <= 60 {
            value.append(UInt8((byteCount - 1) << 2))
        } else {
            value.append(UInt8(61 << 2))
            value.append(UInt8((byteCount - 1) & 0xFF))
            value.append(UInt8(((byteCount - 1) >> 8) & 0xFF))
        }
        for unit in utf16JSON {
            value.append(UInt8(unit & 0xFF))
            value.append(UInt8(unit >> 8))
        }
        let snapshot = T3Parsing.decodeSnapshotValue(value)
        XCTAssertEqual(snapshot?.sequence, 7)
        XCTAssertEqual(snapshot?.threads.first?.title, "hola 🐱")
        XCTAssertEqual(snapshot?.threads.first?.status, "running")
    }

    func testDecodeSnapshotValueRejectsGarbage() {
        XCTAssertNil(T3Parsing.decodeSnapshotValue(Array("not json at all".utf8)))
        XCTAssertNil(T3Parsing.decodeSnapshotValue([0xFF, 0x11, 0x02, 0x01, 0x02, 0x03]))
    }
}

// MARK: - Shell signature (blind detection)

extension T3ParsingTests {
    func testContainsShellSignature() {
        let shell = Array(#"{"schemaVersion":3,"environmentId":"e1","snapshot":{"snapshotSequence":9}}"#.utf8)
        XCTAssertTrue(T3Parsing.containsShellSignature(shell))
        let config = Array(#"{"schemaVersion":1,"environmentId":"e1","cwd":"/root","refs":[]}"#.utf8)
        XCTAssertFalse(T3Parsing.containsShellSignature(config))
        let utf16 = Array("{\"snapshot\":{\"snapshotSequence\":9}}".utf16)
            .flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertTrue(T3Parsing.containsShellSignature(utf16))
        XCTAssertFalse(T3Parsing.containsShellSignature([]))
    }
}
