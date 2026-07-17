import SwiftUI

/// User preferences that aren't part of the library data — currently the accent
/// theme. Persisted in UserDefaults and applied as the app-wide tint.
@MainActor
final class AppSettings: ObservableObject {
    /// A named accent, grouped into blue / pink / teal families so the picker
    /// reads as "shades of" each.
    struct Theme: Identifiable, Hashable {
        let id: String
        let name: String
        let family: String
        let hex: UInt32
        var color: Color { Color(hex: hex) }
    }

    static let themes: [Theme] = [
        Theme(id: "blue", name: "Blue", family: "Blue", hex: 0x2F7BF6),
        Theme(id: "pink", name: "Pink", family: "Pink", hex: 0xE85B9A),
        Theme(id: "teal", name: "Teal", family: "Teal", hex: 0x14A5A0),
    ]

    static let defaultThemeID = "blue"   // blue tint by default

    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "MurmurTheme") }
    }

    // Custom captioning prompts. When enabled (and non-blank), these override the
    // built-in guidance for that field, in both import and manual regeneration.
    @Published var customTitleEnabled: Bool {
        didSet { UserDefaults.standard.set(customTitleEnabled, forKey: "MurmurCustomTitleEnabled") }
    }
    @Published var customTitlePrompt: String {
        didSet { UserDefaults.standard.set(customTitlePrompt, forKey: "MurmurCustomTitlePrompt") }
    }
    @Published var customSummaryEnabled: Bool {
        didSet { UserDefaults.standard.set(customSummaryEnabled, forKey: "MurmurCustomSummaryEnabled") }
    }
    @Published var customSummaryPrompt: String {
        didSet { UserDefaults.standard.set(customSummaryPrompt, forKey: "MurmurCustomSummaryPrompt") }
    }

    init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "MurmurTheme") ?? Self.defaultThemeID
        customTitleEnabled = defaults.bool(forKey: "MurmurCustomTitleEnabled")
        customTitlePrompt = defaults.string(forKey: "MurmurCustomTitlePrompt") ?? ""
        customSummaryEnabled = defaults.bool(forKey: "MurmurCustomSummaryEnabled")
        customSummaryPrompt = defaults.string(forKey: "MurmurCustomSummaryPrompt") ?? ""
    }

    /// The custom title guidance to use, or nil to fall back to the default.
    var effectiveTitlePrompt: String? {
        let trimmed = customTitlePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return customTitleEnabled && !trimmed.isEmpty ? trimmed : nil
    }
    var effectiveSummaryPrompt: String? {
        let trimmed = customSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return customSummaryEnabled && !trimmed.isEmpty ? trimmed : nil
    }

    var theme: Theme {
        Self.themes.first { $0.id == themeID } ?? Self.themes[0]
    }

    var accent: Color { theme.color }

    /// A soft wash of the accent for card/section backgrounds.
    var accentWash: Color { theme.color.opacity(0.14) }

    /// A very light tint for large surfaces (sidebar, feed) so the whole app
    /// reads in the chosen colour without overwhelming the text.
    var surfaceTint: Color { theme.color.opacity(0.07) }

    /// A top-down accent gradient used as a banner behind entry headers.
    var headerGradient: LinearGradient {
        LinearGradient(
            colors: [theme.color.opacity(0.28), theme.color.opacity(0.04), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension Color {
    /// Builds a color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
