import Combine
import Foundation
import AppKit

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderKind: ProviderSnapshot] = [:]
    @Published private(set) var lastRefreshAt: Date?

    let settingsStore: SettingsStore

    private let adapters: [ProviderKind: any ProviderAdapter]
    private let fileWatchService = FileWatchService()
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?

    init(settingsStore: SettingsStore, adapters: [ProviderKind: any ProviderAdapter]? = nil) {
        self.settingsStore = settingsStore
        self.adapters = adapters ?? [
            .codex: CodexAdapter(),
            .claude: ClaudeAdapter(),
            .antigravity: AntigravityAdapter(),
            .windsurf: WindsurfAdapter(),
        ]

        settingsStore.$settings
            .sink { [weak self] _ in
                self?.handleSettingsChange()
            }
            .store(in: &cancellables)
    }

    func start() {
        configureWatchers()
        configurePolling()
        configureWakeNotification()
        refreshAll()
    }

    func stop() {
        pendingRefreshWorkItem?.cancel()
        refreshTask?.cancel()
        pollTimer?.invalidate()
        fileWatchService.stopWatching()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func refreshAll() {
        // Invalidate all API caches so we get truly fresh data
        for adapter in adapters.values {
            adapter.invalidateCache()
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefreshAll()
        }
    }

    func snapshot(for provider: ProviderKind) -> ProviderSnapshot {
        snapshots[provider] ?? .unavailable(
            provider: provider,
            sourceDescription: "No data yet",
            message: "Waiting for first refresh."
        )
    }

    private func performRefreshAll() async {
        var updated = snapshots

        for provider in ProviderKind.allCases {
            guard let adapter = adapters[provider] else {
                continue
            }

            do {
                let snapshot = try await adapter.loadSnapshot()
                updated[provider] = snapshot
            } catch {
                if updated[provider] == nil {
                    updated[provider] = .unavailable(
                        provider: provider,
                        status: .error,
                        sourceDescription: "Adapter load failed",
                        message: error.localizedDescription
                    )
                }
            }
        }

        guard !Task.isCancelled else {
            return
        }

        snapshots = updated
        lastRefreshAt = Date()
    }

    private func handleSettingsChange() {
        configureWatchers()
        configurePolling()
    }

    private func configureWatchers() {
        let urls = adapters.values.flatMap(\.observedURLs)
        fileWatchService.startWatching(urls: urls) { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleRefresh()
            }
        }
    }

    private func configurePolling() {
        pollTimer?.invalidate()
        let interval = max(15, settingsStore.settings.refreshInterval)

        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func scheduleRefresh() {
        pendingRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshAll()
            }
        }

        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    // MARK: - Wake from sleep

    private func configureWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delay slightly to let network come back up after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Task { @MainActor in
                    // Invalidate Claude caches so we fetch fresh data after sleep
                    ClaudeAdapter.invalidateCaches()
                    self?.refreshAll()
                }
            }
        }
    }
}
