import AppKit

enum StatusIconRenderer {
    static func separateIcon(for provider: ProviderKind, snapshot: ProviderSnapshot) -> NSImage {
        let size = NSSize(width: 36, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
        background.fill()

        let accentColor = provider.accentNSColor

        // Progress bar at bottom
        let progress = snapshot.maxPercentUsed ?? 0
        let barY: CGFloat = 2.5
        let barHeight: CGFloat = 2
        let barWidth: CGFloat = 28

        // Track
        let trackRect = NSRect(x: 4, y: barY, width: barWidth, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        trackPath.fill()

        // Fill
        if progress > 0 {
            let fillWidth = max(2, barWidth * progress)
            let fillColor = progress > 0.85 ? NSColor.systemRed : accentColor
            let fillRect = NSRect(x: 4, y: barY, width: fillWidth, height: barHeight)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1)
            fillColor.setFill()
            fillPath.fill()
        }

        // Label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: accentColor,
        ]
        let label = provider.shortLabel as NSString
        let labelSize = label.size(withAttributes: attributes)
        let labelX = (size.width - labelSize.width) / 2
        label.draw(at: NSPoint(x: labelX, y: 6), withAttributes: attributes)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func mergedIcon(snapshots: [ProviderSnapshot]) -> NSImage {
        let count = max(snapshots.count, 1)
        let dotSize: CGFloat = 5
        let dotSpacing: CGFloat = 3
        let padding: CGFloat = 5
        let width = padding * 2 + CGFloat(count) * dotSize + CGFloat(max(0, count - 1)) * dotSpacing
        let size = NSSize(width: max(width, 22), height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let sortedSnapshots = snapshots.sorted { $0.provider.rawValue < $1.provider.rawValue }
        let startX = (size.width - (CGFloat(sortedSnapshots.count) * dotSize + CGFloat(max(0, sortedSnapshots.count - 1)) * dotSpacing)) / 2

        for (index, snapshot) in sortedSnapshots.enumerated() {
            let percent = snapshot.maxPercentUsed ?? 0
            let accentColor = snapshot.provider.accentNSColor

            let x = startX + CGFloat(index) * (dotSize + dotSpacing)
            let dotRect = NSRect(x: x, y: (size.height - dotSize) / 2, width: dotSize, height: dotSize)

            // Draw filled dot with opacity based on usage
            let fillColor: NSColor
            if percent > 0.85 {
                fillColor = NSColor.systemRed
            } else if percent > 0 {
                fillColor = accentColor
            } else {
                fillColor = accentColor.withAlphaComponent(0.35)
            }

            let dotPath = NSBezierPath(ovalIn: dotRect)
            fillColor.setFill()
            dotPath.fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
