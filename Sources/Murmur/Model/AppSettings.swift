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

    /// The journal author's gender, used only to pick the third-person pronouns a
    /// caption or the assistant uses when it refers to them. `.unset` means the
    /// profile hasn't been filled in yet (it gates onboarding); it is never offered
    /// as a pickable option. "Prefer not to say" maps to `.unspecified`, which —
    /// like a real neutral choice — uses they/them.
    enum Gender: String, CaseIterable, Identifiable {
        case unset
        case male
        case female
        case unspecified   // "Prefer not to say" → gender-neutral pronouns

        var id: String { rawValue }

        /// The three options shown in the picker, in display order. `.unset` is
        /// deliberately absent — it only exists to detect an unconfigured profile.
        static var choices: [Gender] { [.male, .female, .unspecified] }

        var label: String {
            switch self {
            case .unset: return ""
            case .male: return "Male"
            case .female: return "Female"
            case .unspecified: return "Prefer not to say"
            }
        }

        var subjectPronoun: String {   // he / she / they
            switch self {
            case .male: return "he"
            case .female: return "she"
            default: return "they"
            }
        }
        var objectPronoun: String {    // him / her / them
            switch self {
            case .male: return "him"
            case .female: return "her"
            default: return "them"
            }
        }
        var possessivePronoun: String {   // his / her / their
            switch self {
            case .male: return "his"
            case .female: return "her"
            default: return "their"
            }
        }
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

    // Who the journal belongs to. Fed into caption and assistant prompts so the
    // model refers to the author by name and with the right pronouns. Both must be
    // set before the app opens (see `profileComplete`, which gates onboarding).
    @Published var authorName: String {
        didSet { UserDefaults.standard.set(authorName, forKey: "MurmurAuthorName") }
    }
    @Published var gender: Gender {
        didSet { UserDefaults.standard.set(gender.rawValue, forKey: "MurmurGender") }
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
        authorName = defaults.string(forKey: "MurmurAuthorName") ?? ""
        gender = Gender(rawValue: defaults.string(forKey: "MurmurGender") ?? "") ?? .unset
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

    /// The author's name with surrounding whitespace stripped, or nil if blank.
    var trimmedName: String? {
        let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// True once both name and gender have been chosen. Onboarding stays up until
    /// this holds (alongside the model checks) — see `RootView`.
    var profileComplete: Bool {
        trimmedName != nil && gender != .unset
    }

    /// A one-sentence description of the author, injected into caption and
    /// assistant prompts so the model uses the right name and pronouns. Empty when
    /// the name isn't set, so prompts never carry a blank placeholder.
    var authorPersona: String {
        guard let name = trimmedName else {
            return ""
        }
        let subject = gender.subjectPronoun
        let example = subject.prefix(1).uppercased() + subject.dropFirst()
        return "The journal's author is \(name). When a summary or answer refers to the author, use \(subject)/\(gender.objectPronoun)/\(gender.possessivePronoun) pronouns (e.g. \"\(example) reflected on the day…\")."
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
