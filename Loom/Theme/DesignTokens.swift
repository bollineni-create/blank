import SwiftUI

/// Loom's design tokens, mirroring the published design system (project/tokens.json):
/// warm paper, white tiles with hairlines, serif headlines, and coral + violet only where Loom speaks.
enum Theme {
    // MARK: Color

    /// The warm paper canvas: the map, the side panel, every page. Never pure white.
    static let background = Color(light: 0xfaf8f5, dark: 0x141312)
    /// Raised tiles on background: item cards, branch pills, search results, panels.
    static let surface = Color(light: 0xffffff, dark: 0x1f1d1b)
    /// Recessed fills: input fields, chips, count capsules.
    static let surfaceSunken = Color(light: 0xf2efea, dark: 0x191816)

    static let label = Color(light: 0x1c1b19, dark: 0xf4f2ee)
    static let labelSecondary = Color(light: 0x6b6862, dark: 0xa8a49d)
    /// Timestamps and sizes beside a stronger label only (below 4.5:1).
    static let labelTertiary = Color(light: 0x9b978f, dark: 0x6e6a64)

    /// 1px borders on tiles, pills, panels and dividers.
    static let hairline = Color(light: Color(hex: 0x1c1b19, opacity: 0.08), dark: Color(hex: 0xf4f2ee, opacity: 0.1))
    static let mapDot = Color(light: Color(hex: 0x1c1b19, opacity: 0.1), dark: Color(hex: 0xf4f2ee, opacity: 0.1))

    /// Loom coral. Fills only: capture button, prominent buttons, selection.
    static let accent = Color(hex: 0xe84f61)
    /// Coral for text and small symbols: citations, links, the sparkles mark.
    static let accentInk = Color(light: 0xc4384b, dark: 0xff8a97)
    /// Loom violet: end stop of the signature gradient and the glow.
    static let accentViolet = Color(hex: 0x8c61f2)
    static let onAccent = Color.white
    /// Soft coral fill for tag chips and badges (text on it stays `label`).
    static let accentTint = Color(light: Color(hex: 0xe84f61, opacity: 0.12), dark: Color(hex: 0xff8a97, opacity: 0.16))

    static let glowViolet = Color(light: Color(hex: 0x8c61f2, opacity: 0.28), dark: Color(hex: 0x8c61f2, opacity: 0.36))
    static let glowCoral = Color(light: Color(hex: 0xe84f61, opacity: 0.16), dark: Color(hex: 0xe84f61, opacity: 0.22))

    static let statusReady = Color(light: 0x34c759, dark: 0x30d158)
    static let statusWarning = Color(light: 0xff9500, dark: 0xff9f0a)
    /// Activity dot: orange while the AI is working, red while files are being added.
    static let statusBusy = statusWarning
    static let statusUploading = Color(light: 0xff3b30, dark: 0xff453a)
    static let favorite = Color(light: 0xffcc00, dark: 0xffd60a)
    static let destructive = Color(light: 0xff3b30, dark: 0xff453a)

    /// The signature gradient (accent → accent-violet, top-left to bottom-right). Root node and capture button only.
    static let signature = LinearGradient(colors: [accent, accentViolet], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The light behind search and at the map center: violet into coral, then transparent.
    static func glow(radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [.init(color: glowViolet, location: 0),
                               .init(color: glowCoral, location: 0.45),
                               .init(color: .clear, location: 1)],
                       center: .center, startRadius: 0, endRadius: radius)
    }

    /// Branch palette: topics and spaces take these in order and repeat after 10.
    /// Only ever a dot, edge, badge or selection ring next to `label` text.
    static let branches: [Color] = [
        Color(hex: 0xfa734a), Color(hex: 0x4085f5), Color(hex: 0x29b380), Color(hex: 0xe6529e), accentViolet,
        Color(hex: 0x14a8bf), Color(hex: 0xf2a821), Color(hex: 0x5c6bdb), Color(hex: 0xd9404d), Color(hex: 0x6bb333),
    ]

    static func branch(_ index: Int) -> Color {
        branches[((index % branches.count) + branches.count) % branches.count]
    }

    // MARK: Radius

    enum Radius {
        static let badge: CGFloat = 6
        static let control: CGFloat = 12
        static let panel: CGFloat = 16
        static let card: CGFloat = 20
        static let sheet: CGFloat = 28
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

extension Font {
    /// Onboarding and empty-screen headlines. One per screen.
    static let loomDisplay = Font.system(size: 44, weight: .regular, design: .serif)
    /// Panel titles: an item's title, "Ask your library".
    static let loomTitle = Font.system(.title, design: .serif)
    /// "My Brain", empty-state titles, section heads.
    static let loomTitle3 = Font.system(.title3, design: .serif)
}

extension View {
    /// Serif voice: regular weight with slight negative tracking.
    func serifTracking() -> some View { tracking(-0.2) }
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
    @ViewBuilder
    func floatingChrome<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
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
