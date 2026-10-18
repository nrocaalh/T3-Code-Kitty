import Foundation
import AppKit

struct T3Thread: Identifiable, Equatable {
    let id: String
    let title: String
    let projectTitle: String
    let status: String
    let settled: Bool
    let snoozed: Bool
    let pendingApproval: Bool
    let pendingInput: Bool
    let proposedPlan: Bool
    let hasError: Bool
    let updatedAt: Date?
    let latestTurnId: String?
    let latestTurnCompletedAt: Date?
    var lastVisitedAt: Date?
    var reviewedByBacklog = false

    var reviewKey: String {
        if let latestTurnId, !latestTurnId.isEmpty { return latestTurnId }
        return "thread"
    }

    var alertKey: String { "\(id)#\(reviewKey)" }

    var isReviewedByVisit: Bool {
        guard status == "ready", !settled, !snoozed else { return false }
        if pendingApproval || pendingInput || proposedPlan || hasError { return false }
        if reviewedByBacklog { return true }
        guard let completedAt = latestTurnCompletedAt ?? updatedAt,
              let lastVisitedAt
        else { return false }
        return lastVisitedAt.addingTimeInterval(1) >= completedAt
    }

    var needsReview: Bool {
        (status == "ready" && !settled && !snoozed)
            || pendingApproval
            || pendingInput
            || proposedPlan
            || hasError
    }

    var isRunning: Bool { status == "running" }
}

struct T3Snapshot {
    let sequence: Int
    let environmentId: String
    let threads: [T3Thread]
    let capturedAt: Date
}

/// Reads T3 Code's own locally cached snapshot, strictly read-only.
///
/// T3 Code (Electron) persists its renderer snapshot in an IndexedDB LevelDB
/// database. The current state lives in the append-only `.log` files. We parse
/// those records, take the newest snapshot, and never write to the directory.
final class T3Watcher {
    typealias Update = (T3Snapshot?) -> Void

    private struct Cached {
        let size: Int
        let mtime: Date
        let snapshot: T3Snapshot?
    }

    private let queue = DispatchQueue(label: "com.t3codekitty.app.watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cache: [String: Cached] = [:]
    private var lastLoggedFingerprint = ""
    private var lastKnownSnapshot: T3Snapshot?
    private var cachedVisits: [String: Date] = [:]
    private var visitsStat: (path: String, size: Int, mtime: Date)?
    private let trackingStartedAt: Date

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: "reviewedTrackingStartedAt") as? Date {
            trackingStartedAt = stored
        } else {
            let now = Date()
            trackingStartedAt = now
            defaults.set(now, forKey: "reviewedTrackingStartedAt")
        }
        if let raw = defaults.dictionary(forKey: "cachedThreadVisits") as? [String: Double] {
            cachedVisits = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    var onUpdate: Update?

    private let dbDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/t3code/IndexedDB/t3code_app_0.indexeddb.leveldb")
    private let localStorageDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/t3code/Local Storage/leveldb")

    func start() {
        queue.async { [weak self] in self?.poll() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.8, repeating: 0.4, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func refreshNow() {
        queue.async { [weak self] in self?.poll() }
    }

    private func poll() {
        let snapshot = readLatest()
        if let snapshot {
            let ready = snapshot.threads.filter { $0.needsReview }.count
            let running = snapshot.threads.filter { $0.isRunning }.count
            let fingerprint = "\(ready)/\(running)/\(snapshot.threads.count)"
            if fingerprint != lastLoggedFingerprint {
                lastLoggedFingerprint = fingerprint
                Log.write("snapshot seq=\(snapshot.sequence) ready=\(ready) running=\(running) threads=\(snapshot.threads.count)")
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    // MARK: - Reading the LevelDB log

    private func readLatest() -> T3Snapshot? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dbDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let logs = entries
            .filter { $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }

        var livePaths = Set<String>()
        var best: T3Snapshot?

        for url in logs {
            livePaths.insert(url.path)
            let values = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate ?? .distantPast

            let snapshot: T3Snapshot?
            if let cached = cache[url.path], cached.size == size, cached.mtime == mtime {
                snapshot = cached.snapshot
            } else {
                let previous = cache[url.path]
                let incremental = previous != nil && size >= (previous?.size ?? 0)
                let start = incremental
                    ? max(0, (size - 131_072) / 32_768 * 32_768)
                    : 0
                if let parsed = Self.parseLog(at: url, from: start),
                   parsed.sequence >= (previous?.snapshot?.sequence ?? -1) {
                    snapshot = parsed
                    cache[url.path] = Cached(size: size, mtime: mtime, snapshot: parsed)
                } else if let old = previous?.snapshot {
                    // No snapshot in the tail (or a partial write). Keep the
                    // last good state and retry on the next tick.
                    snapshot = old
                } else if start > 0, let full = Self.parseLog(at: url, from: 0) {
                    snapshot = full
                    cache[url.path] = Cached(size: size, mtime: mtime, snapshot: full)
                } else {
                    snapshot = nil
                }
            }

            if let snapshot, snapshot.sequence > (best?.sequence ?? -1) {
                best = snapshot
            }
        }

        cache = cache.filter { livePaths.contains($0.key) }

        if let best {
            lastKnownSnapshot = best
        } else if let lastKnownSnapshot {
            best = lastKnownSnapshot
        } else {
            best = parseSSTableFallback()
        }
        guard let snapshot = best else { return nil }
        let visits = readThreadVisits()
        let threads = snapshot.threads.map { thread -> T3Thread in
            var copy = thread
            copy.lastVisitedAt = visits[thread.id]
            if let completedAt = thread.latestTurnCompletedAt ?? thread.updatedAt {
                copy.reviewedByBacklog = thread.status == "ready" && completedAt < trackingStartedAt
            }
            return copy
        }
        return T3Snapshot(
            sequence: snapshot.sequence,
            environmentId: snapshot.environmentId,
            threads: threads,
            capturedAt: snapshot.capturedAt
        )
    }

    private func readThreadVisits() -> [String: Date] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: localStorageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return cachedVisits }

        let logs = entries
            .filter { $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }

        if let newest = logs.first,
           let stat = visitsStat,
           stat.path == newest.path,
           stat.size == ((try? newest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1),
           stat.mtime == modificationDate(newest) {
            return cachedVisits
        }

        let marker = Array("threadLastVisitedAtById".utf8)
        var dict: [String: Any]?

        for url in logs {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            var fileDict: [String: Any]?
            for record in Self.logicalRecords([UInt8](data)) {
                guard Self.find(record, marker) != nil,
                      let slice = Self.jsonObjectBytes(record),
                      let object = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
                      object["threadLastVisitedAtById"] is [String: Any]
                else { continue }
                fileDict = object
            }
            if let fileDict {
                dict = fileDict
                break
            }
        }

        if dict == nil, let table = entries.first(where: { $0.pathExtension == "ldb" }) {
            if let data = try? Data(contentsOf: table, options: [.mappedIfSafe]) {
                let bytes = [UInt8](data)
                let rootMarker = Array(#"{"projectExpandedById""#.utf8)
                if let start = Self.find(bytes, rootMarker),
                   let slice = Self.jsonObjectBytes(Array(bytes[start...])),
                   let object = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
                   object["threadLastVisitedAtById"] is [String: Any] {
                    dict = object
                }
            }
        }

        guard let raw = dict?["threadLastVisitedAtById"] as? [String: String] else {
            rememberVisitsStat(logs.first)
            return cachedVisits
        }
        var visits: [String: Date] = [:]
        for (key, value) in raw {
            guard let date = Self.parseDate(value) else { continue }
            let threadID = key.components(separatedBy: ":").last ?? key
            visits[threadID] = date
        }
        cachedVisits = visits
        rememberVisitsStat(logs.first)
        UserDefaults.standard.set(visits.mapValues { $0.timeIntervalSince1970 }, forKey: "cachedThreadVisits")
        return visits
    }

    private func rememberVisitsStat(_ url: URL?) {
        guard let url else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        visitsStat = (url.path, size, modificationDate(url))
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Parse the newest snapshot object contained in a LevelDB `.log` file.
    /// When `from` is non-zero it must point at a 32 KiB block boundary.
    static func parseLog(at url: URL, from offset: Int = 0) -> T3Snapshot? {
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

    private static let marker = Array(#"{"schemaVersion""#.utf8)

    private static func find(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
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

    private static func decodeSnapshot(_ payload: [UInt8]) -> T3Snapshot? {
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
                threads.append(T3Thread(
                    id: id,
                    title: clean(thread["title"] as? String ?? "Sesión"),
                    projectTitle: projects[projectId] ?? "",
                    status: session["status"] as? String ?? "stopped",
                    settled: thread["settledAt"] is String,
                    snoozed: isSnoozed(thread["snoozedUntil"] as? String),
                    pendingApproval: thread["hasPendingApprovals"] as? Bool ?? false,
                    pendingInput: thread["hasPendingUserInput"] as? Bool ?? false,
                    proposedPlan: thread["hasActionableProposedPlan"] as? Bool ?? false,
                    hasError: (session["lastError"] as? String)?.isEmpty == false,
                    updatedAt: parseDate(thread["updatedAt"] as? String),
                    latestTurnId: (thread["latestTurn"] as? [String: Any])?["turnId"] as? String,
                    latestTurnCompletedAt: parseDate((thread["latestTurn"] as? [String: Any])?["completedAt"] as? String),
                    lastVisitedAt: nil
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

    /// Returns the bytes of the first complete JSON object starting at the
    /// beginning of the payload. LevelDB stores an extra serialization prefix
    /// before the JSON, so we scan forward for the opening brace.
    private static func jsonObjectBytes(_ payload: [UInt8]) -> [UInt8]? {
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

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSnoozed(_ value: String?) -> Bool {
        guard let date = parseDate(value) else { return false }
        return date > Date()
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    // MARK: - LevelDB log record framing

    private static func logicalRecords(_ bytes: [UInt8]) -> [[UInt8]] {
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

    // MARK: - Fallback for compacted tables

    /// The SSTable is usually compressed, so this is only a best-effort scan.
    /// It is used when no log contains a snapshot (for example right after a
    /// compaction while T3 Code sits idle).
    private func parseSSTableFallback() -> T3Snapshot? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dbDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let tables = entries
            .filter { $0.pathExtension == "ldb" }
            .sorted { modificationDate($0) > modificationDate($1) }

        for table in tables {
            guard let cached = cache[table.path],
                  cached.size == ((try? table.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1),
                  cached.snapshot != nil
            else {
                guard let data = try? Data(contentsOf: table, options: [.mappedIfSafe]) else { continue }
                let bytes = [UInt8](data)
                guard let start = Self.find(bytes, Self.marker),
                      let snapshot = Self.decodeSnapshot(Array(bytes[start...]))
                else { continue }
                let size = (try? table.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                cache[table.path] = Cached(
                    size: size,
                    mtime: modificationDate(table),
                    snapshot: snapshot
                )
                return snapshot
            }
            return cached.snapshot
        }
        return nil
    }
}
