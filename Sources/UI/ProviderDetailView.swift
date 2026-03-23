import SwiftUI

struct ProviderDetailView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        ScrollView {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 10) {
                    headerSection

                    ForEach(snapshot.windows) { window in
                        windowRow(window)
                    }

                    if snapshot.windows.isEmpty {
                        emptyState
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(snapshot.provider.accentColor)
                    .frame(width: 10, height: 10)

                Text(snapshot.provider.displayName)
                    .font(.title3.weight(.semibold))

                if let badge = snapshot.badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular.tint(snapshot.provider.accentColor), in: .capsule)
                }

                Spacer()

                Text(snapshot.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.status == .ok ? .green : .orange)
            }

            if let account = snapshot.accountLabel, !account.isEmpty {
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = snapshot.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(snapshot.provider.accentColor), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("Updated \(UsageFormatters.freshnessText(for: snapshot.lastUpdated))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(snapshot.sourceDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(window.usageSummary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
                if let percent = window.resolvedPercentUsed {
                    Text("\(Int((percent * 100).rounded()))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(percent > 0.85 ? .red : .secondary)
                }
            }

            if let percent = window.resolvedPercentUsed {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 6)

                        Capsule()
                            .fill(percent > 0.85 ? Color.red : snapshot.provider.accentColor)
                            .frame(width: max(3, geo.size.width * percent), height: 6)
                    }
                }
                .frame(height: 6)
            }

            HStack {
                if let resetDate = window.resetDate {
                    Text(UsageFormatters.relativeResetText(for: resetDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(UsageFormatters.absoluteResetText(for: resetDate))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let note = window.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No usage windows")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("This provider does not have trackable quota data yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
