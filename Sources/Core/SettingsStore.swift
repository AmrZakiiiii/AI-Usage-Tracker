import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, storageKey: String = "AIUsageTracker.settings") {
        self.defaults = defaults
        self.storageKey = storageKey

        if let data = defaults.data(forKey: storageKey),
           let saved = try? decoder.decode(AppSettings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = .default
        }
    }

    func update(_ transform: (inout AppSettings) -> Void) {
        var updated = settings
        transform(&updated)
        settings = updated
    }

    func setProvider(_ provider: ProviderKind, enabled: Bool) {
        update { settings in
            var providers = settings.enabledProviders

            if enabled, !providers.contains(provider) {
                providers.append(provider)
            } else if !enabled {
                providers.removeAll { $0 == provider }
            }

            settings.enabledProviders = ProviderKind.allCases.filter { providers.contains($0) }
        }
    }

    func setBarDisplayMode(_ mode: BarDisplayMode) {
        update { $0.barDisplayMode = mode }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        update { $0.refreshInterval = max(15, interval) }
    }

    private func save() {
        guard let data = try? encoder.encode(settings) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }
}
