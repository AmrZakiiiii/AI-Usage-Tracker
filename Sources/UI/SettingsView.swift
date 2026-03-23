import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var store: ProviderStore

    var body: some View {
        ScrollView {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 14) {
                    displayGroup
                    providerToggleGroup
                }
            }
        }
    }

    private var displayGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display")
                .font(.subheadline.weight(.semibold))

            Picker("Bar Mode", selection: binding(
                get: { store.settingsStore.settings.barDisplayMode },
                set: { store.settingsStore.setBarDisplayMode($0) }
            )) {
                ForEach(BarDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Stepper(
                value: binding(
                    get: { Int(store.settingsStore.settings.refreshInterval) },
                    set: { store.settingsStore.setRefreshInterval(TimeInterval($0)) }
                ),
                in: 15...300,
                step: 15
            ) {
                Text("Refresh every \(Int(store.settingsStore.settings.refreshInterval))s")
                    .font(.caption)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var providerToggleGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enabled Providers")
                .font(.subheadline.weight(.semibold))

            ForEach(ProviderKind.allCases) { provider in
                Toggle(provider.displayName, isOn: binding(
                    get: { store.settingsStore.settings.enabledProviders.contains(provider) },
                    set: { store.settingsStore.setProvider(provider, enabled: $0) }
                ))
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func binding<T>(get: @escaping @MainActor () -> T, set: @escaping @MainActor (T) -> Void) -> Binding<T> {
        Binding(
            get: { get() },
            set: { set($0) }
        )
    }
}
