import AppKit
import SwiftUI

extension ProviderKind {
    var accentColor: Color {
        Color(nsColor: accentNSColor)
    }

    var accentNSColor: NSColor {
        switch self {
        case .codex:
            return NSColor(calibratedRed: 0.10, green: 0.46, blue: 0.90, alpha: 1)
        case .claude:
            return NSColor(calibratedRed: 0.84, green: 0.42, blue: 0.21, alpha: 1)
        case .antigravity:
            return NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.40, alpha: 1)
        case .windsurf:
            return NSColor(calibratedRed: 0.53, green: 0.24, blue: 0.88, alpha: 1)
        }
    }
}
