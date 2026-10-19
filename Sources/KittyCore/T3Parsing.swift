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
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func decodeSnapshot(_ payload: [UInt8]) -> T3Snapshot? {
        guard let slice = jsonObjectBytes(payload) else { return nil }
        let text = String(decoding: slice, as: UTF8.self)
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = root["snapshot"] as? [String: Any]
        else { return nil }

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
        if let n = value as? NSNumber { return true }
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
            guard let start = find(record, marker) else { continue }
            if let snapshot = decodeSnapshot(Array(record[start...])) {
                return snapshot
            }
        }
        return nil
    }
}
