import SwiftUI
import SwiftData

// MARK: - Graph model + physics

/// A force-directed web of concepts (tags and spaces) and files (everything you saved).
/// Positions are plain stored values (not observed) and advance one physics step per frame.
@Observable
final class WebSimulation {
    enum Kind: Equatable {
        case concept(name: String, isSpace: Bool)
        case item(UUID)
    }

    struct Node {
        let id: String
        let kind: Kind
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var radius: CGFloat
        var colorIndex: Int
        var count: Int
        var pinned = false
    }

    struct Link {
        let a: Int
        let b: Int
        let distance: CGFloat
        let isSimilarity: Bool
    }

    /// Only this is observed: it pauses the frame timer once the web stops moving.
    var settled = false

    @ObservationIgnored private(set) var nodes: [Node] = []
    @ObservationIgnored private(set) var links: [Link] = []
    @ObservationIgnored private(set) var neighbors: [Set<Int>] = []
    @ObservationIgnored private(set) var index: [String: Int] = [:]
    @ObservationIgnored private(set) var images: [UUID: Image] = [:]
    /// Half-size of each concept's pill as last drawn, so taps anywhere on a pill hit it.
    @ObservationIgnored var pillHalfSizes: [Int: CGSize] = [:]
    @ObservationIgnored private var alpha: CGFloat = 1
    @ObservationIgnored private var alphaTarget: CGFloat = 0
    /// Set between reaching rest and the deferred `settled = true`, so the save happens once.
    @ObservationIgnored private var settling = false

    private static let positionsKey = "web.positions"

    // MARK: Building

    func rebuild(items: [Item], spaces: [Space], linkSimilar: Bool) {
        let previous = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        let saved = previous.isEmpty ? Self.loadPositions() : [:]
        func startPosition(_ id: String, near anchor: CGPoint?) -> CGPoint {
            if let p = previous[id] ?? saved[id] { return p }
            let base = anchor ?? .zero
            let spread: CGFloat = anchor == nil ? 260 : 50
            return CGPoint(x: base.x + .random(in: -spread...spread), y: base.y + .random(in: -spread...spread))
        }

        var newNodes: [Node] = []
        var newIndex: [String: Int] = [:]
        var newLinks: [Link] = []

        // Concepts: tags, most used first, then spaces.
        var tagCounts: [String: Int] = [:]
        for item in items { for tag in item.tags { tagCounts[tag, default: 0] += 1 } }
        let tags = tagCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(60)
        for (i, (tag, count)) in tags.enumerated() {
            let id = "tag:\(tag)"
            let p = startPosition(id, near: nil)
            newIndex[id] = newNodes.count
            newNodes.append(Node(id: id, kind: .concept(name: tag, isSpace: false), x: p.x, y: p.y,
                                 radius: 14 + CGFloat(count).squareRoot() * 4, colorIndex: i, count: count))
        }
        for (s, space) in spaces.enumerated() {
            let count = items.filter { $0.space?.id == space.id }.count
            let id = "space:\(space.id)"
            let p = startPosition(id, near: nil)
            newIndex[id] = newNodes.count
            newNodes.append(Node(id: id, kind: .concept(name: "\(space.emoji) \(space.name)", isSpace: true), x: p.x, y: p.y,
                                 radius: 16 + CGFloat(count).squareRoot() * 4, colorIndex: tags.count + s, count: count))
        }

        // Files, placed near their first concept the first time they appear.
        var newImages: [UUID: Image] = images
        for item in items {
            let id = "item:\(item.id)"
            let anchorID = item.tags.first.map { "tag:\($0)" } ?? item.space.map { "space:\($0.id)" }
            let anchor = anchorID.flatMap { newIndex[$0] }.map { CGPoint(x: newNodes[$0].x, y: newNodes[$0].y) }
            let p = startPosition(id, near: anchor)
            let me = newNodes.count
            newIndex[id] = me
            // Items take the branch color of their first concept; unsorted items stay neutral (-1).
            newNodes.append(Node(id: id, kind: .item(item.id), x: p.x, y: p.y, radius: 7,
                                 colorIndex: anchorID.flatMap { newIndex[$0] }.map { newNodes[$0].colorIndex } ?? -1, count: 0))
            for tag in item.tags {
                if let c = newIndex["tag:\(tag)"] { newLinks.append(Link(a: c, b: me, distance: 80, isSimilarity: false)) }
            }
            if let space = item.space, let c = newIndex["space:\(space.id)"] {
                newLinks.append(Link(a: c, b: me, distance: 90, isSimilarity: false))
            }
            if newImages[item.id] == nil, let data = item.thumbnail, let image = PlatformImage(data: data) {
                newImages[item.id] = Image(platformImage: image)
            }
        }

        // Related files: each file links to its two closest neighbours by meaning.
        if linkSimilar {
            let vectors = items.map { SearchIndex.unpack($0.embedding) }
            for i in items.indices {
                guard let vi = vectors[i] else { continue }
                var best: [(Int, Float)] = []
                for j in items.indices where j != i {
                    guard let vj = vectors[j] else { continue }
                    let score = SearchIndex.cosine(vi, vj)
                    if score > 0.6 { best.append((j, score)) }
                }
                for (j, _) in best.sorted(by: { $0.1 > $1.1 }).prefix(2) {
                    guard let a = newIndex["item:\(items[i].id)"], let b = newIndex["item:\(items[j].id)"] else { continue }
                    if !newLinks.contains(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }) {
                        newLinks.append(Link(a: a, b: b, distance: 70, isSimilarity: true))
                    }
                }
            }
        }

        var newNeighbors = Array(repeating: Set<Int>(), count: newNodes.count)
        for link in newLinks {
            newNeighbors[link.a].insert(link.b)
            newNeighbors[link.b].insert(link.a)
        }
        for i in newNodes.indices {
            if case .item = newNodes[i].kind {
                newNodes[i].radius = 6 + min(CGFloat(newNeighbors[i].count), 6) * 0.7
            }
        }

        let isFirstBuild = nodes.isEmpty
        let hadSavedLayout = !saved.isEmpty
        nodes = newNodes
        links = newLinks
        neighbors = newNeighbors
        index = newIndex
        pillHalfSizes = [:]
        images = newImages.filter { id, _ in newIndex["item:\(id)"] != nil }

        if isFirstBuild && !hadSavedLayout {
            alpha = 1
            for _ in 0..<150 { step() } // pre-settle so the first frame already looks like a web
        } else {
            alpha = max(alpha, isFirstBuild ? 0.08 : 0.35)
        }
        settled = false
    }

    // MARK: Physics

    func tick() {
        guard !settled, !settling else { return }
        step()
        if alpha < 0.004 && alphaTarget == 0 {
            // tick() runs while a frame renders: defer both the observed change and the save,
            // since writing UserDefaults mid-render re-triggers rendering (via @AppStorage) in a tight loop.
            settling = true
            DispatchQueue.main.async {
                self.settling = false
                guard self.alpha < 0.004 && self.alphaTarget == 0 else { return }
                self.settled = true
                self.savePositions()
            }
        }
    }

    private func step() {
        alpha += (alphaTarget - alpha) * 0.0228
        let n = nodes.count
        guard n > 0 else { return }

        // Springs along links.
        for link in links {
            let a = nodes[link.a], b = nodes[link.b]
            var dx = b.x + b.vx - a.x - a.vx
            var dy = b.y + b.vy - a.y - a.vy
            if dx == 0 && dy == 0 { dx = 0.01; dy = 0.01 }
            let d = (dx * dx + dy * dy).squareRoot()
            let strength: CGFloat = link.isSimilarity ? 0.12 : 0.5 / CGFloat(max(1, min(neighbors[link.a].count, neighbors[link.b].count)))
            let k = (d - link.distance) / d * alpha * strength
            let degA = CGFloat(neighbors[link.a].count), degB = CGFloat(neighbors[link.b].count)
            let bias = degA / max(1, degA + degB)
            nodes[link.b].vx -= dx * k * bias
            nodes[link.b].vy -= dy * k * bias
            nodes[link.a].vx += dx * k * (1 - bias)
            nodes[link.a].vy += dy * k * (1 - bias)
        }

        // Repulsion between every pair, plus collision so nodes don't overlap.
        for i in 0..<n {
            let ci: CGFloat = isConcept(i) ? -520 : -140
            for j in (i + 1)..<max(i + 1, n) {
                var dx = nodes[j].x - nodes[i].x
                var dy = nodes[j].y - nodes[i].y
                if dx == 0 && dy == 0 { dx = .random(in: -0.5...0.5); dy = .random(in: -0.5...0.5) }
                let d2 = dx * dx + dy * dy
                if d2 > 640_000 { continue }
                let cj: CGFloat = isConcept(j) ? -520 : -140
                let inv = alpha / max(d2, 30)
                nodes[i].vx += dx * cj * inv
                nodes[i].vy += dy * cj * inv
                nodes[j].vx -= dx * ci * inv
                nodes[j].vy -= dy * ci * inv

                // Pills are wider than their circle: push overlapping pills apart along the shorter overlap.
                if let hi = pillHalfSizes[i], let hj = pillHalfSizes[j] {
                    let ox = hi.width + hj.width + 10 - abs(dx)
                    let oy = hi.height + hj.height + 6 - abs(dy)
                    if ox > 0 && oy > 0 {
                        if ox < oy {
                            let push = ox * 0.25 * (dx < 0 ? -1 : 1)
                            nodes[i].vx -= push
                            nodes[j].vx += push
                        } else {
                            let push = oy * 0.25 * (dy < 0 ? -1 : 1)
                            nodes[i].vy -= push
                            nodes[j].vy += push
                        }
                        continue
                    }
                }

                let minD = nodes[i].radius + nodes[j].radius + 6
                if d2 < minD * minD {
                    let d = d2.squareRoot()
                    let push = (minD - d) / d * 0.5
                    nodes[i].vx -= dx * push * 0.5
                    nodes[i].vy -= dy * push * 0.5
                    nodes[j].vx += dx * push * 0.5
                    nodes[j].vy += dy * push * 0.5
                }
            }
        }

        // Gentle pull to the middle so loose files don't drift away; then move.
        for i in 0..<n {
            nodes[i].vx -= nodes[i].x * 0.012 * alpha
            nodes[i].vy -= nodes[i].y * 0.012 * alpha
            if nodes[i].pinned {
                nodes[i].vx = 0
                nodes[i].vy = 0
                continue
            }
            nodes[i].vx *= 0.6
            nodes[i].vy *= 0.6
            nodes[i].x += nodes[i].vx
            nodes[i].y += nodes[i].vy
        }
    }

    private func isConcept(_ i: Int) -> Bool {
        if case .concept = nodes[i].kind { return true }
        return false
    }

    // MARK: Interaction

    func hitTest(_ p: CGPoint, scale: CGFloat) -> Int? {
        let slop = 6 / max(scale, 0.2)
        var best: (Int, CGFloat)?
        for (i, node) in nodes.enumerated() {
            let dx = node.x - p.x, dy = node.y - p.y
            let d = (dx * dx + dy * dy).squareRoot()
            if let half = pillHalfSizes[i], abs(dx) <= half.width + slop, abs(dy) <= half.height + slop {
                // Pills sit on top of files, so a pill wins over anything under it.
                return i
            }
            if d <= node.radius + slop, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    func pin(_ i: Int, at p: CGPoint) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].x = p.x
        nodes[i].y = p.y
        nodes[i].pinned = true
        alphaTarget = 0.25
        alpha = max(alpha, 0.25)
        settled = false
    }

    func release(_ i: Int) {
        if nodes.indices.contains(i) { nodes[i].pinned = false }
        alphaTarget = 0
    }

    func reheat() {
        alpha = max(alpha, 0.6)
        settled = false
    }

    func resetLayout() {
        UserDefaults.standard.removeObject(forKey: Self.positionsKey)
        for i in nodes.indices {
            nodes[i].x = .random(in: -300...300)
            nodes[i].y = .random(in: -300...300)
        }
        alpha = 1
        settled = false
    }

    func position(of id: String) -> CGPoint? {
        index[id].map { CGPoint(x: nodes[$0].x, y: nodes[$0].y) }
    }

    var bounds: CGRect {
        guard !nodes.isEmpty else { return .zero }
        var r = CGRect.null
        for n in nodes { r = r.union(CGRect(x: n.x - n.radius, y: n.y - n.radius, width: n.radius * 2, height: n.radius * 2)) }
        return r
    }

    // MARK: Saved layout

    private func savePositions() {
        let stored = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, [Double($0.x), Double($0.y)]) })
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.positionsKey) }
    }

    private static func loadPositions() -> [String: CGPoint] {
        guard let data = UserDefaults.standard.data(forKey: positionsKey),
              let stored = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return stored.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }
}

// MARK: - View

/// The main page: an interactive web of concepts and files.
struct KnowledgeWebView: View {
    /// The item open in the side panel.
    @Binding var selection: UUID?
    /// Search text from the main page; matches stay bright, the rest dims.
    var highlight: String
    /// Set to an item's ID to fly the camera to it.
    @Binding var focusRequest: UUID?

    @Environment(Librarian.self) private var librarian
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @Query(sort: \Space.createdAt) private var spaces: [Space]

    @AppStorage("web.linkSimilar") private var linkSimilar = true
    @AppStorage("web.alwaysShowNames") private var alwaysShowNames = false

    @State private var sim = WebSimulation()
    @State private var scale: CGFloat = 0.9
    @State private var baseScale: CGFloat = 0.9
    @State private var pan: CGSize = .zero
    @State private var dragMode: DragMode?
    @State private var hovered: Int?
    @State private var hoverLocation: CGPoint = .zero
    @State private var selectedConcept: String?
    /// Kinds picked in the legend; empty shows everything.
    @State private var kindFilter: Set<ItemKind> = []
    @State private var viewSize: CGSize = .zero
    @State private var newNoteTags: [String]?
    @State private var showingNewNote = false
    /// The rebuild waiting for a burst of changes to end, and the item to fly to once it's on the map.
    @State private var rebuildTask: Task<Void, Never>?
    @State private var pendingFocus: String?

    private enum DragMode {
        case node(Int)
        case pan(start: CGSize)
    }

    /// Concepts take the branch palette in order; items share their concept's color.
    private func color(of node: WebSimulation.Node) -> Color {
        node.colorIndex < 0 ? Theme.labelTertiary : Theme.branch(node.colorIndex)
    }

    /// Changes whenever something that shapes the web changes.
    private var signature: String {
        items.map { "\($0.id)|\($0.tags.joined(separator: ","))|\($0.space?.id.uuidString ?? "")|\($0.embedding?.count ?? 0)|\($0.thumbnail?.count ?? 0)" }
            .joined(separator: ";") + "#\(spaces.map(\.name).joined())#\(linkSimilar)"
    }

    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        // The canvas draws outside the body, so it is rebuilt when the theme changes.
        let themeID = Theme.current.id
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: sim.settled)) { _ in
                let _ = sim.tick()
                canvas(byID: byID, size: geometry.size)
            }
            .id(themeID)
            .contentShape(Rectangle())
            .gesture(dragGesture(size: geometry.size))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { scale = clampScale(baseScale * $0.magnification) }
                    .onEnded { _ in baseScale = scale }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hovered = sim.hitTest(toWorld(location, size: geometry.size), scale: scale)
                case .ended:
                    hovered = nil
                }
            }
            .overlay(alignment: .topLeading) { hoverCard(byID: byID, size: geometry.size) }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .onAppear {
                viewSize = geometry.size
                sim.rebuild(items: items, spaces: spaces, linkSimilar: linkSimilar)
                fit()
            }
            .onChange(of: geometry.size) { _, size in viewSize = size }
        }
        .background(background)
        .clipped()
        .onChange(of: signature) { _, _ in scheduleRebuild() }
        .onChange(of: focusRequest) { _, id in
            guard let id else { return }
            focus(on: "item:\(id)")
            focusRequest = nil
        }
        .overlay(alignment: .topLeading) { legend }
        .overlay(alignment: .bottomLeading) { conceptChip }
        .overlay { if items.isEmpty { emptyState } }
        .sheet(isPresented: $showingNewNote) { NoteEditorSheet(tags: newNoteTags ?? []) }
    }

    // MARK: Drawing

    private func canvas(byID: [UUID: Item], size: CGSize) -> some View {
        let focus = focusSet
        let query = highlight.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = query.isEmpty ? nil : matchingNodes(query: query, byID: byID)
        let kinds = kindFilter.isEmpty ? nil : kindNodes(kindFilter, byID: byID)
        let showFileNames = alwaysShowNames || scale > 1.1
        let busy = librarian.busyItemIDs
        let theme = Theme.current
        let style = theme.style

        return Canvas { ctx, size in
            drawBackdrop(&ctx, size: size, style: style)
            ctx.translateBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            ctx.scaleBy(x: scale, y: scale)
            let nodes = sim.nodes
            let compact = scale < 0.42
            drawWorldTexture(&ctx, size: size, style: style)

            // The theme's glow at the map center. Lamplight's lamp pool follows the selected topic instead.
            if style.centerGlow || style.canvas == .lamp {
                let lamp = style.canvas == .lamp
                let center = lamp ? (selectedConcept.flatMap { sim.position(of: $0) } ?? .zero) : .zero
                let glowRadius: CGFloat = lamp ? 340 : 520
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                         with: .radialGradient(Gradient(stops: [.init(color: Theme.glowInner, location: 0),
                                                                .init(color: Theme.glowOuter, location: 0.45),
                                                                .init(color: .clear, location: 1)]),
                                               center: center, startRadius: 0, endRadius: glowRadius))
            }

            func dimmed(_ i: Int) -> Bool {
                if let focus, !focus.contains(i) { return true }
                if let matches, !matches.contains(i) { return true }
                if let kinds, !kinds.contains(i) { return true }
                return false
            }

            // Edges in the language's line: curves, stems, straight ink, right angles, thick strokes, dashes or mist.
            // Related files get a faint dotted link.
            let unit = 1 / max(scale, 0.6)
            for link in sim.links {
                let a = nodes[link.a], b = nodes[link.b]
                let path = edgePath(from: CGPoint(x: a.x, y: a.y), to: CGPoint(x: b.x, y: b.y), style: style.edge)
                let lit = focus.map { $0.contains(link.a) && $0.contains(link.b) } ?? false
                let faded = dimmed(link.a) || dimmed(link.b)
                if link.isSimilarity {
                    ctx.stroke(path, with: .color(Theme.labelTertiary.opacity(faded ? 0.05 : (lit ? 0.7 : 0.3))),
                               style: StrokeStyle(lineWidth: (lit ? 2 : 1.5) * unit, lineCap: .round, dash: [4 * unit, 6 * unit]))
                    continue
                }
                var tone = style.inkEdges ? Theme.label : color(of: a)
                if lit && style.inkEdges { tone = style.node == .star ? Theme.accent : Theme.signal }
                var opacity = faded ? 0.05 : (lit ? 0.8 : 0.45)
                if style.inkEdges && !lit && !faded { opacity = style.edgeWidth >= 2 ? 0.45 : 0.3 }
                if style.edge == .soft && !lit { opacity *= 0.6 }
                let width = style.edgeWidth * (lit ? 1.35 : 1) * unit
                if lit && style.node == .star {
                    ctx.stroke(path, with: .color(Theme.accent.opacity(0.18)), style: StrokeStyle(lineWidth: width * 5, lineCap: .round))
                }
                ctx.stroke(path, with: .color(tone.opacity(opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: style.edge == .orthogonal ? .square : .round, lineJoin: .round,
                                              dash: style.edge == .dashed ? [6 * unit, 4 * unit] : []))
            }

            // Files: surface discs (squares and tags in the print languages) with a ring in the branch color
            // and the kind symbol. Zoomed far out they become plain branch-colored dots.
            func fileShape(_ rect: CGRect) -> Path {
                switch style.node {
                case .drafted, .block: Path(rect)
                case .specimen, .misprint, .underline: Path(roundedRect: rect, cornerRadius: rect.width * 0.2)
                default: Path(ellipseIn: rect)
                }
            }
            ctx.drawLayer { layer in
                if !compact, style.depth != .flat, !style.depth.isHard {
                    layer.addFilter(.shadow(color: Color(hex: theme.ink.light, opacity: 0.12), radius: 3, x: 0, y: 1))
                }
                for (i, node) in nodes.enumerated() {
                    guard case .item(let id) = node.kind else { continue }
                    let c = color(of: node)
                    let isHovered = hovered == i
                    let selected = selection == id
                    var r = node.radius + (compact ? 0 : 3)
                    if isHovered || selected { r *= 1.2 }
                    let rect = CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2)
                    let showsImage = sim.images[id] != nil && (scale > 0.8 || isHovered || selected)
                    let drawn = showsImage ? rect.insetBy(dx: -r * 0.4, dy: -r * 0.4) : rect
                    layer.opacity = dimmed(i) ? Theme.dimmedOpacity : 1

                    if compact {
                        layer.fill(fileShape(rect), with: .color(c))
                        continue
                    }
                    if case .hard(let dx, let dy, let accent) = style.depth {
                        layer.fill(fileShape(drawn.offsetBy(dx: dx / scale, dy: dy / scale)), with: .color(accent ? Theme.accent : Theme.label))
                    }
                    if showsImage, let image = sim.images[id] {
                        layer.drawLayer { inner in
                            inner.clip(to: fileShape(drawn))
                            inner.draw(image, in: drawn)
                        }
                        layer.stroke(fileShape(drawn), with: .color(c), lineWidth: max(1.5, style.outline) / scale)
                    } else {
                        layer.fill(fileShape(rect), with: .color(Theme.surface))
                        layer.stroke(fileShape(rect.insetBy(dx: 0.75 / scale, dy: 0.75 / scale)), with: .color(c), lineWidth: max(1.5, style.outline) / scale)
                        if r * scale >= 9, let item = byID[id] {
                            layer.draw(Text(Image(systemName: item.kind.symbol))
                                        .font(.system(size: r * 0.95, weight: style.symbolWeight))
                                        .foregroundStyle(Theme.labelSecondary),
                                       at: CGPoint(x: node.x, y: node.y))
                        }
                    }
                    if selected {
                        // Selection: a 2px ring in the branch color, offset 2px.
                        let ring = drawn.insetBy(dx: -2 / scale - 1 / scale, dy: -2 / scale - 1 / scale)
                        layer.stroke(fileShape(ring), with: .color(c), lineWidth: 2 / scale)
                    }
                    if busy.contains(id) {
                        // Still being copied, read or summarized.
                        layer.stroke(fileShape(rect.insetBy(dx: -r * 0.9, dy: -r * 0.9)), with: .color(Theme.accentInk),
                                     style: StrokeStyle(lineWidth: 1.5 / scale, dash: [4 / scale, 3 / scale]))
                    }
                }
            }

            // File names under the files, in the language's reading face.
            let nameFace = theme.body.weighted(.medium)
            for (i, node) in nodes.enumerated() {
                guard case .item(let id) = node.kind else { continue }
                let wanted = showFileNames || hovered == i || selection == id || (focus?.contains(i) ?? false) || (matches?.contains(i) ?? false)
                guard wanted, !dimmed(i), !compact, let item = byID[id] else { continue }
                let title = item.displayTitle
                let short = title.count > 32 ? String(title.prefix(30)) + "…" : title
                ctx.draw(Text(short).font(nameFace.font(size: max(9, 11 / scale.squareRoot()), relativeTo: .caption)).foregroundStyle(Theme.labelSecondary),
                         at: CGPoint(x: node.x, y: node.y + node.radius + 6), anchor: .top)
            }

            // Concepts, drawn as the language's topic: pills, pebbles, specimen labels, stars, blocks, words…
            let fontSize = min(24, max(13, 15 / scale.squareRoot()))
            var topics: [MapTopic] = []
            for (i, node) in nodes.enumerated() {
                guard case .concept(let name, let isSpace) = node.kind else { continue }
                let topic = layoutTopic(index: i, node: node, name: isSpace ? name : name.capitalized, fontSize: fontSize,
                                        selected: selectedConcept == node.id, theme: theme, ctx: ctx)
                topics.append(topic)
                sim.pillHalfSizes[i] = CGSize(width: topic.rect.width / 2, height: topic.rect.height / 2)
            }
            // Fills first, in one layer so the soft languages share one shadow pass.
            ctx.drawLayer { layer in
                switch style.depth {
                case .soft: layer.addFilter(.shadow(color: Color(hex: theme.ink.light, opacity: 0.08), radius: 6, x: 0, y: 3))
                case .low, .frost: layer.addFilter(.shadow(color: Color(hex: theme.ink.light, opacity: 0.08), radius: 5, x: 0, y: 4))
                case .flat, .hard: break
                }
                for topic in topics {
                    layer.opacity = dimmed(topic.index) ? Theme.dimmedOpacity : 1
                    drawTopicFill(topic, in: &layer, style: style, color: color(of: nodes[topic.index]))
                }
            }
            for topic in topics {
                ctx.opacity = dimmed(topic.index) ? Theme.dimmedOpacity : 1
                drawTopicDetail(topic, in: &ctx, style: style, color: color(of: nodes[topic.index]), hovered: hovered == topic.index)
            }
            ctx.opacity = 1
        }
    }

    /// An edge between two map points in the language's line.
    private func edgePath(from: CGPoint, to: CGPoint, style: ThemeStyle.Edge) -> Path {
        var path = Path()
        path.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        switch style {
        case .straight:
            path.addLine(to: to)
        case .orthogonal:
            // Right angles, like a drafted connector: across, down, across.
            path.addLine(to: CGPoint(x: mid.x, y: from.y))
            path.addLine(to: CGPoint(x: mid.x, y: to.y))
            path.addLine(to: to)
        case .stem:
            let bend: CGFloat = 0.24
            path.addQuadCurve(to: to, control: CGPoint(x: mid.x - (to.y - from.y) * bend, y: mid.y + (to.x - from.x) * bend))
        case .curve, .thick, .dashed, .soft:
            let bend: CGFloat = 0.12
            path.addQuadCurve(to: to, control: CGPoint(x: mid.x - (to.y - from.y) * bend, y: mid.y + (to.x - from.x) * bend))
        }
        return path
    }

    /// Measures a topic in the language's face and shape, centered on its node.
    private func layoutTopic(index: Int, node: WebSimulation.Node, name: String, fontSize fs: CGFloat, selected: Bool,
                             theme: LoomTheme, ctx: GraphicsContext) -> MapTopic {
        let style = theme.style
        var face = theme.body.weighted(.semibold)
        var nameSize = fs
        var tracking: CGFloat = 0
        var text = name
        switch style.node {
        case .underline, .lampWord:
            face = theme.display; nameSize = fs * 1.15; tracking = theme.display.tracking
        case .specimen:
            face = theme.display; nameSize = fs * 1.25; tracking = theme.display.tracking
        case .star:
            face = theme.label; nameSize = fs * 0.8; tracking = theme.label.tracking; text = name.uppercased()
        case .block, .chunky:
            face = theme.body.weighted(.bold)
        case .misprint:
            face = theme.label
        case .drafted:
            face = theme.body.weighted(.medium)
        case .pill, .pebble, .frosted:
            break
        }

        var ink = Theme.label
        var countInk = Theme.labelSecondary
        switch style.node {
        case .pebble where selected: ink = Theme.onAccent
        case .block: ink = selected ? Theme.onAccent : Theme.background; countInk = ink.opacity(0.75)
        case .chunky: ink = selected ? Theme.onAccent : Theme.onChip; countInk = Theme.onChip
        case .misprint where selected: ink = Theme.onChip; countInk = Theme.onChip
        case .lampWord where selected: ink = Theme.accentInk
        default: break
        }

        let label = ctx.resolve(Text(text).font(face.font(size: nameSize, relativeTo: .body)).tracking(tracking).foregroundStyle(ink))
        let count = ctx.resolve(Text("\(node.count)").font(theme.label.font(size: fs * 0.72, relativeTo: .caption)).foregroundStyle(countInk))
        let ns = label.measure(in: CGSize(width: 1000, height: 200))
        let cs = count.measure(in: CGSize(width: 200, height: 200))

        let width: CGFloat, height: CGFloat
        switch style.node {
        case .pill, .pebble, .frosted:
            width = fs * 0.9 + fs * 0.5 + fs * 0.45 + ns.width + fs * 0.5 + cs.width + fs * 0.8 + fs * 0.5
            height = ns.height + fs * 0.8
        case .chunky:
            width = fs * 0.9 + ns.width + fs * 0.5 + cs.width + fs * 0.8 + fs * 0.5
            height = ns.height + fs * 0.9
        case .specimen, .block, .misprint:
            width = fs * 0.7 + ns.width + fs * 0.5 + cs.width + fs * 0.7
            height = ns.height + fs * 0.7
        case .drafted:
            width = fs * 0.7 + fs * 0.45 + fs * 0.45 + ns.width + fs * 0.5 + cs.width + fs * 0.7
            height = ns.height + fs * 0.7
        case .underline:
            width = ns.width + fs * 0.15 + cs.width
            height = ns.height + fs * 0.4
        case .lampWord:
            width = fs * 0.4 + fs * 0.4 + ns.width + fs * 0.35 + cs.width
            height = ns.height + fs * 0.3
        case .star:
            let star = starRadius(count: node.count, fontSize: fs)
            width = star * 2 + fs * 0.5 + ns.width + fs * 0.4 + cs.width
            height = max(star * 2, ns.height)
        }
        let rect = CGRect(x: node.x - width / 2, y: node.y - height / 2, width: width, height: height)
        return MapTopic(index: index, rect: rect, name: label, count: count, nameSize: ns, countSize: cs, selected: selected,
                        fontSize: fs, total: node.count, corner: theme.corner ?? 0, colorIndex: node.colorIndex)
    }

    private func starRadius(count: Int, fontSize fs: CGFloat) -> CGFloat {
        fs * 0.22 + CGFloat(count).squareRoot() * fs * 0.1
    }

    /// The topic's body: what sits under its text, including hard offset shadows.
    private func drawTopicFill(_ t: MapTopic, in ctx: inout GraphicsContext, style: ThemeStyle, color c: Color) {
        let rect = t.rect
        let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        let box = Path(roundedRect: rect, cornerRadius: min(t.corner, rect.height / 2))
        switch style.node {
        case .pill:
            ctx.fill(capsule, with: .color(Theme.surface))
        case .pebble:
            ctx.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 2 / scale), cornerRadius: rect.height / 2), with: .color(Theme.hairline))
            ctx.fill(capsule, with: .color(t.selected ? Theme.accent : Theme.surface))
        case .frosted:
            ctx.fill(capsule, with: .color(Theme.current.surface.opacity(0.72, 0.66).color))
        case .chunky:
            ctx.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 3 / scale), cornerRadius: rect.height / 2), with: .color(Theme.label))
            ctx.fill(capsule, with: .color(t.selected ? Theme.accent : Theme.chip(t.colorIndex)))
        case .specimen, .drafted:
            ctx.fill(box, with: .color(Theme.surface))
        case .block:
            ctx.fill(box, with: .color(t.selected ? Theme.accent : Theme.label))
        case .misprint:
            ctx.fill(box.offsetBy(dx: 3 / scale, dy: 3 / scale), with: .color(Theme.accent))
            ctx.fill(box, with: .color(t.selected ? Theme.chip(0) : Theme.surface))
        case .underline, .lampWord, .star:
            break
        }
    }

    /// The topic's outline, marks, name and count.
    private func drawTopicDetail(_ t: MapTopic, in ctx: inout GraphicsContext, style: ThemeStyle, color c: Color, hovered: Bool) {
        let rect = t.rect, fs = t.fontSize
        let hair = 1 / scale
        let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        let box = Path(roundedRect: rect, cornerRadius: min(t.corner, rect.height / 2))

        /// The count in a capsule at `x`, last on the line.
        func countBubble(at x: CGFloat, fill: Color) {
            let bubble = CGRect(x: x, y: rect.midY - (t.countSize.height + fs * 0.3) / 2,
                                width: t.countSize.width + fs * 0.8, height: t.countSize.height + fs * 0.3)
            ctx.fill(Path(roundedRect: bubble, cornerRadius: bubble.height / 2), with: .color(fill))
            ctx.draw(t.count, at: CGPoint(x: bubble.midX, y: bubble.midY))
        }

        switch style.node {
        case .pill, .pebble, .frosted:
            if style.node == .pill { ctx.stroke(capsule, with: .color(Theme.hairline), lineWidth: hair) }
            if style.node == .frosted { ctx.stroke(capsule, with: .color(Theme.hairline), lineWidth: hair) }
            if style.node != .pebble && (t.selected || hovered) {
                let gap = 2 / scale
                let ring = rect.insetBy(dx: -gap - hair, dy: -gap - hair)
                if style.node == .frosted && t.selected {
                    // Mist's soft halo outside the selected pill.
                    let halo = rect.insetBy(dx: -4 / scale, dy: -4 / scale)
                    ctx.stroke(Path(roundedRect: halo, cornerRadius: halo.height / 2), with: .color(Theme.accent.opacity(0.24)), lineWidth: 6 / scale)
                } else {
                    ctx.stroke(Path(roundedRect: ring, cornerRadius: ring.height / 2),
                               with: .color(t.selected ? c : Theme.hairline), lineWidth: 2 / scale)
                }
            }
            var x = rect.minX + fs * 0.9
            let dot = fs * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot)),
                     with: .color(style.node == .pebble && t.selected ? Theme.onAccent : c))
            x += dot + fs * 0.45
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.5
            countBubble(at: x, fill: style.node == .pebble ? Theme.background : Theme.surfaceSunken)

        case .chunky:
            ctx.stroke(capsule, with: .color(Theme.label), lineWidth: 2 / scale)
            var x = rect.minX + fs * 0.9
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.5
            countBubble(at: x, fill: Theme.surface.opacity(0.7))

        case .specimen:
            ctx.stroke(box, with: .color(t.selected ? Theme.signal : Theme.hairline), lineWidth: (t.selected ? 1.5 : 1) * hair)
            // The corner tick, in the branch colour.
            let tick = fs * 0.45
            var corner = Path()
            corner.move(to: CGPoint(x: rect.minX, y: rect.minY))
            corner.addLine(to: CGPoint(x: rect.minX + tick, y: rect.minY))
            corner.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tick))
            corner.closeSubpath()
            ctx.fill(corner, with: .color(c))
            var x = rect.minX + fs * 0.7
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.5
            ctx.draw(t.count, at: CGPoint(x: x, y: rect.midY), anchor: .leading)

        case .drafted:
            ctx.stroke(box, with: .color(t.selected ? Theme.signal : Theme.hairline), lineWidth: (t.selected ? 1.5 : 1) * hair)
            // Dimension ticks past each corner.
            let tick = fs * 0.35
            var ticks = Path()
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(rect.minX, rect.minY, -1, -1), (rect.maxX, rect.minY, 1, -1),
                                                                    (rect.minX, rect.maxY, -1, 1), (rect.maxX, rect.maxY, 1, 1)]
            for (cx, cy, sx, sy) in corners {
                ticks.move(to: CGPoint(x: cx, y: cy)); ticks.addLine(to: CGPoint(x: cx + tick * sx, y: cy))
                ticks.move(to: CGPoint(x: cx, y: cy)); ticks.addLine(to: CGPoint(x: cx, y: cy + tick * sy))
            }
            ctx.stroke(ticks, with: .color(t.selected ? Theme.signal : Theme.labelSecondary), lineWidth: hair)
            var x = rect.minX + fs * 0.7
            let swatch = fs * 0.45
            ctx.fill(Path(CGRect(x: x, y: rect.midY - swatch / 2, width: swatch, height: swatch)), with: .color(c))
            x += swatch + fs * 0.45
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.5
            ctx.draw(t.count, at: CGPoint(x: x, y: rect.midY), anchor: .leading)

        case .block, .misprint:
            if style.node == .misprint { ctx.stroke(box, with: .color(Theme.label), lineWidth: 1.5 * hair) }
            var x = rect.minX + fs * 0.7
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.5
            ctx.draw(t.count, at: CGPoint(x: x, y: rect.midY), anchor: .leading)

        case .underline:
            // A word with a rule beneath and a superscript count; the selection is ruled in the second pen.
            let nameRect = CGRect(x: rect.minX, y: rect.midY - t.nameSize.height / 2, width: t.nameSize.width, height: t.nameSize.height)
            ctx.draw(t.name, at: CGPoint(x: nameRect.minX, y: nameRect.midY), anchor: .leading)
            ctx.draw(t.count, at: CGPoint(x: nameRect.maxX + fs * 0.15, y: nameRect.minY + fs * 0.1), anchor: .topLeading)
            var rule = Path()
            rule.move(to: CGPoint(x: nameRect.minX, y: nameRect.maxY + fs * 0.12))
            rule.addLine(to: CGPoint(x: nameRect.maxX, y: nameRect.maxY + fs * 0.12))
            ctx.stroke(rule, with: .color(t.selected ? Theme.signal : (hovered ? Theme.label : c)), lineWidth: (t.selected ? 2 : 1) * hair)

        case .lampWord:
            var x = rect.minX
            let dot = fs * 0.4
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot)), with: .color(t.selected ? Theme.accent : c))
            x += dot + fs * 0.4
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.35
            ctx.draw(t.count, at: CGPoint(x: x, y: rect.midY), anchor: .leading)

        case .star:
            let star = starRadius(count: t.total, fontSize: fs)
            let center = CGPoint(x: rect.minX + star, y: rect.midY)
            let tone = t.selected ? Theme.accent : Theme.label
            let glow = star * (t.selected || hovered ? 3.4 : 2.4)
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [(t.selected ? Theme.accent : c).opacity(0.35), .clear]),
                                           center: center, startRadius: 0, endRadius: glow))
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - star, y: center.y - star, width: star * 2, height: star * 2)), with: .color(tone))
            var x = rect.minX + star * 2 + fs * 0.5
            ctx.draw(t.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
            x += t.nameSize.width + fs * 0.4
            ctx.draw(t.count, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
        }
    }

    /// Screen-space textures that move with the map: Loom's dots, ruled paper, the drafting grid, Swiss columns.
    private func drawBackdrop(_ ctx: inout GraphicsContext, size: CGSize, style: ThemeStyle) {
        let originX = size.width / 2 + pan.width, originY = size.height / 2 + pan.height
        func first(_ origin: CGFloat, _ pitch: CGFloat) -> CGFloat {
            let r = origin.truncatingRemainder(dividingBy: pitch)
            return r < 0 ? r + pitch : r
        }
        func lines(pitch: CGFloat, vertical: Bool, horizontal: Bool) -> Path {
            var path = Path()
            if vertical {
                var x = first(originX, pitch)
                while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += pitch }
            }
            if horizontal {
                var y = first(originY, pitch)
                while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += pitch }
            }
            return path
        }

        switch style.canvas {
        case .dots:
            // 30pt pitch at 1× zoom, never tighter than 14pt on screen.
            var pitch = Theme.Space.s30 * scale
            while pitch < 14 { pitch *= 2 }
            var dots = Path()
            var y = first(originY, pitch)
            while y < size.height {
                var x = first(originX, pitch)
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += pitch
                }
                y += pitch
            }
            ctx.fill(dots, with: .color(Theme.mapDot))
        case .ruled:
            var pitch = 28 * scale
            while pitch < 14 { pitch *= 2 }
            ctx.stroke(lines(pitch: pitch, vertical: false, horizontal: true), with: .color(Theme.hairline.opacity(0.7)), lineWidth: 1)
        case .grid:
            // A 16/80 drafting grid; the minor lines drop out when they would crowd.
            let minor = 16 * scale
            var major = 80 * scale
            while major < 40 { major *= 2 }
            if minor >= 8 {
                ctx.stroke(lines(pitch: minor, vertical: true, horizontal: true), with: .color(Theme.hairline.opacity(0.35)), lineWidth: 0.5)
            }
            ctx.stroke(lines(pitch: major, vertical: true, horizontal: true), with: .color(Theme.hairline.opacity(0.8)), lineWidth: 1)
        case .columns:
            // The 4-column grid, fixed to the window.
            var rules = Path()
            for k in 1...3 {
                let x = (size.width * CGFloat(k) / 4).rounded()
                rules.move(to: CGPoint(x: x, y: 0)); rules.addLine(to: CGPoint(x: x, y: size.height))
            }
            ctx.stroke(rules, with: .color(Theme.label.opacity(0.07)), lineWidth: 1)
        default:
            break
        }
    }

    /// Textures that live on the map itself: stars, speckle, thrown rings, a halftone patch, mist blooms.
    private func drawWorldTexture(_ ctx: inout GraphicsContext, size: CGSize, style: ThemeStyle) {
        let visible = CGRect(x: (-size.width / 2 - pan.width) / scale, y: (-size.height / 2 - pan.height) / scale,
                             width: size.width / scale, height: size.height / scale)
        switch style.canvas {
        case .stars, .speckle:
            let stars = style.canvas == .stars
            var cell: CGFloat = stars ? 64 : 46
            while cell * scale < 28 { cell *= 2 }
            let x0 = Int((visible.minX / cell).rounded(.down)), x1 = Int((visible.maxX / cell).rounded(.up))
            let y0 = Int((visible.minY / cell).rounded(.down)), y1 = Int((visible.maxY / cell).rounded(.up))
            guard (x1 - x0 + 1) * (y1 - y0 + 1) < 5000 else { return }
            var buckets = [Path](repeating: Path(), count: 4)
            for i in x0...x1 {
                for j in y0...y1 {
                    let h = Self.noise(i, j)
                    let p = CGPoint(x: (CGFloat(i) + h.0) * cell, y: (CGFloat(j) + h.1) * cell)
                    let r = stars ? (0.5 + h.2 * 1.1) / scale : 1.5 + h.2 * 2.5
                    buckets[min(3, Int(h.3 * 4))].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }
            }
            let colors: [Color] = stars
                ? [0.16, 0.26, 0.4, 0.6].map { Theme.label.opacity($0) }
                : [Theme.chip(0), Theme.chip(1), Theme.signal, Theme.accent].map { $0.opacity(0.5) }
            for (k, path) in buckets.enumerated() { ctx.fill(path, with: .color(colors[k])) }
        case .rings:
            // Wheel-thrown rings behind the centre, fading out.
            var rings = Path()
            for k in 1...18 {
                let r = 20 + CGFloat(k) * 22
                rings.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
            }
            ctx.stroke(rings, with: .radialGradient(Gradient(colors: [Theme.hairline, Theme.hairline.opacity(0)]),
                                                    center: .zero, startRadius: 0, endRadius: 420), lineWidth: 1 / scale)
        case .halftone:
            // A halftone patch in pink, with a slightly off-register ink pass.
            let center = CGPoint(x: -220, y: -160), reach: CGFloat = 240, step: CGFloat = 11
            var dots = Path()
            var y = -reach
            while y <= reach {
                var x = -reach
                while x <= reach {
                    let d = (x * x + y * y).squareRoot()
                    let r = (1 - d / reach) * 4.2
                    if r > 0.4 { dots.addEllipse(in: CGRect(x: center.x + x - r, y: center.y + y - r, width: r * 2, height: r * 2)) }
                    x += step
                }
                y += step
            }
            ctx.fill(dots.offsetBy(dx: 3, dy: 2), with: .color(Theme.label.opacity(0.07)))
            ctx.fill(dots, with: .color(Theme.accent.opacity(0.26)))
        case .mist:
            let blooms: [(center: CGPoint, radius: CGFloat, tone: Color, alpha: Double)] = [
                (CGPoint(x: -280, y: -200), 420, Theme.signal, 0.16),
                (CGPoint(x: 260, y: 140), 460, Theme.accent, 0.1),
                (CGPoint(x: -40, y: 340), 340, Theme.signal, 0.1)
            ]
            for (center, radius, tone, alpha) in blooms {
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(colors: [tone.opacity(alpha), .clear]), center: center, startRadius: 0, endRadius: radius))
            }
        default:
            break
        }
    }

    /// Four stable pseudo-random values in 0...1 for a texture cell, so stars and speckles stay put.
    private static func noise(_ i: Int, _ j: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var h = UInt64(bitPattern: Int64((i &* 73_856_093) ^ (j &* 19_349_663)))
        func next() -> CGFloat {
            h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((h >> 33) & 0xffff) / 65_535
        }
        return (next(), next(), next(), next())
    }

    /// When hovering a node or a concept is selected: that node and its direct connections.
    private var focusSet: Set<Int>? {
        let center = hovered ?? selectedConcept.flatMap { sim.index[$0] }
        guard let center, sim.neighbors.indices.contains(center) else { return nil }
        return sim.neighbors[center].union([center])
    }

    private func matchingNodes(query: String, byID: [UUID: Item]) -> Set<Int> {
        var result = Set<Int>()
        for (i, node) in sim.nodes.enumerated() {
            switch node.kind {
            case .concept(let name, _):
                if name.lowercased().contains(query) { result.insert(i) }
            case .item(let id):
                guard let item = byID[id] else { continue }
                if item.displayTitle.lowercased().contains(query) || item.summary.lowercased().contains(query)
                    || item.takeaways.contains(where: { $0.lowercased().contains(query) })
                    || item.body.lowercased().contains(query) || item.tags.contains(where: { $0.contains(query) }) {
                    result.insert(i)
                }
            }
        }
        return result
    }

    /// Files of the given kinds, plus the concepts they connect to.
    private func kindNodes(_ kinds: Set<ItemKind>, byID: [UUID: Item]) -> Set<Int> {
        var result = Set<Int>()
        for (i, node) in sim.nodes.enumerated() {
            guard case .item(let id) = node.kind, let item = byID[id], kinds.contains(item.kind) else { continue }
            result.insert(i)
            for j in sim.neighbors[i] {
                if case .concept = sim.nodes[j].kind { result.insert(j) }
            }
        }
        return result
    }

    private var background: some View { Theme.background }

    // MARK: Gestures

    private func toWorld(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - pan.width) / scale, y: (p.y - size.height / 2 - pan.height) / scale)
    }

    /// One gesture for everything: drag a node to move it, drag empty space to pan, tap to open.
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil {
                    if let i = sim.hitTest(toWorld(value.startLocation, size: size), scale: scale) {
                        dragMode = .node(i)
                    } else {
                        dragMode = .pan(start: pan)
                    }
                }
                let moved = hypot(value.translation.width, value.translation.height) > 3
                switch dragMode {
                case .node(let i) where moved:
                    sim.pin(i, at: toWorld(value.location, size: size))
                case .pan(let start):
                    pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                default:
                    break
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 3
                if case .node(let i) = dragMode { sim.release(i) }
                if !moved { handleTap(at: toWorld(value.location, size: size)) }
                dragMode = nil
            }
    }

    private func handleTap(at p: CGPoint) {
        guard let i = sim.hitTest(p, scale: scale) else {
            withAnimation(Theme.motion) { selectedConcept = nil }
            return
        }
        switch sim.nodes[i].kind {
        case .item(let id):
            selection = id
        case .concept:
            let id = sim.nodes[i].id
            withAnimation(Theme.motion) { selectedConcept = selectedConcept == id ? nil : id }
        }
    }

    // MARK: Camera

    private func clampScale(_ s: CGFloat) -> CGFloat { min(4, max(0.12, s)) }

    private func fit() {
        let b = sim.bounds
        guard b.width > 0, b.height > 0, viewSize.width > 0 else { return }
        let s = clampScale(min((viewSize.width - 80) / b.width, (viewSize.height - 220) / b.height))
        scale = s
        baseScale = s
        pan = CGSize(width: -b.midX * s, height: -b.midY * s + 20)
    }

    /// Rebuilds the web once a burst of changes has ended. Adding a batch of files changes the library many
    /// times a second (each item, its thumbnail, its embedding, its tags), and each rebuild compares every item
    /// with every other; doing that for every change is what froze the app.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            sim.rebuild(items: items, spaces: spaces, linkSimilar: linkSimilar)
            if let id = pendingFocus {
                pendingFocus = nil
                focus(on: id)
            }
        }
    }

    private func focus(on id: String) {
        guard let p = sim.position(of: id) else {
            // Not on the map yet: fly there once the next rebuild has placed it.
            pendingFocus = id
            scheduleRebuild()
            return
        }
        let s = max(scale, 1.2)
        withAnimation(.spring(duration: 0.5)) {
            scale = s
            baseScale = s
            pan = CGSize(width: -p.x * s, height: -p.y * s)
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { withAnimation(Theme.motion) { scale = clampScale(scale * 1.3); baseScale = scale } } label: {
                Image(systemName: "plus").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            Rectangle().fill(Theme.hairline).frame(width: 24, height: 1)
            Button { withAnimation(Theme.motion) { scale = clampScale(scale / 1.3); baseScale = scale } } label: {
                Image(systemName: "minus").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            Rectangle().fill(Theme.hairline).frame(width: 24, height: 1)
            Button { withAnimation(Theme.motion) { fit() } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 40, height: 40).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .font(.body)
        .loomSymbols()
        .foregroundStyle(Theme.label)
        .floatingChrome(RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .padding(.trailing, Theme.Space.s20)
        .padding(.bottom, 96)
    }

    // MARK: Overlays

    /// Preview card that follows the pointer on Mac / iPad.
    @ViewBuilder
    private func hoverCard(byID: [UUID: Item], size: CGSize) -> some View {
        if dragMode == nil, let i = hovered, sim.nodes.indices.contains(i), case .item(let id) = sim.nodes[i].kind, let item = byID[id] {
            ItemCard(item: item, color: color(of: sim.nodes[i]), selected: selection == id)
                .allowsHitTesting(false)
                .offset(x: min(hoverLocation.x + 16, size.width - Theme.itemCardWidth - 8), y: min(hoverLocation.y + 16, size.height - 240))
                .transition(.opacity)
        }
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.s12) {
            // Names when there's room; symbols alone on a narrow iPhone.
            ViewThatFits(in: .horizontal) {
                kindKey(showNames: true)
                kindKey(showNames: false)
            }
            Menu {
                Toggle("Link Related Files", isOn: $linkSimilar)
                Toggle("Always Show File Names", isOn: $alwaysShowNames)
                Divider()
                Button("Fit to Screen") { withAnimation(Theme.motion) { fit() } }
                Button("Shake Up Layout") { sim.resetLayout() }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.caption).loomSymbols()
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(Theme.labelSecondary)
        .padding(.horizontal, Theme.Space.s8).padding(.vertical, Theme.Space.s2)
        // Not interactive: the glass would take the tap on iPhone before the buttons inside it see it.
        .floatingChrome(Theme.pillShape, interactive: false)
        .padding(.leading, Theme.Space.s20)
        .padding(.top, 80)
    }

    private func kindKey(showNames: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(ItemKind.allCases) { kind in
                let on = kindFilter.contains(kind)
                Button {
                    withAnimation(Theme.motion) {
                        if on { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
                    }
                } label: {
                    HStack(spacing: Theme.Space.s4) {
                        Image(systemName: kind.symbol).font(.caption2).loomSymbols()
                        if showNames { Text(kind.label).loomLabel() }
                    }
                    .foregroundStyle(on ? Theme.accentInk : Theme.labelSecondary)
                    .padding(.horizontal, showNames ? Theme.Space.s6 : Theme.Space.s8)
                    .frame(minWidth: 30, minHeight: 36)
                    .background(on ? Theme.accentTint : .clear, in: Theme.pillShape)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(kind.label)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(on ? "Show all kinds" : "Show only \(kind.label.lowercased())")
            }
        }
    }

    /// Shown when a concept is selected: what it is and a shortcut to add to it.
    @ViewBuilder
    private var conceptChip: some View {
        if let id = selectedConcept, let i = sim.index[id], case .concept(let name, let isSpace) = sim.nodes[i].kind {
            HStack(spacing: Theme.Space.s12) {
                Circle().fill(color(of: sim.nodes[i])).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: Theme.Space.s2) {
                    Text(isSpace ? name : name.capitalized).font(.loomTitle3).serifTracking().foregroundStyle(Theme.label)
                    Text("\(sim.neighbors[i].count) connected").loomLabel().foregroundStyle(Theme.labelSecondary)
                }
                if !isSpace {
                    Button {
                        newNoteTags = [name]
                        showingNewNote = true
                    } label: { Label("New note here", systemImage: "square.and.pencil") }
                    .buttonStyle(.bordered)
                }
                Button { withAnimation(Theme.motion) { selectedConcept = nil } } label: { Image(systemName: "xmark").loomSymbols() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.labelSecondary)
            }
            .padding(Theme.Space.s16)
            .surfaceTile(RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .padding(.leading, Theme.Space.s20)
            .padding(.bottom, 92)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.s12) {
            Image(systemName: "brain.head.profile").font(.system(size: 36, weight: Theme.style.symbolWeight)).foregroundStyle(Theme.labelSecondary)
            Text("Your mind map grows as you save things").font(.loomTitle3).serifTracking().foregroundStyle(Theme.label)
            Text("Add notes, links, photos, videos or files with +, or drop them here. The on-device AI finds the concepts and connects everything.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.labelSecondary).frame(maxWidth: 400)
        }
        .padding(Theme.Space.s24)
        .surfaceTile(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
    }
}

/// A file on the map: a 200pt white card with a hairline, a soft shadow, an inset thumbnail,
/// a kind badge in the branch color and, when selected, a 2px ring in that color.
struct ItemCard: View {
    let item: Item
    let color: Color
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data = item.thumbnail, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: Theme.itemCardWidth - Theme.Space.s12, height: 108 - Theme.Space.s12)
                    .clipShape(RoundedRectangle(cornerRadius: max(0, Theme.Radius.card - Theme.Space.s6)))
                    .overlay {
                        if item.kind == .video {
                            Image(systemName: "play.circle.fill").font(.system(size: 30))
                                .foregroundStyle(.white).shadow(radius: 3)
                        }
                    }
                    .padding([.top, .horizontal], Theme.Space.s6)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack(spacing: Theme.Space.s6) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(color, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                    Text(item.url?.host() ?? item.kind.label.dropLast().description)
                        .loomLabel()
                        .foregroundStyle(Theme.labelSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.favorite)
                    }
                }
                Text(item.displayTitle)
                    .font(Theme.current.display.font(size: 15, relativeTo: .footnote))
                    .serifTracking()
                    .foregroundStyle(Theme.label)
                    .lineLimit(2)
                if !item.preview.isEmpty {
                    Text(item.preview).font(.caption2).foregroundStyle(Theme.labelSecondary).lineLimit(3)
                }
                ForEach(Array(item.takeaways.prefix(2).enumerated()), id: \.offset) { _, lesson in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
                        Image(systemName: "sparkles").font(.system(size: 8)).foregroundStyle(Theme.accentInk)
                        Text(lesson).font(.caption2).foregroundStyle(Theme.label).lineLimit(2)
                    }
                }
                if !item.tags.isEmpty {
                    Text(item.tags.prefix(4).map { "#\($0)" }.joined(separator: " "))
                        .font(.loomLabel).foregroundStyle(Theme.labelSecondary).lineLimit(1)
                }
            }
            .padding(Theme.Space.s12)
        }
        .frame(width: Theme.itemCardWidth, alignment: .leading)
        .surfaceTile(RoundedRectangle(cornerRadius: Theme.Radius.card), lifted: selected)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Radius.card + 4)
                    .strokeBorder(color, lineWidth: 2)
                    .padding(-4)
            }
        }
    }
}

/// A topic laid out for drawing on the map: its box, resolved text and selection.
private struct MapTopic {
    let index: Int
    let rect: CGRect
    let name: GraphicsContext.ResolvedText
    let count: GraphicsContext.ResolvedText
    let nameSize: CGSize
    let countSize: CGSize
    let selected: Bool
    let fontSize: CGFloat
    /// How many things the topic holds.
    let total: Int
    let corner: CGFloat
    let colorIndex: Int
}
