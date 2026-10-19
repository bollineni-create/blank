import SwiftUI

/// The look the app wears. Each fills the same roles, so every view works in all of them.
/// The choice lives in UserDefaults under `DesignLanguage.storageKey`; the root views rebuild when it changes.
enum DesignLanguage: String, CaseIterable, Identifiable {
    /// Near-black field, star-white type, brass instruments. Dark-first.
    case observatory
    /// A risograph zine: blue ink and fluorescent pink on cream paper, monospaced throughout.
    case riso
    /// The original look: warm paper, serif headlines, coral and violet.
    case classic

    static let storageKey = "designLanguage"
    static let defaultValue = DesignLanguage.observatory

    static var current: DesignLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(DesignLanguage.init) ?? defaultValue
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .observatory: "Observatory"
        case .riso: "Riso"
        case .classic: "Loom Classic"
        }
    }

    /// The type design for reading text; headlines use `Font.loomDisplay` and friends.
    var bodyDesign: Font.Design {
        self == .riso ? .monospaced : .default
    }

    fileprivate var palette: Palette {
        switch self {
        case .observatory: .observatory
        case .riso: .riso
        case .classic: .classic
        }
    }
}

/// One language's colours. `Theme` reads the current language's palette.
private struct Palette {
    var background, surface, surfaceSunken: Color
    var label, labelSecondary, labelTertiary: Color
    var hairline, mapDot: Color
    var accent, accentInk, accentSecondary, onAccent, accentTint: Color
    var glowPrimary, glowSecondary: Color
    /// Replaces the first branch colour, so the top topic wears the language's signal.
    var firstBranch: Color?

    static let classic = Palette(
        background: Color(light: 0xfaf8f5, dark: 0x141312),
        surface: Color(light: 0xffffff, dark: 0x1f1d1b),
        surfaceSunken: Color(light: 0xf2efea, dark: 0x191816),
        label: Color(light: 0x1c1b19, dark: 0xf4f2ee),
        labelSecondary: Color(light: 0x6b6862, dark: 0xa8a49d),
        labelTertiary: Color(light: 0x9b978f, dark: 0x6e6a64),
        hairline: Color(light: Color(hex: 0x1c1b19, opacity: 0.08), dark: Color(hex: 0xf4f2ee, opacity: 0.1)),
        mapDot: Color(light: Color(hex: 0x1c1b19, opacity: 0.1), dark: Color(hex: 0xf4f2ee, opacity: 0.1)),
        accent: Color(hex: 0xe84f61),
        accentInk: Color(light: 0xc4384b, dark: 0xff8a97),
        accentSecondary: Color(hex: 0x8c61f2),
        onAccent: .white,
        accentTint: Color(light: Color(hex: 0xe84f61, opacity: 0.12), dark: Color(hex: 0xff8a97, opacity: 0.16)),
        glowPrimary: Color(light: Color(hex: 0x8c61f2, opacity: 0.28), dark: Color(hex: 0x8c61f2, opacity: 0.36)),
        glowSecondary: Color(light: Color(hex: 0xe84f61, opacity: 0.16), dark: Color(hex: 0xe84f61, opacity: 0.22)))

    /// obs-* tokens from the Loom Design Languages system.
    static let observatory = Palette(
        background: Color(light: 0xf3f1ec, dark: 0x0b0d12),
        surface: Color(light: 0xffffff, dark: 0x151922),
        surfaceSunken: Color(light: 0xebe8e1, dark: 0x10131a),
        label: Color(light: 0x14161c, dark: 0xece7da),
        labelSecondary: Color(light: 0x555a66, dark: 0x9a9fae),
        labelTertiary: Color(light: 0x8a8e98, dark: 0x6b7080),
        hairline: Color(light: 0xd6d3cc, dark: 0x262c38),
        mapDot: Color(light: Color(hex: 0x14161c, opacity: 0.12), dark: Color(hex: 0xece7da, opacity: 0.14)),
        accent: Color(light: 0xb8741a, dark: 0xf2b54a),
        accentInk: Color(light: 0x8a5410, dark: 0xf5c56f),
        accentSecondary: Color(light: 0x8a5410, dark: 0xc98a2a),
        onAccent: Color(light: 0x14161c, dark: 0x1a1205),
        accentTint: Color(light: Color(hex: 0xb8741a, opacity: 0.14), dark: Color(hex: 0xf2b54a, opacity: 0.16)),
        glowPrimary: Color(light: Color(hex: 0x2f5aa8, opacity: 0.2), dark: Color(hex: 0x8fb0ff, opacity: 0.22)),
        glowSecondary: Color(light: Color(hex: 0xb8741a, opacity: 0.12), dark: Color(hex: 0xf2b54a, opacity: 0.14)),
        firstBranch: Color(light: 0x2f5aa8, dark: 0x8fb0ff))

    /// riso-* tokens from the Loom Design Languages system. Lines are full ink, like a printed outline.
    static let riso = Palette(
        background: Color(light: 0xf5f1e8, dark: 0x17142a),
        surface: Color(light: 0xfffdf8, dark: 0x221e3b),
        surfaceSunken: Color(light: 0xede7da, dark: 0x1c1833),
        label: Color(light: 0x1f2a5c, dark: 0xf5f1e8),
        labelSecondary: Color(light: 0x4a5280, dark: 0xb6b2cf),
        labelTertiary: Color(light: 0x7c82a6, dark: 0x8a86a6),
        hairline: Color(light: 0x1f2a5c, dark: 0xf5f1e8),
        mapDot: Color(light: Color(hex: 0x1f2a5c, opacity: 0.16), dark: Color(hex: 0xf5f1e8, opacity: 0.16)),
        accent: Color(light: 0xd61a86, dark: 0xff5cbc),
        accentInk: Color(light: 0xb5136f, dark: 0xff7dca),
        accentSecondary: Color(light: 0xd61a86, dark: 0xff5cbc),
        onAccent: Color(light: 0xffffff, dark: 0x17142a),
        accentTint: Color(hex: 0xffe800, opacity: 0.55),
        glowPrimary: Color(hex: 0xffe800, opacity: 0.35),
        glowSecondary: Color(light: Color(hex: 0xd61a86, opacity: 0.14), dark: Color(hex: 0xff5cbc, opacity: 0.18)))
}

/// Loom's design tokens, mirroring the published design systems (project/tokens.json).
/// Colours, radii and headline type follow `DesignLanguage.current`.
enum Theme {
    private static var palette: Palette { DesignLanguage.current.palette }

    // MARK: Color

    /// The canvas: the map, the side panel, every page. Never pure white.
    static var background: Color { palette.background }
    /// Raised tiles on background: item cards, branch pills, search results, panels.
    static var surface: Color { palette.surface }
    /// Recessed fills: input fields, chips, count capsules.
    static var surfaceSunken: Color { palette.surfaceSunken }

    static var label: Color { palette.label }
    static var labelSecondary: Color { palette.labelSecondary }
    /// Timestamps and sizes beside a stronger label only (below 4.5:1).
    static var labelTertiary: Color { palette.labelTertiary }

    /// 1px borders on tiles, pills, panels and dividers.
    static var hairline: Color { palette.hairline }
    static var mapDot: Color { palette.mapDot }

    /// The one primary fill: capture button, prominent buttons, selection.
    static var accent: Color { palette.accent }
    /// The accent for text and small symbols: citations, links, the sparkles mark.
    static var accentInk: Color { palette.accentInk }
    /// End stop of the signature gradient.
    static var accentViolet: Color { palette.accentSecondary }
    static var onAccent: Color { palette.onAccent }
    /// Soft fill for tag chips and badges (text on it stays `label`).
    static var accentTint: Color { palette.accentTint }

    static var glowViolet: Color { palette.glowPrimary }
    static var glowCoral: Color { palette.glowSecondary }

    static let statusReady = Color(light: 0x34c759, dark: 0x30d158)
    static let statusWarning = Color(light: 0xff9500, dark: 0xff9f0a)
    /// Activity dot: orange while the AI is working, red while files are being added.
    static let statusBusy = statusWarning
    static let statusUploading = Color(light: 0xff3b30, dark: 0xff453a)
    static let favorite = Color(light: 0xffcc00, dark: 0xffd60a)
    static let destructive = Color(light: 0xff3b30, dark: 0xff453a)

    /// The signature gradient (accent → its second stop, top-left to bottom-right). Root node and capture button only.
    static var signature: LinearGradient {
        LinearGradient(colors: [accent, accentViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The light behind search and at the map center, fading to transparent.
    static func glow(radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [.init(color: glowViolet, location: 0),
                               .init(color: glowCoral, location: 0.45),
                               .init(color: .clear, location: 1)],
                       center: .center, startRadius: 0, endRadius: radius)
    }

    /// Branch palette: topics and spaces take these in order and repeat after 10.
    /// Only ever a dot, edge, badge or selection ring next to `label` text.
    static var branches: [Color] {
        [palette.firstBranch ?? Color(hex: 0xfa734a), Color(hex: 0x4085f5), Color(hex: 0x29b380), Color(hex: 0xe6529e),
         Color(hex: 0x8c61f2), Color(hex: 0x14a8bf), Color(hex: 0xf2a821), Color(hex: 0x5c6bdb), Color(hex: 0xd9404d),
         Color(hex: 0x6bb333)]
    }

    static func branch(_ index: Int) -> Color {
        let colors = branches
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    // MARK: Radius

    /// Classic is soft and round; Observatory uses 10px corners (`obs-radius`), Riso 3px (`riso-radius`).
    enum Radius {
        static var badge: CGFloat { pick(classic: 6, observatory: 4, riso: 2) }
        static var control: CGFloat { pick(classic: 12, observatory: 8, riso: 3) }
        static var panel: CGFloat { pick(classic: 16, observatory: 10, riso: 3) }
        static var card: CGFloat { pick(classic: 20, observatory: 10, riso: 3) }
        static var sheet: CGFloat { pick(classic: 28, observatory: 16, riso: 6) }

        private static func pick(classic: CGFloat, observatory: CGFloat, riso: CGFloat) -> CGFloat {
            switch DesignLanguage.current {
            case .classic: classic
            case .observatory: observatory
            case .riso: riso
            }
        }
    }

    // MARK: Spacing (4px scale)

    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s30: CGFloat = 30
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40
    }

    /// Map nodes that don't match the current search.
    static let dimmedOpacity: Double = 0.2

    /// Item cards on the map are this wide; the thumbnail fills the top.
    static let itemCardWidth: CGFloat = 200
}

// MARK: - Type

// Classic speaks in New York serif. Observatory titles are medium monospace, widely tracked
// (`obs-display`, IBM Plex Mono); Riso is bold monospace throughout (`riso-display`, Space Mono).
// Both use the system's monospaced design (SF Mono) rather than bundled font files.
extension Font {
    /// Onboarding and empty-screen headlines. One per screen.
    static var loomDisplay: Font { headline(size: 44, style: .largeTitle) }
    /// Panel titles: an item's title, "Ask your library".
    static var loomTitle: Font { headline(style: .title) }
    /// "My Brain", empty-state titles, section heads.
    static var loomTitle3: Font { headline(style: .title3) }

    private static func headline(size: CGFloat? = nil, style: Font.TextStyle) -> Font {
        let voice: (design: Font.Design, weight: Font.Weight) = switch DesignLanguage.current {
        case .classic: (.serif, .regular)
        case .observatory: (.monospaced, .medium)
        case .riso: (.monospaced, .bold)
        }
        let (design, weight) = voice
        // Monospace runs wide, so the fixed-size display shrinks to keep headlines on one or two lines.
        if let size { return .system(size: design == .serif ? size : size * 0.7, weight: weight, design: design) }
        return .system(style, design: design, weight: weight)
    }
}

extension View {
    /// The headline voice's tracking: slightly tight for serif and Riso, wide for Observatory.
    func headlineTracking() -> some View {
        let amount: CGFloat = switch DesignLanguage.current {
        case .classic: -0.2
        case .observatory: 1.5
        case .riso: -0.6
        }
        return tracking(amount)
    }
}

// MARK: - Elevation

extension View {
    /// Tiles at rest (`shadow-tile`) or hovered/selected (`shadow-tile-hover`).
    func tileShadow(lifted: Bool = false) -> some View {
        self
            .shadow(color: Color(hex: 0x1c1b19, opacity: lifted ? 0.05 : 0.04), radius: lifted ? 2 : 1, y: lifted ? 2 : 1)
            .shadow(color: Color(hex: 0x1c1b19, opacity: lifted ? 0.09 : 0.05), radius: lifted ? 18 : 10, y: lifted ? 14 : 6)
    }

    /// Floating chrome over the map (`shadow-float`).
    func floatShadow() -> some View {
        shadow(color: Color(hex: 0x1c1b19, opacity: 0.1), radius: 20, y: 10)
    }

    /// An opaque `surface` tile with a hairline edge and a soft shadow.
    func surfaceTile<S: InsettableShape>(_ shape: S, lifted: Bool = false) -> some View {
        self
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .tileShadow(lifted: lifted)
    }

    /// Floating chrome: Liquid Glass on iOS 26 / macOS 26 and later, regular material plus hairline before that.
    /// Pass `tint` only for the one primary action (the capture button).
    /// Pass `interactive: false` for a bar that holds its own buttons: interactive glass takes the touch on iPhone.
    @ViewBuilder
    func floatingChrome<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background(tint ?? .clear, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                .floatShadow()
        }
    }
}

/// Groups neighbouring floating chrome so Liquid Glass shapes merge; a plain container on older systems.
struct ChromeGroup<Content: View>: View {
    var spacing: CGFloat = Theme.Space.s12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: Color(hex: light), dark: Color(hex: dark))
    }

    /// A color that follows the system appearance.
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}
