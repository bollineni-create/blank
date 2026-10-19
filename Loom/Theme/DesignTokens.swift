import SwiftUI
import CoreText

/// Loom's design tokens. Colours, corners and type come from the theme picked in Settings (`Themes.swift`);
/// status colours, spacing and elevation are shared by every theme.
enum Theme {
    /// The look picked in Settings. Reading it from a view's body redraws that view when it changes.
    static var current: LoomTheme { ThemeStore.shared.theme }

    // MARK: Color

    /// The canvas: the map, the side panel, every page.
    static var background: Color { current.ground.color }
    /// Raised tiles on background: item cards, branch pills, search results, panels.
    static var surface: Color { current.surface.color }
    /// Recessed fills: input fields, chips, count capsules.
    static var surfaceSunken: Color { current.sunken.color }

    static var label: Color { current.ink.color }
    static var labelSecondary: Color { current.muted.color }
    /// Timestamps and sizes beside a stronger label only (below 4.5:1).
    static var labelTertiary: Color { current.faint.color }

    /// 1px borders on tiles, pills, panels and dividers.
    static var hairline: Color { current.line.color }
    static var mapDot: Color { current.ink.opacity(0.1, 0.1).color }

    /// The one primary fill: capture button, prominent buttons, selection.
    static var accent: Color { current.accent.color }
    /// The accent as text and small symbols: citations, links, the sparkles mark.
    static var accentInk: Color { current.accentInk.color }
    /// Far end of the signature gradient.
    static var accentDeep: Color { current.accentDeep.color }
    static var onAccent: Color { current.onAccent.color }
    /// Soft accent fill for tag chips and badges (text on it stays `label`).
    static var accentTint: Color { current.accentTint.color }
    /// The theme's second hue: first branch colour and highlights.
    static var signal: Color { current.signal.color }

    static var glowInner: Color { current.glowInner.color }
    static var glowOuter: Color { current.glowOuter.color }

    static let statusReady = Color(light: 0x34c759, dark: 0x30d158)
    static let statusWarning = Color(light: 0xff9500, dark: 0xff9f0a)
    /// Activity dot: orange while the AI is working, red while files are being added.
    static let statusBusy = statusWarning
    static let statusUploading = Color(light: 0xff3b30, dark: 0xff453a)
    static let favorite = Color(light: 0xffcc00, dark: 0xffd60a)
    static let destructive = Color(light: 0xff3b30, dark: 0xff453a)

    /// The signature gradient (accent → accent-deep, top-left to bottom-right). Root node and capture button only.
    static var signature: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The light behind search and at the map center, then transparent.
    static func glow(radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [.init(color: glowInner, location: 0),
                               .init(color: glowOuter, location: 0.45),
                               .init(color: .clear, location: 1)],
                       center: .center, startRadius: 0, endRadius: radius)
    }

    /// Branch palette: topics and spaces take these in order and repeat after 10.
    /// Only ever a dot, edge, badge or selection ring next to `label` text.
    static var branches: [Color] { current.branches.map { Color(hex: $0) } }

    static func branch(_ index: Int) -> Color {
        branches[((index % branches.count) + branches.count) % branches.count]
    }

    // MARK: Radius

    /// Loom's own scale, or the theme's one radius on controls, panels and cards.
    enum Radius {
        static var badge: CGFloat { Theme.current.corner.map { min($0, 6) } ?? 6 }
        static var control: CGFloat { Theme.current.corner ?? 12 }
        static var panel: CGFloat { Theme.current.corner ?? 16 }
        static var card: CGFloat { Theme.current.corner ?? 20 }
        static var sheet: CGFloat { Theme.current.corner.map { $0 == 0 ? 0 : $0 + 8 } ?? 28 }
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

    /// Registers the bundled theme fonts (Resources/Fonts) for this process. Safe to call more than once.
    static func registerFonts() { _ = fontsRegistered }

    private static let fontsRegistered: Void = {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

// MARK: - Type

extension Font {
    /// Onboarding and empty-screen headlines. One per screen.
    static var loomDisplay: Font {
        let t = Theme.current
        return t.display.font(size: t.displaySize + 6, relativeTo: .largeTitle)
    }
    /// Panel titles: an item's title, "Ask your library".
    static var loomTitle: Font {
        let t = Theme.current
        return t.display.font(size: min(28, t.displaySize), relativeTo: .title)
    }
    /// "My Brain", empty-state titles, section heads.
    static var loomTitle3: Font { Theme.current.display.font(size: 20, relativeTo: .title3) }
    /// Summaries, takeaways and notes; the default for text without its own font.
    static var loomBody: Font {
        let t = Theme.current
        return t.body.family == nil ? .body : t.body.font(size: t.bodySize, relativeTo: .body)
    }
}

extension View {
    /// The display voice's tracking (slightly negative for most themes).
    func serifTracking() -> some View { tracking(Theme.current.display.tracking) }
}

// MARK: - Elevation

extension View {
    /// Tiles at rest (`shadow-tile`) or hovered/selected (`shadow-tile-hover`).
    func tileShadow(lifted: Bool = false) -> some View {
        self
            .shadow(color: Color(hex: Theme.current.ink.light, opacity: lifted ? 0.05 : 0.04), radius: lifted ? 2 : 1, y: lifted ? 2 : 1)
            .shadow(color: Color(hex: Theme.current.ink.light, opacity: lifted ? 0.09 : 0.05), radius: lifted ? 18 : 10, y: lifted ? 14 : 6)
    }

    /// Floating chrome over the map (`shadow-float`).
    func floatShadow() -> some View {
        shadow(color: Color(hex: Theme.current.ink.light, opacity: 0.1), radius: 20, y: 10)
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
