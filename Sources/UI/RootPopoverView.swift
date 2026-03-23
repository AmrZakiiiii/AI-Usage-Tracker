import SwiftUI

enum PopoverSection {
    case provider
    case settings
}

struct RootPopoverView: View {
    @ObservedObject var store: ProviderStore

    @State private var section: PopoverSection
    @State private var selectedProvider: ProviderKind

    init(store: ProviderStore, initialProvider: ProviderKind?) {
        self.store = store
        _section = State(initialValue: .provider)
        _selectedProvider = State(initialValue: initialProvider ?? store.settingsStore.settings.enabledProviders.first ?? .codex)
    }

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider()
                    .opacity(0.3)

                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider()
                    .opacity(0.3)

                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("AI Usage Tracker")
                    .font(.headline)

                Spacer()

                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .buttonStyle(.glass)

                Button {
                    section = section == .settings ? .provider : .settings
                } label: {
                    Image(systemName: section == .settings ? "xmark" : "gearshape")
                        .font(.body)
                }
                .buttonStyle(.glass)
            }

            if section == .provider {
                providerSwitcher
            }
        }
    }

    private var providerSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(enabledProviders) { provider in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedProvider = provider
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(provider.accentColor)
                            .frame(width: 7, height: 7)

                        Text(provider.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    selectedProvider == provider
                        ? .regular.tint(provider.accentColor)
                        : .regular,
                    in: .capsule
                )
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .provider:
            ProviderDetailView(snapshot: store.snapshot(for: selectedProvider))
        case .settings:
            SettingsView(store: store)
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(UsageFormatters.freshnessText(for: store.lastRefreshAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.glass)
        }
    }

    private var enabledProviders: [ProviderKind] {
        let providers = store.settingsStore.settings.enabledProviders
        return providers.isEmpty ? ProviderKind.allCases : providers
    }
}
