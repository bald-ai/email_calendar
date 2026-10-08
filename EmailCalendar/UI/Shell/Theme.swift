#if os(macOS)
import AppKit
import SwiftUI

/// A calm, single-column look: dark slate by default, with a light counterpart.
enum Theme {
    static let window = dynamic(light: 0xF3F2EE, dark: 0x1D2129)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x252A33)
    static let raised = dynamic(light: 0xF6F5F1, dark: 0x2C323C)
    static let hover = dynamic(light: 0xEFEEE9, dark: 0x2F3540)
    static let line = dynamic(light: 0xE2E0D9, dark: 0x363C47)
    static let text = dynamic(light: 0x1E2026, dark: 0xF1F2F4)
    static let secondary = dynamic(light: 0x6B6F78, dark: 0x9BA1AD)
    static let accent = Color(hex: 0x6C5CE7)
    static let rule = dynamic(light: 0x5B7BE0, dark: 0x5872D8)
    static let unread = Color(hex: 0xF5A524)
    static let back = Color(hex: 0x8FE3C9)
    static let yes = Color(hex: 0x3FB37F)
    static let no = Color(hex: 0xE5534B)
    static let actionBar = dynamic(light: 0x2A2F3A, dark: 0x1A1E26)
    static let menuGradient = LinearGradient(colors: [Color(hex: 0x6AA2F7), Color(hex: 0x7B6CF0)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    private static let avatarPalette: [UInt32] = [0xF08C6B, 0xF2C94C, 0x5AA9E6, 0x7BC74D, 0xE86FA8, 0x4FC3A1, 0x9B7BEA, 0xE5534B, 0xF2994A]

    static func avatarColor(for key: String) -> Color {
        let hash = key.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hex: avatarPalette[Int(hash % UInt32(avatarPalette.count))])
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "@" || $0 == "|" })
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// "2:25pm" today, "Oct 7" otherwise.
    static func shortDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute()).lowercased().replacingOccurrences(of: " ", with: "")
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct Avatar: View {
    var name: String
    var key: String
    var size: CGFloat = 34

    var body: some View {
        let color = Theme.avatarColor(for: key)
        Circle().fill(color)
            .overlay(Text(Theme.initials(name)).font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(color == Color(hex: 0xF2C94C) ? Color.black.opacity(0.75) : .white))
            .frame(width: size, height: size)
    }
}

/// A centered page title with optional hairlines on both sides, as on Set Aside or Bubble Up.
struct PageTitle: View {
    var title: String
    var subtitle: String?
    var ruled = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                if ruled { Rectangle().fill(Theme.rule).frame(height: 1) }
                Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.text).fixedSize()
                if ruled { Rectangle().fill(Theme.rule).frame(height: 1) }
            }
            if let subtitle { Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.85)) }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Theme.text).opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}
#endif
