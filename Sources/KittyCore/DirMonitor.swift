#if os(macOS)
import Foundation
import CoreServices

/// Coalesced FSEvents watcher over the T3 Code cache directories.
/// Event-driven polling is cheaper than a tight timer: on Apple silicon the
/// stream itself costs no CPU wakeups, it just wakes us on filesystem changes.
final class DirMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    // Non-capturing C function pointer; context carries an unretained self.
    private let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
        guard let info, numEvents > 0, let eventPaths else { return }
        let monitor = Unmanaged<DirMonitor>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
        guard !paths.isEmpty else { return }
        monitor.deliver(paths)
    }

    init(paths: [String], queue: DispatchQueue, handler: @escaping @Sendable ([String]) -> Void) {
        self.queue = queue
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func restartIfNeeded() {
        guard let stream, !FSEventStreamIsRunning(stream) else { return }
        if FSEventStreamStart(stream) { return }
        KittyLog.write("FSEvents stream failed to restart; slow timer keeps watching")
    }

    private func deliver(_ paths: [String]) {
        queue.async { [handler] in handler(paths) }
    }
}
#endif
