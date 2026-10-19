import SwiftUI
import Observation

/// The looks you can pick in Settings: Loom's original and the ten design languages from the published
/// design system (Loom Design Languages). Each fills the same roles, so every view works in all of them.
struct LoomTheme: Identifiable, Equatable {
    static func == (a: LoomTheme, b: LoomTheme) -> Bool { a.id == b.id }

    let id: String
    let name: String
    let mood: String

    /// Canvas, raised tiles, text, secondary text, hairlines.
    let ground, surface, ink, muted, line: Tone
    /// The one primary fill, what sits on it, and its colour as text.
    let accent, onAccent, accentInk: Tone
    /// The second hue: first branch colour and the inner glow.
    let signal: Tone
    /// Recessed fills, timestamps (below 4.5:1), and the far end of the signature gradient.
    var sunken, faint, accentDeep: Tone
    /// The glow behind search and at the map center, inside to outside.
    var glowInner, glowOuter: Tone
    var accentTint: Tone

    /// One radius for controls, panels and cards; nil keeps Loom's own 6/12/16/20/28 scale.
    let corner: CGFloat?
    let display: TypeStyle
    let displaySize: CGFloat
    let body: TypeStyle
    let bodySize: CGFloat
    /// Kinds, counts, dates and tags.
    let label: TypeStyle
    let labelSize: CGFloat
    /// The map, tile depth, icons and motion.
    let style: ThemeStyle
    var branches: [UInt32]

    init(id: String, name: String, mood: String,
         ground: Tone, surface: Tone, ink: Tone, muted: Tone, line: Tone,
         accent: Tone, onAccent: Tone, accentInk: Tone, signal: Tone,
         corner: CGFloat?, display: TypeStyle, displaySize: CGFloat, body: TypeStyle, bodySize: CGFloat,
         label: TypeStyle, labelSize: CGFloat, style: ThemeStyle) {
        self.id = id; self.name = name; self.mood = mood
        self.ground = ground; self.surface = surface; self.ink = ink; self.muted = muted; self.line = line
        self.accent = accent; self.onAccent = onAccent; self.accentInk = accentInk; self.signal = signal
        self.corner = corner; self.display = display; self.displaySize = displaySize; self.body = body; self.bodySize = bodySize
        self.label = label; self.labelSize = labelSize; self.style = style
        // The languages define nine roles; the rest are blended from them.
        sunken = ground.mixed(with: line, 0.45)
        faint = muted.mixed(with: ground, 0.35)
        accentDeep = accent.mixed(with: ink, 0.35)
        glowInner = signal.opacity(0.18, 0.22)
        glowOuter = accent.opacity(0.16, 0.2)
        accentTint = accent.opacity(0.12, 0.16)
        branches = [signal.light, 0xc98a2b, 0x4f78ad, 0xa64d6c, 0x6f8f3a, 0x7a5cae, 0xd06a3c, 0x3a9aa6, 0x8b6b4a, 0xb84a4a]
    }

    static let storageKey = "theme"
    static let defaultID = "kiln"

    static func named(_ id: String?) -> LoomTheme {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    static let all: [LoomTheme] = [loom, paper, herbarium, observatory, blueprint, terrazzo, swiss, kiln, lamplight, riso, mist]

    static let loom: LoomTheme = {
        var t = LoomTheme(id: "loom", name: "Loom", mood: "Warm paper, coral and violet. The original.",
                          ground: Tone(0xfaf8f5, 0x141312), surface: Tone(0xffffff, 0x1f1d1b),
                          ink: Tone(0x1c1b19, 0xf4f2ee), muted: Tone(0x6b6862, 0xa8a49d),
                          line: Tone(0x1c1b19, 0xf4f2ee).opacity(0.08, 0.1),
                          accent: Tone(0xe84f61, 0xe84f61), onAccent: Tone(0xffffff, 0xffffff),
                          accentInk: Tone(0xc4384b, 0xff8a97), signal: Tone(0x8c61f2, 0x8c61f2),
                          corner: nil, display: TypeStyle(design: .serif, weight: .regular, tracking: -0.2), displaySize: 38,
                          body: TypeStyle(weight: .regular), bodySize: 17,
                          label: TypeStyle(weight: .medium), labelSize: 12,
                          style: ThemeStyle(node: .pill, edge: .curve, canvas: .dots, centerGlow: true, depth: .soft,
                                            glass: true, gradient: true, symbolWeight: .medium, motion: .spring(duration: 0.35)))
        t.sunken = Tone(0xf2efea, 0x191816)
        t.faint = Tone(0x9b978f, 0x6e6a64)
        t.accentDeep = Tone(0x8c61f2, 0x8c61f2)
        t.glowInner = Tone(0x8c61f2, 0x8c61f2).opacity(0.28, 0.36)
        t.glowOuter = Tone(0xe84f61, 0xe84f61).opacity(0.16, 0.22)
        t.accentTint = Tone(0xe84f61, 0xff8a97).opacity(0.12, 0.16)
        t.branches = [0xfa734a, 0x4085f5, 0x29b380, 0xe6529e, 0x8c61f2, 0x14a8bf, 0xf2a821, 0x5c6bdb, 0xd9404d, 0x6bb333]
        return t
    }()

    static let paper = LoomTheme(
        id: "paper", name: "Paper & Ink", mood: "Quiet, literate, archival.",
        ground: Tone(0xf4efe6, 0x16130f), surface: Tone(0xfbf8f2, 0x201c17), ink: Tone(0x1b1814, 0xefe8dc),
        muted: Tone(0x5f574c, 0xa99f90), line: Tone(0xd9d0c1, 0x3a332a), accent: Tone(0xb8321b, 0xe2553b),
        onAccent: Tone(0xffffff, 0x1a0b07), accentInk: Tone(0xa92a14, 0xf08a73), signal: Tone(0x1f4e79, 0x8fb4dc),
        corner: 2, display: TypeStyle("Newsreader", weight: .medium, tracking: -0.4), displaySize: 34,
        body: TypeStyle("Newsreader", weight: .regular), bodySize: 16,
        label: TypeStyle("IBM Plex Mono", weight: .medium, tracking: 1.2), labelSize: 11,
        style: ThemeStyle(node: .underline, edge: .straight, edgeWidth: 1, inkEdges: true, canvas: .ruled, depth: .flat,
                          labelCaps: true, symbolWeight: .light, motion: .easeOut(duration: 0.12)))

    static let herbarium = LoomTheme(
        id: "herbarium", name: "Herbarium", mood: "Patient, curious, alive.",
        ground: Tone(0xeef0e6, 0x121611), surface: Tone(0xf8f8f1, 0x1b2119), ink: Tone(0x1f2a1f, 0xe6ebdc),
        muted: Tone(0x56614f, 0xa2ab96), line: Tone(0xc9d0bc, 0x2f382c), accent: Tone(0x3f6b3a, 0x8fbf7f),
        onAccent: Tone(0xffffff, 0x0f1a0d), accentInk: Tone(0x355d31, 0xa7d197), signal: Tone(0xa8476f, 0xe48aac),
        corner: 4, display: TypeStyle("Cormorant Garamond", weight: .semibold, italic: true, tracking: -0.2), displaySize: 36,
        body: TypeStyle("Figtree", weight: .regular), bodySize: 15,
        label: TypeStyle("IBM Plex Mono", weight: .medium, tracking: 0.6), labelSize: 11,
        style: ThemeStyle(node: .specimen, edge: .stem, edgeWidth: 1, canvas: .plain, depth: .flat,
                          symbolWeight: .regular, motion: .easeOut(duration: 0.24)))

    static let observatory = LoomTheme(
        id: "observatory", name: "Observatory", mood: "Deep, focused, a little cosmic.",
        ground: Tone(0xf3f1ec, 0x0b0d12), surface: Tone(0xffffff, 0x151922), ink: Tone(0x14161c, 0xece7da),
        muted: Tone(0x555a66, 0x9a9fae), line: Tone(0xd6d3cc, 0x262c38), accent: Tone(0xb8741a, 0xf2b54a),
        onAccent: Tone(0x14161c, 0x1a1205), accentInk: Tone(0x8a5410, 0xf5c56f), signal: Tone(0x2f5aa8, 0x8fb0ff),
        corner: 10, display: TypeStyle("IBM Plex Mono", weight: .medium, tracking: 2), displaySize: 26,
        body: TypeStyle("Figtree", weight: .regular), bodySize: 15,
        label: TypeStyle("IBM Plex Mono", weight: .medium, tracking: 1.6), labelSize: 10,
        style: ThemeStyle(node: .star, edge: .straight, edgeWidth: 1, inkEdges: true, canvas: .stars, centerGlow: true, depth: .soft,
                          glass: true, labelCaps: true, displayCaps: true, symbolWeight: .light, motion: .easeInOut(duration: 0.4)))

    static let blueprint = LoomTheme(
        id: "blueprint", name: "Blueprint", mood: "Precise, constructive, nerdy in a good way.",
        ground: Tone(0xe9f0f7, 0x0f2a4a), surface: Tone(0xf7fafd, 0x163559), ink: Tone(0x0d2440, 0xe8f1fb),
        muted: Tone(0x45607e, 0xa9c0da), line: Tone(0xb7c9dc, 0x2e5480), accent: Tone(0x1d4f91, 0xf2f6fb),
        onAccent: Tone(0xffffff, 0x0f2a4a), accentInk: Tone(0x1d4f91, 0x9fd0ff), signal: Tone(0xc84a1c, 0xff9a6b),
        corner: 0, display: TypeStyle("IBM Plex Sans", weight: .semibold, tracking: -0.3), displaySize: 28,
        body: TypeStyle("IBM Plex Sans", weight: .regular), bodySize: 15,
        label: TypeStyle("IBM Plex Mono", weight: .medium, tracking: 0.4), labelSize: 11,
        style: ThemeStyle(node: .drafted, edge: .orthogonal, edgeWidth: 1, inkEdges: true, canvas: .grid, depth: .flat,
                          symbolWeight: .regular, motion: .linear(duration: 0.1)))

    static let terrazzo = LoomTheme(
        id: "terrazzo", name: "Terrazzo", mood: "Warm, bright, a bit cheeky.",
        ground: Tone(0xfbf3ea, 0x1d1714), surface: Tone(0xffffff, 0x29211c), ink: Tone(0x2a1f1a, 0xf7ece2),
        muted: Tone(0x6d5f57, 0xbba99c), line: Tone(0xecdccc, 0x3d322b), accent: Tone(0xf05a36, 0xff8466),
        onAccent: Tone(0x2a1f1a, 0x22140f), accentInk: Tone(0xb8391a, 0xff9f86), signal: Tone(0x1f7a70, 0x5cc2b3),
        corner: 22, display: TypeStyle("Bricolage Grotesque", weight: .heavy, tracking: -0.8), displaySize: 34,
        body: TypeStyle("Bricolage Grotesque", weight: .regular), bodySize: 16,
        label: TypeStyle("Bricolage Grotesque", weight: .bold), labelSize: 12,
        style: ThemeStyle(node: .chunky, edge: .thick, edgeWidth: 3.5, canvas: .speckle, depth: .hard(x: 0, y: 3, accent: false),
                          outline: 2, inkOutline: true, symbolWeight: .bold, filledSymbols: true,
                          motion: .spring(duration: 0.3, bounce: 0.35),
                          chips: [Tone(0xf2b134, 0xe0a52a), Tone(0xf4a6b8, 0xd98ba0), Tone(0xffffff, 0xf7ece2)],
                          onChip: Tone(0x2a1f1a, 0x2a1f1a)))

    static let swiss = LoomTheme(
        id: "swiss", name: "Swiss Index", mood: "Confident, clear, objective.",
        ground: Tone(0xffffff, 0x0a0a0a), surface: Tone(0xf2f2f2, 0x1a1a1a), ink: Tone(0x0a0a0a, 0xffffff),
        muted: Tone(0x4d4d4d, 0xb3b3b3), line: Tone(0x0a0a0a, 0xffffff), accent: Tone(0xd7000f, 0xff2a36),
        onAccent: Tone(0xffffff, 0x000000), accentInk: Tone(0xc4000d, 0xff5a63), signal: Tone(0x0057a8, 0x5aa9ff),
        corner: 0, display: TypeStyle("Archivo", weight: .heavy, tracking: -1.2), displaySize: 40,
        body: TypeStyle("Archivo", weight: .regular), bodySize: 15,
        label: TypeStyle("Archivo", weight: .bold, tracking: 0.2), labelSize: 11,
        style: ThemeStyle(node: .block, edge: .orthogonal, edgeWidth: 2, inkEdges: true, canvas: .columns, depth: .flat,
                          outline: 0, symbolWeight: .semibold, motion: .linear(duration: 0.08)))

    static let kiln: LoomTheme = {
        var t = LoomTheme(
            id: "kiln", name: "Kiln", mood: "Warm, tactile, grounded.",
            ground: Tone(0xf3e9df, 0x1b1411), surface: Tone(0xfbf5ef, 0x261c17), ink: Tone(0x2b1d16, 0xf3e6da),
            muted: Tone(0x6e574a, 0xb9a291), line: Tone(0xe0cfc0, 0x3b2d25), accent: Tone(0xb5502c, 0xe07a52),
            onAccent: Tone(0xffffff, 0x1b0e08), accentInk: Tone(0x9c4223, 0xf0946f), signal: Tone(0x2a7471, 0x6cc2bd),
            corner: 14, display: TypeStyle("DM Serif Display", weight: .regular, tracking: -0.3), displaySize: 34,
            body: TypeStyle("Figtree", weight: .regular), bodySize: 15,
            label: TypeStyle("Figtree", weight: .semibold, tracking: 0.2), labelSize: 12,
            style: ThemeStyle(node: .pebble, edge: .curve, edgeWidth: 1.5, canvas: .rings, depth: .low, outline: 0,
                              symbolWeight: .regular, motion: .easeInOut(duration: 0.26)))
        t.sunken = Tone(0xeadccf, 0x211814)
        t.faint = Tone(0x9c8574, 0x7d6758)
        t.accentDeep = Tone(0x7e3219, 0xb5502c)
        return t
    }()

    static let lamplight: LoomTheme = {
        var t = LoomTheme(
            id: "lamplight", name: "Lamplight", mood: "Cosy, scholarly, intimate.",
            ground: Tone(0xefe7d6, 0x14100b), surface: Tone(0xf8f2e6, 0x1f1912), ink: Tone(0x221a10, 0xf1e4c8),
            muted: Tone(0x615542, 0xb3a283), line: Tone(0xd8ccb4, 0x3a2f22), accent: Tone(0x2f5d3a, 0xe8b65a),
            onAccent: Tone(0xffffff, 0x1d1406), accentInk: Tone(0x2a5434, 0xf0c879), signal: Tone(0x9a6a1a, 0x7fb08a),
            corner: 6, display: TypeStyle("Libre Caslon Text", weight: .regular, tracking: -0.2), displaySize: 30,
            body: TypeStyle("Newsreader", weight: .regular), bodySize: 16,
            label: TypeStyle("Figtree", weight: .semibold, tracking: 0.8), labelSize: 11,
            style: ThemeStyle(node: .lampWord, edge: .straight, edgeWidth: 1, canvas: .lamp, depth: .soft, innerRule: true,
                              labelCaps: true, symbolWeight: .light, motion: .easeInOut(duration: 0.3)))
        t.glowInner = Tone(0x9a6a1a, 0xe8b65a).opacity(0.18, 0.2)
        return t
    }()

    static let riso: LoomTheme = {
        var t = LoomTheme(
            id: "riso", name: "Riso", mood: "Indie, energetic, handmade.",
            ground: Tone(0xf5f1e8, 0x17142a), surface: Tone(0xfffdf8, 0x221e3b), ink: Tone(0x1f2a5c, 0xf5f1e8),
            muted: Tone(0x4a5280, 0xb6b2cf), line: Tone(0x1f2a5c, 0xf5f1e8), accent: Tone(0xd61a86, 0xff5cbc),
            onAccent: Tone(0xffffff, 0x17142a), accentInk: Tone(0xb5136f, 0xff7dca), signal: Tone(0xffe800, 0xffe800),
            corner: 3, display: TypeStyle("Space Mono", weight: .bold, tracking: -0.6), displaySize: 28,
            body: TypeStyle("Space Mono", weight: .regular), bodySize: 14,
            label: TypeStyle("Space Mono", weight: .bold, tracking: 0.4), labelSize: 11,
            style: ThemeStyle(node: .misprint, edge: .dashed, edgeWidth: 1.5, canvas: .halftone, depth: .hard(x: 3, y: 3, accent: true),
                              outline: 1.5, inkOutline: true, symbolWeight: .bold, motion: .spring(duration: 0.12, bounce: 0.4),
                              chips: [Tone(0xffe800, 0xffe800)], onChip: Tone(0x1f2a5c, 0x1f2a5c)))
        // The yellow is a highlighter fill, never a lone mark, so the first branch is the pink ink.
        t.branches[0] = 0xd61a86
        return t
    }()

    static let mist = LoomTheme(
        id: "mist", name: "Mist", mood: "Serene, light, unobtrusive.",
        ground: Tone(0xeef1f2, 0x101415), surface: Tone(0xf9fbfb, 0x182022), ink: Tone(0x1d2426, 0xe3eaeb),
        muted: Tone(0x5b6669, 0x9aa7aa), line: Tone(0xd5dcde, 0x263133), accent: Tone(0x2d6e66, 0x8fd6c8),
        onAccent: Tone(0xffffff, 0x0d1f1c), accentInk: Tone(0x2a655e, 0x9fe0d3), signal: Tone(0x3f8f84, 0x5fb3a6),
        corner: 24, display: TypeStyle("Figtree", weight: .light, tracking: -0.6), displaySize: 32,
        body: TypeStyle("Figtree", weight: .regular), bodySize: 15,
        label: TypeStyle("Figtree", weight: .medium, tracking: 0.2), labelSize: 12,
        style: ThemeStyle(node: .frosted, edge: .soft, edgeWidth: 2, canvas: .mist, depth: .frost,
                          glass: true, symbolWeight: .light, motion: .spring(duration: 0.35, bounce: 0)))
}

/// The chosen look, remembered across launches. Views that read `Theme` redraw when it changes.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var theme: LoomTheme {
        didSet { UserDefaults.standard.set(theme.id, forKey: LoomTheme.storageKey) }
    }

    private init() {
        theme = LoomTheme.named(UserDefaults.standard.string(forKey: LoomTheme.storageKey))
    }
}

/// A colour for light and dark appearance.
struct Tone: Equatable {
    var light: UInt32
    var dark: UInt32
    var lightOpacity = 1.0
    var darkOpacity = 1.0

    init(_ light: UInt32, _ dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    var color: Color {
        Color(light: Color(hex: light, opacity: lightOpacity), dark: Color(hex: dark, opacity: darkOpacity))
    }

    func opacity(_ light: Double, _ dark: Double) -> Tone {
        var t = self
        t.lightOpacity = light
        t.darkOpacity = dark
        return t
    }

    /// Blends `amount` of `other` into this colour, in each appearance.
    func mixed(with other: Tone, _ amount: Double) -> Tone {
        func mix(_ a: UInt32, _ b: UInt32) -> UInt32 {
            var result: UInt32 = 0
            for shift: UInt32 in [16, 8, 0] {
                let x = Double((a >> shift) & 0xff), y = Double((b >> shift) & 0xff)
                result |= UInt32((x + (y - x) * amount).rounded()) << shift
            }
            return result
        }
        return Tone(mix(light, other.light), mix(dark, other.dark))
    }
}

/// A typeface and its voice: a bundled family, or the system font when `family` is nil.
struct TypeStyle: Equatable {
    var family: String?
    var design: Font.Design = .default
    var weight: Font.Weight
    var italic = false
    var tracking: CGFloat = 0

    init(_ family: String? = nil, design: Font.Design = .default, weight: Font.Weight, italic: Bool = false, tracking: CGFloat = 0) {
        self.family = family
        self.design = design
        self.weight = weight
        self.italic = italic
        self.tracking = tracking
    }

    func font(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        var font = Font.system(size: size, weight: weight, design: design)
        if let family { font = .custom(family, size: size, relativeTo: style).weight(weight) }
        return italic ? font.italic() : font
    }

    func weighted(_ weight: Font.Weight) -> TypeStyle {
        var t = self
        t.weight = weight
        return t
    }
}

/// How a language draws everything beyond colour and type: the map's topics, edges and canvas,
/// the depth of tiles, the voice of icons and the feel of motion. From each language's guide.
struct ThemeStyle {
    /// How a topic sits on the map.
    enum Node {
        /// Loom: a surface pill with a branch dot and a count capsule.
        case pill
        /// Kiln: a glazed pebble on a shelf; the selected one is fired in the accent.
        case pebble
        /// Mist: a frosted pill; the selected one gets a soft halo.
        case frosted
        /// Terrazzo: a chunky outlined pill in rotating chip colours with a hard shadow.
        case chunky
        /// Paper & Ink: an underlined word with a superscript count.
        case underline
        /// Herbarium: a boxed specimen label, italic name, typed count, a corner tick.
        case specimen
        /// Observatory: a star sized by count with its name beside it.
        case star
        /// Blueprint: a labelled box with corner ticks; the selection is red-lined.
        case drafted
        /// Swiss Index: a black block with white text; the selected one is red.
        case block
        /// Lamplight: a serif word with a brass dot; the selection sits in lamplight.
        case lampWord
        /// Riso: an outlined tag with a pink misprint behind; the selection is highlighted yellow.
        case misprint
    }

    enum Edge { case curve, stem, straight, orthogonal, thick, dashed, soft }

    /// The texture under the map.
    enum Canvas { case dots, plain, ruled, grid, columns, stars, speckle, rings, lamp, halftone, mist }

    /// How tiles and chrome stand off the canvas.
    enum Depth: Equatable {
        /// Loom's soft lit shadow.
        case soft
        /// Low and close, like objects on a shelf.
        case low
        /// No shadow: rules and colour blocks carry depth.
        case flat
        /// A hard offset shadow in ink, or in the accent as a second ink layer.
        case hard(x: CGFloat, y: CGFloat, accent: Bool)
        /// Translucent frosted panels with a wide soft blur.
        case frost

        var isHard: Bool {
            if case .hard = self { return true }
            return false
        }
    }

    var node: Node = .pill
    var edge: Edge = .curve
    var edgeWidth: CGFloat = 1.5
    /// Edges drawn in ink with the selected topic's edges in `signal`, rather than in branch colours.
    var inkEdges = false
    var canvas: Canvas = .dots
    /// The theme's glow at the map centre.
    var centerGlow = false
    var depth: Depth = .soft
    /// Tile and chrome outline width; 0 for none.
    var outline: CGFloat = 1
    /// Outlines in `ink` rather than `line`.
    var inkOutline = false
    /// A fine rule inset inside tiles (Lamplight's leather cards).
    var innerRule = false
    /// Floating chrome in Liquid Glass where the system has it, rather than the language's own opaque tiles.
    var glass = false
    /// The capture button in the accent to accent-deep gradient rather than flat accent.
    var gradient = false
    /// Labels set in capitals (tracked mono and small-caps voices).
    var labelCaps = false
    /// Display type set in capitals.
    var displayCaps = false
    var symbolWeight: Font.Weight = .regular
    /// Filled SF Symbols where a filled form exists.
    var filledSymbols = false
    var motion: Animation = .easeInOut(duration: 0.25)
    /// Extra fills: Terrazzo's sun and rose chips, Riso's yellow highlight.
    var chips: [Tone] = []
    /// Text on `chips`.
    var onChip: Tone?
}
