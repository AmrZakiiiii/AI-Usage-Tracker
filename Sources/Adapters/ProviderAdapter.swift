import Foundation

@MainActor
protocol ProviderAdapter {
    var kind: ProviderKind { get }
    var observedURLs: [URL] { get }

    func loadSnapshot() async throws -> ProviderSnapshot
    func invalidateCache()
}

extension FileManager {
    func modificationDate(for url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }

        return values.contentModificationDate
    }
}
