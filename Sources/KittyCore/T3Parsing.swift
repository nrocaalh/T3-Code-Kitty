import Foundation

public struct T3Thread: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let projectTitle: String
    public let status: String
    public let settled: Bool
    public let snoozed: Bool
    public let pendingApproval: Bool
    public let pendingInput: Bool
    public let proposedPlan: Bool
    public let hasError: Bool
    public let updatedAt: Date?
    public let latestTurnId: String?
    public let latestTurnCompletedAt: Date?
    public var lastVisitedAt: Date?
    public var reviewedByBacklog = false

    public var reviewKey: String {
        if let latestTurnId, !latestTurnId.isEmpty { return latestTurnId }
        return "thread"
    }

    public var alertKey: String { "\(id)#\(reviewKey)" }

    public var isReviewedByVisit: Bool {
        guard status == "ready", !settled, !snoozed else { return false }
        if pendingApproval || pendingInput || proposedPlan || hasError { return false }
        if reviewedByBacklog { return true }
        guard let completedAt = latestTurnCompletedAt ?? updatedAt,
              let lastVisitedAt
        else { return false }
        return lastVisitedAt.addingTimeInterval(1) >= completedAt
    }

    public var needsReview: Bool {
        (status == "ready" && !settled && !snoozed)
            || pendingApproval
            || pendingInput
            || proposedPlan
            || hasError
    }

    public var isRunning: Bool { status == "running" }
}

public struct T3Snapshot: Sendable {
    public let sequence: Int
    public let environmentId: String
    public let threads: [T3Thread]
    public let capturedAt: Date
}

/// Pure, filesystem-independent parsing logic for T3 Code's LevelDB cache.
/// Everything here is stateless so it can be unit tested on any platform.
enum T3Parsing {
    static let marker = Array(#"{"schemaVersion""#.utf8)

    static func find(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        find(haystack, needle, from: 0)
    }

    static func find(_ haystack: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
        let n = haystack.count
        let m = needle.count
        guard m > 0, start >= 0, n - start >= m else { return nil }
        if m == 1 { return haystack[start...].firstIndex(of: needle[0]) }
        // Boyer-Moore-Horspool: the snapshot marker is 16 bytes, so the skip
        // table lets us stride past most of multi-megabyte records.
        var skip = [Int](repeating: m, count: 256)
        for i in 0..<(m - 1) { skip[Int(needle[i])] = m - 1 - i }
        var i = start
        while i <= n - m {
            var j = m - 1
            while j >= 0 && haystack[i + j] == needle[j] { j -= 1 }
            if j < 0 { return i }
            i += skip[Int(haystack[i + m - 1])]
        }
        return nil
    }

    // MARK: - IndexedDB value decoding

    /// Blink wraps large IndexedDB values as `FF 11 02` + a Snappy stream
    /// (see idb_value_wrapping.cc: kRequiresProcessingSSVPseudoVersion +
    /// kCompressedWithSnappy). Without unwrapping, the cached shell snapshot
    /// is unreadable.
    static let idbSnappyWrapper: [UInt8] = [0xFF, 0x11, 0x02]
    static let maxSnappyOutput = 64 * 1024 * 1024

    /// Decodes one IndexedDB value into a snapshot, whatever encoding T3
    /// Code's Chromium used for it: raw JSON, a Snappy-wrapped string, or a
    /// two-byte (UTF-16) V8 string.
    static func decodeSnapshotValue(_ bytes: [UInt8]) -> T3Snapshot? {
        if let snapshot = decodeSnapshot(bytes) { return snapshot }
        var searchFrom = 0
        var attempts = 0
        while attempts < 16,
              let wrap = find(bytes, idbSnappyWrapper, from: searchFrom) {
            attempts += 1
            searchFrom = wrap + idbSnappyWrapper.count
            guard let inflated = snappyDecompress(Array(bytes[searchFrom...])) else { continue }
            if let snapshot = decodeSnapshot(inflated) { return snapshot }
            if let snapshot = decodeSnapshotFromUTF16(inflated) { return snapshot }
        }
        return decodeSnapshotFromUTF16(bytes)
    }

    static func readVarint(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        var result = 0
        var shift = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= (Int(byte) & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 35 { return nil }
        }
        return nil
    }

    /// Raw Snappy block format: varint uncompressed length, then literal and
    /// copy tags. This is the whole decompressor IndexedDB values need.
    static func snappyDecompress(_ input: [UInt8]) -> [UInt8]? {
        var offset = 0
        guard let length = readVarint(input, &offset), length > 0, length <= maxSnappyOutput
        else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(min(length, 4 * 1024 * 1024))
        while offset < input.count, out.count < length {
            let tag = input[offset]
            offset += 1
            let kind = tag & 0x03
            if kind == 0 {
                var count = Int(tag >> 2)
                if count >= 60 {
                    let extra = count - 59
                    guard offset + extra <= input.count else { return nil }
                    count = 0
                    for index in 0..<extra { count |= Int(input[offset + index]) << (8 * index) }
                    offset += extra
                    count += 1
                } else {
                    count += 1
                }
                guard offset + count <= input.count, out.count + count <= length else { return nil }
                out.append(contentsOf: input[offset..<(offset + count)])
                offset += count
            } else {
                let count: Int
                var distance: Int
                switch kind {
                case 1:
                    count = 4 + (Int(tag >> 2) & 0x07)
                    guard offset < input.count else { return nil }
                    distance = (Int(tag >> 5) << 8) | Int(input[offset])
                    offset += 1
                case 2:
                    count = Int(tag >> 2) + 1
                    guard offset + 2 <= input.count else { return nil }
                    distance = Int(input[offset]) | (Int(input[offset + 1]) << 8)
                    offset += 2
                default:
                    count = Int(tag >> 2) + 1
                    guard offset + 4 <= input.count else { return nil }
                    distance = Int(input[offset])
                        | (Int(input[offset + 1]) << 8)
                        | (Int(input[offset + 2]) << 16)
                        | (Int(input[offset + 3]) << 24)
                    offset += 4
                }
                guard distance > 0, distance <= out.count, out.count + count <= length else {
                    return nil
                }
                // Copies may overlap their own output, so they go byte by byte.
                for _ in 0..<count {
                    out.append(out[out.count - distance])
                }
            }
        }
        return out.count == length ? out : nil
    }

    /// JSON root for one-byte V8 strings: Chromium stores JS strings with
    /// only Latin-1 characters as one byte per char, so accented text is not
    /// valid UTF-8 on disk. Try UTF-8 first, then transcode Latin-1.
    static func jsonRoot(from bytes: [UInt8]) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: Data(bytes)) {
            return object as? [String: Any]
        }
        var utf8 = [UInt8]()
        utf8.reserveCapacity(bytes.count + 16)
        for byte in bytes {
            if byte < 0x80 {
                utf8.append(byte)
            } else {
                utf8.append(0xC0 | (byte >> 6))
                utf8.append(0x80 | (byte & 0x3F))
            }
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(utf8)) {
            return object as? [String: Any]
        }
        return nil
    }

    static func decodeSnapshot(_ payload: [UInt8]) -> T3Snapshot? {
        guard let slice = jsonObjectBytes(payload),
              let root = jsonRoot(from: slice),
              let snapshot = root["snapshot"] as? [String: Any]
        else { return nil }
        return buildSnapshot(root: root, snapshot: snapshot)
    }

    /// Two-byte V8 strings (any character above U+00FF, e.g. emoji) store the
    /// JSON as UTF-16LE. Matches `{"schemaVersion":` interleaved with zeros,
    /// then brace-matches with a two-byte stride.
    static let utf16Marker: [UInt8] = {
        var bytes: [UInt8] = []
        for unit in "{\"schemaVersion\":".utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }()

    /// Byte signature of a record that holds shell/thread snapshot data (as
    /// opposed to config or vcs-refs records, which also carry
    /// `{"schemaVersion"`). Used to tell "T3 Code is writing snapshot data we
    /// cannot decode" apart from "the log only has unrelated records".
    static let shellSignature = Array(#""snapshot":{"snapshotSequence""#.utf8)
    static let shellSignatureUTF16: [UInt8] = {
        var bytes: [UInt8] = []
        for unit in "\"snapshot\":{\"snapshotSequence\"".utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }()

    static func containsShellSignature(_ bytes: [UInt8]) -> Bool {
        find(bytes, shellSignature) != nil || find(bytes, shellSignatureUTF16) != nil
    }

    static func decodeSnapshotFromUTF16(_ bytes: [UInt8]) -> T3Snapshot? {
        guard let start = find(bytes, utf16Marker),
              let units = jsonObjectUTF16Units(bytes, start: start)
        else { return nil }
        let text = String(decoding: units, as: UTF16.self)
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let snapshot = root["snapshot"] as? [String: Any]
        else { return nil }
        return buildSnapshot(root: root, snapshot: snapshot)
    }

    /// Returns the JSON object's UTF-16 code units, starting at `start` (the
    /// `{` low byte of the UTF-16LE marker). String content may hold any code
    /// unit (surrogate pairs); the structural region must stay ASCII.
    static func jsonObjectUTF16Units(_ payload: [UInt8], start: Int) -> [UInt16]? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i + 1 < payload.count {
            let low = payload[i]
            let high = payload[i + 1]
            if inString {
                if escaped {
                    escaped = false
                } else if high == 0, low == 0x5C {
                    escaped = true
                } else if high == 0, low == 0x22 {
                    inString = false
                }
            } else {
                guard high == 0 else { return nil }
                if low == 0x22 {
                    inString = true
                } else if low == 0x7B {
                    depth += 1
                } else if low == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        var units = [UInt16]()
                        units.reserveCapacity((i + 2 - start) / 2)
                        var j = start
                        while j <= i {
                            units.append(UInt16(payload[j]) | (UInt16(payload[j + 1]) << 8))
                            j += 2
                        }
                        return units
                    }
                }
            }
            i += 2
        }
        return nil
    }

    static func buildSnapshot(root: [String: Any], snapshot: [String: Any]) -> T3Snapshot? {
        let environmentId = root["environmentId"] as? String ?? ""
        let sequence = snapshot["snapshotSequence"] as? Int ?? 0

        var projects: [String: String] = [:]
        if let list = snapshot["projects"] as? [[String: Any]] {
            for project in list {
                if let id = project["id"] as? String {
                    projects[id] = clean(project["title"] as? String ?? "")
                }
            }
        }

        var threads: [T3Thread] = []
        if let list = snapshot["threads"] as? [[String: Any]] {
            for thread in list {
                guard let id = thread["id"] as? String else { continue }
                if thread["archivedAt"] is String { continue }
                let session = thread["session"] as? [String: Any] ?? [:]
                let projectId = thread["projectId"] as? String ?? ""
                let status = normalizedStatus(thread: thread, session: session)
                let latestTurn = thread["latestTurn"] as? [String: Any]
                let hasError: Bool
                if let sessionError = session["lastError"] as? String {
                    hasError = !sessionError.isEmpty
                } else if let threadError = thread["lastError"] as? String {
                    hasError = !threadError.isEmpty
                } else {
                    hasError = false
                }
                let pendingApproval: Bool
                if let flag = thread["hasPendingApprovals"] as? Bool {
                    pendingApproval = flag
                } else {
                    // v3 has no hasPendingApprovals; a JSON null becomes NSNull,
                    // so test for an actual (non-null) value, not mere presence.
                    pendingApproval = Self.isPresent(thread["pendingRuntimeRequest"])
                }
                threads.append(T3Thread(
                    id: id,
                    title: clean(thread["title"] as? String ?? "Session"),
                    projectTitle: projects[projectId] ?? "",
                    status: status,
                    settled: thread["settledAt"] is String,
                    snoozed: isSnoozed(thread["snoozedUntil"] as? String),
                    pendingApproval: pendingApproval,
                    pendingInput: thread["hasPendingUserInput"] as? Bool ?? false,
                    proposedPlan: thread["hasActionableProposedPlan"] as? Bool ?? false,
                    hasError: hasError,
                    updatedAt: parseDate(thread["updatedAt"] as? String),
                    latestTurnId: (latestTurn?["turnId"] as? String) ?? (thread["latestRunId"] as? String),
                    latestTurnCompletedAt: parseDate(latestTurn?["completedAt"] as? String)
                        ?? parseDate(thread["latestRunCompletedAt"] as? String),
                    lastVisitedAt: parseDate(thread["lastVisitedAt"] as? String)
                ))
            }
        }

        return T3Snapshot(
            sequence: sequence,
            environmentId: environmentId,
            threads: threads,
            capturedAt: Date()
        )
    }

    /// A JSON null deserializes to NSNull, so "key present" is not "has value".
    static func isPresent(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let s = value as? String { return !s.isEmpty }
        if value is NSNumber { return true }
        if let a = value as? [Any] { return !a.isEmpty }
        if let d = value as? [String: Any] { return !d.isEmpty }
        return true
    }

    /// T3 Code Beta (schema v3) moved the status from `session.status` to the
    /// thread level and renamed its vocabulary: `completed` == old `ready`,
    /// `idle` == old `stopped`. Normalize so the rest of the app speaks one
    /// language and both schemas decode identically.
    static func normalizedStatus(thread: [String: Any], session: [String: Any]) -> String {
        let raw = (session["status"] as? String) ?? (thread["status"] as? String) ?? "stopped"
        let mapped: String
        switch raw {
        case "completed": mapped = "ready"
        case "idle": mapped = "stopped"
        case "queued", "starting": mapped = "running"
        default: mapped = raw
        }
        if mapped == "stopped", thread["activeRunId"] is String, thread["latestRunCompletedAt"] == nil {
            return "running"
        }
        return mapped
    }

    /// Returns the bytes of the first complete JSON object starting at the
    /// beginning of the payload. LevelDB stores an extra serialization prefix
    /// before the JSON, so we scan forward for the opening brace.
    static func jsonObjectBytes(_ payload: [UInt8]) -> [UInt8]? {
        guard let start = payload.firstIndex(of: 0x7B) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start

        while i < payload.count {
            let byte = payload[i]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        return Array(payload[start...i])
                    }
                }
            }
            i += 1
        }
        return nil
    }

    static func clean(_ value: String) -> String {
        let spaced = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var result = ""
        for scalar in spaced.unicodeScalars where !isInvisible(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops control and format characters that could spoof UI text
    /// (bidi overrides, zero-width spaces, etc.), keeping tab and ZWJ.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x0008, 0x000B, 0x000C, 0x000E...0x001F,
             0x007F...0x009F,
             0x00AD, 0x061C, 0x180E,
             0x200B, 0x200C, 0x200E, 0x200F,
             0x202A...0x202E,
             0x2060...0x2064, 0x2066...0x2069,
             0xFEFF, 0xFFF9...0xFFFB,
             0xE0001, 0xE0020...0xE007F:
            return true
        default:
            return false
        }
    }

    /// LevelDB log record framing. Blocks are 32 KiB; each record has a
    /// 7-byte header (CRC u32, length u16, type u8): 1=Full, 2=First,
    /// 3=Middle, 4=Last.
    static func logicalRecords(_ bytes: [UInt8]) -> [[UInt8]] {
        let blockSize = 32768
        var records: [[UInt8]] = []
        var pending: [UInt8]?
        var pos = 0

        while pos < bytes.count {
            let blockEnd = min(pos + blockSize, bytes.count)
            while pos + 7 <= blockEnd {
                let length = Int(bytes[pos + 4]) | (Int(bytes[pos + 5]) << 8)
                let type = bytes[pos + 6]
                pos += 7

                if type == 0 && length == 0 {
                    pos = blockEnd
                    break
                }
                guard pos + length <= blockEnd else {
                    pos = blockEnd
                    break
                }
                let chunk = Array(bytes[pos..<(pos + length)])
                pos += length

                switch type {
                case 1:
                    records.append(chunk)
                case 2:
                    pending = chunk
                case 3:
                    if pending != nil { pending!.append(contentsOf: chunk) }
                case 4:
                    if pending != nil {
                        pending!.append(contentsOf: chunk)
                        records.append(pending!)
                        pending = nil
                    }
                default:
                    break
                }
            }
            pos = blockEnd
        }
        return records
    }

    static func isSnoozed(_ value: String?) -> Bool {
        guard let date = parseDate(value) else { return false }
        return date > Date()
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    /// `threadLastVisitedAtById` values may be ISO strings or epoch numbers
    /// (seconds or milliseconds) depending on the T3 Code version.
    static func parseVisitDate(_ value: Any?) -> Date? {
        guard let value, !(value is NSNull), !(value is Bool) else { return nil }
        if let text = value as? String { return parseDate(text) }
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 100_000_000_000
                ? number.doubleValue / 1000
                : number.doubleValue
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        return nil
    }

    /// Copy-only bounded read. Never mmaps: LevelDB may truncate or delete
    /// the file concurrently, which would crash the process on mapped reads.
    static func readBounded(_ url: URL, limitBytes: Int) -> [UInt8]? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= limitBytes,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), data.count <= limitBytes else { return nil }
        return [UInt8](data)
    }

    static let maxLogBytes = 64 * 1024 * 1024
    static let maxLocalStorageBytes = 16 * 1024 * 1024

    /// Parse the newest snapshot object contained in a LevelDB `.log` file.
    /// When `from` is non-zero it must point at a 32 KiB block boundary.
    static func parseLog(at url: URL, from offset: Int = 0) -> T3Snapshot? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= maxLogBytes else { return nil }
        let bytes: [UInt8]
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if offset > 0 {
                handle.seek(toFileOffset: UInt64(offset))
            }
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            bytes = [UInt8](data)
        } catch {
            return nil
        }

        let records = logicalRecords(bytes)
        guard !records.isEmpty else { return nil }

        // Walk backwards: the newest snapshot is near the end, and a few
        // trailing records may merely contain the marker in a key or title.
        for record in records.reversed() {
            if let snapshot = decodeSnapshotValue(record) {
                return snapshot
            }
        }
        return nil
    }
}
