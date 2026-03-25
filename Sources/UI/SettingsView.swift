import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var store: ProviderStore

    var body: some View {
        ScrollView {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 14) {
                    displayGroup
                    alertsGroup
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

    private var alertsGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Alerts")
                .font(.subheadline.weight(.semibold))

            Toggle("Enable notifications", isOn: binding(
                get: { store.settingsStore.settings.alertSettings.enabled },
                set: { newVal in store.settingsStore.update { s in s.alertSettings.enabled = newVal } }
            ))
            .font(.caption)

            if store.settingsStore.settings.alertSettings.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alert thresholds")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach([70, 80, 85, 90, 95], id: \.self) { threshold in
                            let isActive = store.settingsStore.settings.alertSettings.thresholds.contains(threshold)
                            Button {
                                store.settingsStore.update { s in
                                    if isActive {
                                        s.alertSettings.thresholds.removeAll { $0 == threshold }
                                    } else {
                                        s.alertSettings.thresholds.append(threshold)
                                        s.alertSettings.thresholds.sort()
                                    }
                                }
                            } label: {
                                Text("\(threshold)%")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isActive ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.2))
                                    .foregroundColor(isActive ? .white : .secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !NotificationManager.shared.isAuthorized {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                            Text("Notifications not permitted — click to allow")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        .onTapGesture {
                            NotificationManager.shared.requestPermission()
                        }
                    }
                }
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
