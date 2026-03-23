import Foundation

final class FileWatchService {
    private struct Watcher {
        let source: DispatchSourceFileSystemObject
        let descriptor: Int32
    }

    private let queue = DispatchQueue(label: "AIUsageTracker.filewatch", qos: .utility)
    private var watchers: [String: Watcher] = [:]

    func startWatching(urls: [URL], onChange: @escaping @Sendable () -> Void) {
        stopWatching()

        let watchTargets = Set(urls.compactMap(resolveWatchTarget(for:)))

        for url in watchTargets {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete, .attrib],
                queue: queue
            )

            source.setEventHandler(handler: onChange)
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()

            watchers[url.path] = Watcher(source: source, descriptor: descriptor)
        }
    }

    func stopWatching() {
        watchers.values.forEach { $0.source.cancel() }
        watchers.removeAll()
    }

    private func resolveWatchTarget(for url: URL) -> URL? {
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return url
        }

        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            return parent
        }

        return nil
    }
}
