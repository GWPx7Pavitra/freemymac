import SwiftUI
import FreeMyMacCore

/// Chart colors. The series run in a fixed order, validated for colorblind
/// separation in both appearances, so "Apps" is the same color on every launch
/// whether or not other segments are present.
enum Palette {
    static let series1 = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let series2 = dynamic(light: 0xeb6834, dark: 0xd95926)
    static let series3 = dynamic(light: 0x1baf7a, dark: 0x199e70)
    static let series4 = dynamic(light: 0xeda100, dark: 0xc98500)
    static let series5 = dynamic(light: 0xe87ba4, dark: 0xd55181)
    static let series6 = Color(hex: 0x008300)
    static let neutral = Color(hex: 0x898781)
    static let track = dynamic(light: 0xe1e0d9, dark: 0x2c2c2a)

    static let good = Color(hex: 0x0ca30c)
    static let warning = Color(hex: 0xfab219)
    static let serious = Color(hex: 0xec835a)
    static let critical = Color(hex: 0xd03b3b)

    static func color(for kind: StorageSegment.Kind) -> Color {
        switch kind {
        case .files: return series1
        case .apps: return series2
        case .appData: return series3
        case .developer: return series4
        case .system: return series5
        case .hidden: return series6
        case .macOS: return neutral
        case .free: return track
        }
    }

    /// Ink for a label printed inside a block of the given segment.
    static func labelColor(for kind: StorageSegment.Kind, scheme: ColorScheme) -> Color {
        switch kind {
        case .free: return .secondary
        case .developer: return scheme == .light ? Color(hex: 0x0b0b0b) : .white
        default: return .white
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}
