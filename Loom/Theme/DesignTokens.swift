import SwiftUI
import CoreText

/// Loom's design tokens. Colours, corners and type come from the theme picked in Settings (`Themes.swift`);
/// status colours, spacing and elevation are shared by every theme.
enum Theme {
    /// The look picked in Settings. Reading it from a view's body redraws that view when it changes.
    static var current: LoomTheme { ThemeStore.shared.theme }
    /// The current language's map, depth, icon and motion choices.
    static var style: ThemeStyle { current.style }
    /// The current language's motion: page-turn fades, mechanical snaps, springs.
    static var motion: Animation { current.style.motion }

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

    /// The signature gradient (accent → accent-deep, top-left to bottom-right) where the language has one,
    /// flat accent otherwise. Root node and capture button only.
    static var signature: LinearGradient {
        LinearGradient(colors: [accent, style.gradient ? accentDeep : accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Tile and chrome outlines: `line`, or `ink` for languages drawn in ink outlines.
    static var outline: Color { style.inkOutline ? label : hairline }

    /// Terrazzo's chips and Riso's highlight, and the text that sits on them.
    static func chip(_ index: Int) -> Color {
        let chips = current.style.chips
        guard !chips.isEmpty else { return surface }
        return chips[((index % chips.count) + chips.count) % chips.count].color
    }
    static var onChip: Color { current.style.onChip?.color ?? label }

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
        /// Pills and round buttons: fully round, or the language's corner where it is small or square.
        static var pill: CGFloat { Theme.current.corner.map { $0 >= 14 ? 999 : $0 } ?? 999 }
    }

    /// The shape of search, ask, chips and round buttons: a capsule, or the language's own corner.
    static var pillShape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.pill) }

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
    /// Kinds, counts, dates and tags, in the language's label voice. Pair with `loomLabelCase()`.
    static var loomLabel: Font {
        let t = Theme.current
        return t.label.font(size: t.labelSize, relativeTo: .caption)
    }
    /// Summaries, takeaways and notes; the default for text without its own font.
    static var loomBody: Font {
        let t = Theme.current
        return t.body.family == nil ? .body : t.body.font(size: t.bodySize, relativeTo: .body)
    }
}

extension View {
    /// The display voice's tracking (slightly negative for most themes), in capitals where the language sets titles so.
    func serifTracking() -> some View {
        tracking(Theme.current.display.tracking)
            .textCase(Theme.style.displayCaps ? .uppercase : nil)
    }

    /// The label voice: font, tracking and, for tracked mono and small-caps languages, capitals.
    func loomLabel() -> some View {
        font(.loomLabel)
            .tracking(Theme.current.label.tracking)
            .textCase(Theme.style.labelCaps ? .uppercase : nil)
    }

    /// SF Symbols in the language's weight, filled where it prefers filled glyphs.
    func loomSymbols() -> some View {
        fontWeight(Theme.style.symbolWeight)
            .symbolVariant(Theme.style.filledSymbols ? .fill : .none)
    }
}

// MARK: - Elevation

extension View {
    /// Tiles at rest (`shadow-tile`) or hovered/selected (`shadow-tile-hover`), in the language's depth:
    /// soft light, a low shelf shadow, a hard offset print, a wide frosted blur, or none.
    func tileShadow(lifted: Bool = false) -> some View {
        let ink = Theme.current.ink.light
        var near = TileShadow.none, far = TileShadow.none
        switch Theme.style.depth {
        case .soft:
            near = TileShadow(Color(hex: ink, opacity: lifted ? 0.05 : 0.04), lifted ? 2 : 1, 0, lifted ? 2 : 1)
            far = TileShadow(Color(hex: ink, opacity: lifted ? 0.09 : 0.05), lifted ? 18 : 10, 0, lifted ? 14 : 6)
        case .low:
            near = TileShadow(Theme.hairline, 0, 0, 2)
            far = TileShadow(Color(hex: ink, opacity: lifted ? 0.14 : 0.08), lifted ? 8 : 5, 0, lifted ? 6 : 4)
        case .flat:
            break
        case .hard(let x, let y, let accent):
            near = TileShadow(accent ? Theme.accent : Theme.label, 0, lifted ? x * 1.5 : x, lifted ? y * 1.5 : y)
        case .frost:
            far = TileShadow(Color(hex: ink, opacity: lifted ? 0.1 : 0.06), lifted ? 24 : 16, 0, lifted ? 12 : 8)
        }
        return self
            .shadow(color: near.color, radius: near.radius, x: near.x, y: near.y)
            .shadow(color: far.color, radius: far.radius, x: far.x, y: far.y)
    }

    /// Floating chrome over the map (`shadow-float`), or the language's own depth.
    @ViewBuilder
    func floatShadow() -> some View {
        if Theme.style.depth == .soft {
            shadow(color: Color(hex: Theme.current.ink.light, opacity: 0.1), radius: 20, y: 10)
        } else {
            tileShadow()
        }
    }

    /// An opaque `surface` tile with the language's outline, inner rule and depth (frosted for Mist).
    func surfaceTile<S: InsettableShape>(_ shape: S, lifted: Bool = false) -> some View {
        let style = Theme.style
        return self
            .background {
                if style.depth == .frost {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Theme.current.surface.opacity(0.72, 0.66).color)
                    }
                } else {
                    shape.fill(Theme.surface)
                }
            }
            .overlay {
                if style.outline > 0 { shape.strokeBorder(Theme.outline, lineWidth: style.outline) }
            }
            .overlay {
                if style.innerRule { shape.inset(by: 3).strokeBorder(Theme.hairline, lineWidth: 0.5) }
            }
            .tileShadow(lifted: lifted)
    }

    /// Floating chrome: Liquid Glass on iOS 26 / macOS 26 and later, regular material plus hairline before that.
    /// Pass `tint` only for the one primary action (the capture button).
    /// Pass `interactive: false` for a bar that holds its own buttons: interactive glass takes the touch on iPhone.
    /// Languages without glass (print, paper, clay) float the same opaque tiles they use everywhere else.
    @ViewBuilder
    func floatingChrome<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if Theme.style.glass {
            glassChrome(shape, tint: tint, interactive: interactive)
        } else {
            background(tint ?? .clear, in: shape).surfaceTile(shape)
        }
    }

    @ViewBuilder
    private func glassChrome<S: InsettableShape>(_ shape: S, tint: Color?, interactive: Bool) -> some View {
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
        if Theme.style.glass {
            glassGroup
        } else {
            content
        }
    }

    @ViewBuilder
    private var glassGroup: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// One drop shadow: colour, blur radius and offset.
private struct TileShadow {
    var color: Color
    var radius: CGFloat
    var x: CGFloat
    var y: CGFloat

    init(_ color: Color, _ radius: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        self.color = color; self.radius = radius; self.x = x; self.y = y
    }

    static let none = TileShadow(.clear, 0, 0, 0)
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
