import CoreServices
import Foundation

/// Reports changed files under some directories through FSEvents, batched by `latency`, so
/// agent logs are read when they change instead of on a timer.
final class FileChangeWatcher: @unchecked Sendable {
    /// Changed file paths, and whether events were dropped so everything must be checked.
    typealias Handler = @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void

    private let handler: Handler
    private let queue = DispatchQueue(label: "Weft.FileChangeWatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    /// Watches the directories in `paths` that exist; nil if none do.
    init?(paths: [String], latency: TimeInterval, handler: @escaping Handler) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileChangeWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                  | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        let mustRescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
        watcher.handler(list, mustRescan)
    }
}
