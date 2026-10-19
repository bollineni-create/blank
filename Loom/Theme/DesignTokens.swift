import SwiftUI
import CoreText

/// Loom's design tokens in the Kiln language from the published design system (Loom Design Languages):
/// bisque clay, terracotta glaze, a celadon second hue, DM Serif Display titles over Figtree text.
enum Theme {
    // MARK: Color

    /// `kiln-ground`: the bisque canvas behind the map, the side panel, every page.
    static let background = Color(light: 0xf3e9df, dark: 0x1b1411)
    /// `kiln-surface`: raised tiles on background: item cards, branch pills, search results, panels.
    static let surface = Color(light: 0xfbf5ef, dark: 0x261c17)
    /// Recessed fills: input fields, chips, count capsules.
    static let surfaceSunken = Color(light: 0xeadccf, dark: 0x211814)

    /// `kiln-ink`.
    static let label = Color(light: 0x2b1d16, dark: 0xf3e6da)
    /// `kiln-muted`: kinds, dates, counts.
    static let labelSecondary = Color(light: 0x6e574a, dark: 0xb9a291)
    /// Timestamps and sizes beside a stronger label only (below 4.5:1).
    static let labelTertiary = Color(light: 0x9c8574, dark: 0x7d6758)

    /// `kiln-line`: 1px borders on tiles, pills, panels and dividers.
    static let hairline = Color(light: 0xe0cfc0, dark: 0x3b2d25)
    static let mapDot = Color(light: Color(hex: 0x2b1d16, opacity: 0.1), dark: Color(hex: 0xf3e6da, opacity: 0.1))

    /// `kiln-accent`, terracotta. Fills only: capture button, prominent buttons, selection.
    static let accent = Color(light: 0xb5502c, dark: 0xe07a52)
    /// `kiln-accent-ink`: terracotta for text and small symbols: citations, links, the sparkles mark.
    static let accentInk = Color(light: 0x9c4223, dark: 0xf0946f)
    /// Deeper clay: end stop of the signature gradient.
    static let accentDeep = Color(light: 0x7e3219, dark: 0xb5502c)
    /// `kiln-on-accent`.
    static let onAccent = Color(light: 0xffffff, dark: 0x1b0e08)
    /// Soft terracotta fill for tag chips and badges (text on it stays `label`).
    static let accentTint = Color(light: Color(hex: 0xb5502c, opacity: 0.12), dark: Color(hex: 0xe07a52, opacity: 0.16))
    /// `kiln-signal`, celadon glaze: the second hue for branches and highlights.
    static let signal = Color(light: 0x2a7471, dark: 0x6cc2bd)

    static let glowSignal = Color(light: Color(hex: 0x2a7471, opacity: 0.18), dark: Color(hex: 0x6cc2bd, opacity: 0.22))
    static let glowAccent = Color(light: Color(hex: 0xb5502c, opacity: 0.16), dark: Color(hex: 0xe07a52, opacity: 0.2))

    static let statusReady = Color(light: 0x34c759, dark: 0x30d158)
    static let statusWarning = Color(light: 0xff9500, dark: 0xff9f0a)
    /// Activity dot: orange while the AI is working, red while files are being added.
    static let statusBusy = statusWarning
    static let statusUploading = Color(light: 0xff3b30, dark: 0xff453a)
    static let favorite = Color(light: 0xffcc00, dark: 0xffd60a)
    static let destructive = Color(light: 0xff3b30, dark: 0xff453a)

    /// The signature gradient (terracotta → deep clay, top-left to bottom-right). Root node and capture button only.
    static let signature = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The light behind search and at the map center: celadon into terracotta, then transparent.
    static func glow(radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [.init(color: glowSignal, location: 0),
                               .init(color: glowAccent, location: 0.45),
                               .init(color: .clear, location: 1)],
                       center: .center, startRadius: 0, endRadius: radius)
    }

    /// Branch palette: glazes that topics and spaces take in order, repeating after 10. Celadon leads.
    /// Only ever a dot, edge, badge or selection ring next to `label` text.
    static let branches: [Color] = [
        signal, Color(hex: 0xc98a2b), Color(hex: 0x4f78ad), Color(hex: 0xa64d6c), Color(hex: 0x6f8f3a),
        Color(hex: 0x7a5cae), Color(hex: 0xd06a3c), Color(hex: 0x3a9aa6), Color(hex: 0x8b6b4a), Color(hex: 0xb84a4a),
    ]

    static func branch(_ index: Int) -> Color {
        branches[((index % branches.count) + branches.count) % branches.count]
    }

    // MARK: Radius

    enum Radius {
        static let badge: CGFloat = 6
        /// `kiln-radius` (14) on controls, panels and cards.
        static let control: CGFloat = 14
        static let panel: CGFloat = 14
        static let card: CGFloat = 14
        static let sheet: CGFloat = 22
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

    // MARK: Fonts

    /// Registers the bundled Kiln faces (DM Serif Display, Figtree) for this process. Safe to call more than once.
    static func registerFonts() { _ = fontsRegistered }

    private static let fontsRegistered: Void = {
        for name in ["DMSerifDisplay-Regular", "Figtree-Variable"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

// MARK: - Type

extension Font {
    /// Onboarding and empty-screen headlines. One per screen.
    static let loomDisplay = Font.custom("DM Serif Display", size: 40, relativeTo: .largeTitle)
    /// Panel titles: an item's title, "Ask your library" (`kiln-display`).
    static let loomTitle = Font.custom("DM Serif Display", size: 28, relativeTo: .title)
    /// "My Brain", empty-state titles, section heads.
    static let loomTitle3 = Font.custom("DM Serif Display", size: 20, relativeTo: .title3)
    /// Summaries, takeaways and notes (`kiln-body`); the default for text without its own font.
    /// Figtree is one variable file whose default instance is Light, so the weight is set explicitly.
    static let loomBody = Font.custom("Figtree", size: 15, relativeTo: .body).weight(.regular)
}

extension View {
    /// Serif voice: regular weight with slight negative tracking.
    func serifTracking() -> some View { tracking(-0.3) }
}

// MARK: - Elevation

extension View {
    /// Tiles at rest or hovered/selected: soft, low shadows like objects on a shelf.
    func tileShadow(lifted: Bool = false) -> some View {
        self
            .shadow(color: Color(hex: 0x2b1d16, opacity: lifted ? 0.05 : 0.04), radius: lifted ? 2 : 1, y: lifted ? 2 : 1)
            .shadow(color: Color(hex: 0x2b1d16, opacity: lifted ? 0.09 : 0.05), radius: lifted ? 18 : 10, y: lifted ? 14 : 6)
    }

    /// Floating chrome over the map (`shadow-float`).
    func floatShadow() -> some View {
        shadow(color: Color(hex: 0x2b1d16, opacity: 0.1), radius: 20, y: 10)
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
