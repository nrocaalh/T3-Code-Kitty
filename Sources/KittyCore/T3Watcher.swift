import Foundation

/// Reads T3 Code's own locally cached snapshot, strictly read-only.
///
/// T3 Code (Electron) persists its renderer snapshot in an IndexedDB LevelDB
/// database. The current state lives in the append-only `.log` files. We
/// watch those directories with FSEvents (event-driven) plus a slow safety
/// poll, parse the records and never write to the directory.
public actor T3Watcher {
    private struct Cached {
        let size: Int
        let mtime: Date
        let snapshot: T3Snapshot?
    }

    private var onUpdate: (@Sendable (T3Snapshot?) -> Void)?
    private var safetyLoop: Task<Void, Never>?
    #if os(macOS)
    private var monitor: DirMonitor?
    #endif
    private var didStart = false
    private var pollInFlight = false
    private var cache: [String: Cached] = [:]
    private var lastLoggedFingerprint = ""
    private var lastKnownSnapshot: T3Snapshot?
    private var cachedVisits: [String: Date] = [:]
    private var visitsStat: (path: String, size: Int, mtime: Date)?
    private let trackingStartedAt: Date

    private let dbDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/t3code/IndexedDB/t3code_app_0.indexeddb.leveldb")
    private let localStorageDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/t3code/Local Storage/leveldb")
    private let eventsQueue = DispatchQueue(label: "com.t3codekitty.app.events", qos: .utility)

    public init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: KittyDefaults.reviewedTrackingStartedAt) as? Date {
            trackingStartedAt = stored
        } else {
            let now = Date()
            trackingStartedAt = now
            defaults.set(now, forKey: KittyDefaults.reviewedTrackingStartedAt)
        }
        if let raw = defaults.dictionary(forKey: KittyDefaults.cachedThreadVisits) as? [String: Double] {
            cachedVisits = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Idempotent: safe to call from `applicationDidFinishLaunching` and
    /// again from `applicationDidBecomeActive`.
    public func start(onUpdate: @escaping @Sendable (T3Snapshot?) -> Void) {
        self.onUpdate = onUpdate
        guard !didStart else {
            poll()
            return
        }
        didStart = true

        safetyLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                await self?.poll()
            }
        }

        #if os(macOS)
        var dirs: [String] = []
        for url in [dbDirectory, localStorageDirectory] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.type] as? FileAttributeType) == .typeDirectory {
                dirs.append(url.path)
            }
        }
        if !dirs.isEmpty {
            monitor = DirMonitor(paths: dirs, queue: eventsQueue, handler: { [weak self] _ in
                guard let self else { return }
                Task { await self.poll() }
            })
        }
        #endif

        poll()
    }

    public func refreshNow() {
        poll()
    }

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        let snapshot = readLatest()
        if let snapshot {
            let ready = snapshot.threads.filter { $0.needsReview }.count
            let running = snapshot.threads.filter { $0.isRunning }.count
            let fingerprint = "\(ready)/\(running)/\(snapshot.threads.count)"
            if fingerprint != lastLoggedFingerprint {
                lastLoggedFingerprint = fingerprint
                KittyLog.write("snapshot seq=\(snapshot.sequence) ready=\(ready) running=\(running) threads=\(snapshot.threads.count)")
            }
        }
        onUpdate?(snapshot)
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
                if let parsed = T3Parsing.parseLog(at: url, from: start),
                   parsed.sequence >= (previous?.snapshot?.sequence ?? -1) {
                    snapshot = parsed
                    cache[url.path] = Cached(size: size, mtime: mtime, snapshot: parsed)
                } else if let old = previous?.snapshot {
                    // No snapshot in the tail (or a partial write). Keep the
                    // last good state and retry on the next tick.
                    snapshot = old
                } else if start > 0, let full = T3Parsing.parseLog(at: url, from: 0) {
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

        // Minimal parsing: only `threadLastVisitedAtById` is ever extracted;
        // the store may contain unrelated Electron data we must not retain.
        for url in logs {
            guard let bytes = T3Parsing.readBounded(url, limitBytes: T3Parsing.maxLocalStorageBytes) else { continue }
            var fileDict: [String: Any]?
            for record in T3Parsing.logicalRecords(bytes) {
                guard T3Parsing.find(record, marker) != nil,
                      let slice = T3Parsing.jsonObjectBytes(record),
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
            if let bytes = T3Parsing.readBounded(table, limitBytes: T3Parsing.maxLocalStorageBytes) {
                let rootMarker = Array(#"{"projectExpandedById""#.utf8)
                if let start = T3Parsing.find(bytes, rootMarker),
                   let slice = T3Parsing.jsonObjectBytes(Array(bytes[start...])),
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
            guard let date = T3Parsing.parseDate(value) else { continue }
            let threadID = key.components(separatedBy: ":").last ?? key
            visits[threadID] = date
        }
        cachedVisits = visits
        rememberVisitsStat(logs.first)
        UserDefaults.standard.set(visits.mapValues { $0.timeIntervalSince1970 }, forKey: KittyDefaults.cachedThreadVisits)
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
                guard let bytes = T3Parsing.readBounded(table, limitBytes: T3Parsing.maxLogBytes) else { continue }
                guard let start = T3Parsing.find(bytes, T3Parsing.marker),
                      let snapshot = T3Parsing.decodeSnapshot(Array(bytes[start...]))
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
