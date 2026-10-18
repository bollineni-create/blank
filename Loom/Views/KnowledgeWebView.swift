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
    @ObservationIgnored private var alpha: CGFloat = 1
    @ObservationIgnored private var alphaTarget: CGFloat = 0

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
                                 radius: 10 + CGFloat(count).squareRoot() * 3.5, colorIndex: i, count: count))
        }
        for space in spaces {
            let count = items.filter { $0.space?.id == space.id }.count
            let id = "space:\(space.id)"
            let p = startPosition(id, near: nil)
            newIndex[id] = newNodes.count
            newNodes.append(Node(id: id, kind: .concept(name: "\(space.emoji) \(space.name)", isSpace: true), x: p.x, y: p.y,
                                 radius: 12 + CGFloat(count).squareRoot() * 3, colorIndex: -1, count: count))
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
            newNodes.append(Node(id: id, kind: .item(item.id), x: p.x, y: p.y, radius: 7,
                                 colorIndex: ItemKind.allCases.firstIndex(of: item.kind) ?? 0, count: 0))
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
        guard !settled else { return }
        step()
        if alpha < 0.004 && alphaTarget == 0 {
            savePositions()
            DispatchQueue.main.async { self.settled = true }
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
    @State private var viewSize: CGSize = .zero
    @State private var newNoteTags: [String]?
    @State private var showingNewNote = false

    private enum DragMode {
        case node(Int)
        case pan(start: CGSize)
    }

    static let conceptPalette: [Color] = [
        Color(red: 0.98, green: 0.45, blue: 0.29), Color(red: 0.25, green: 0.52, blue: 0.96),
        Color(red: 0.16, green: 0.70, blue: 0.50), Color(red: 0.90, green: 0.32, blue: 0.62),
        Color(red: 0.55, green: 0.38, blue: 0.95), Color(red: 0.08, green: 0.66, blue: 0.75),
        Color(red: 0.95, green: 0.66, blue: 0.13), Color(red: 0.36, green: 0.42, blue: 0.86),
        Color(red: 0.85, green: 0.25, blue: 0.30), Color(red: 0.42, green: 0.70, blue: 0.20),
    ]

    /// File colours by type, in `ItemKind.allCases` order: note, link, image, video, pdf, file.
    static let kindColors: [Color] = [
        Color(red: 0.30, green: 0.56, blue: 0.98), Color(red: 0.18, green: 0.72, blue: 0.48),
        Color(red: 0.93, green: 0.36, blue: 0.62), Color(red: 0.92, green: 0.30, blue: 0.27),
        Color(red: 0.97, green: 0.58, blue: 0.16), Color(red: 0.55, green: 0.57, blue: 0.62),
    ]

    private func color(of node: WebSimulation.Node) -> Color {
        switch node.kind {
        case .concept(_, let isSpace):
            isSpace ? Color.accentColor : Self.conceptPalette[node.colorIndex % Self.conceptPalette.count]
        case .item:
            Self.kindColors[node.colorIndex % Self.kindColors.count]
        }
    }

    /// Changes whenever something that shapes the web changes.
    private var signature: String {
        items.map { "\($0.id)|\($0.tags.joined(separator: ","))|\($0.space?.id.uuidString ?? "")|\($0.embedding?.count ?? 0)|\($0.thumbnail?.count ?? 0)" }
            .joined(separator: ";") + "#\(spaces.map(\.name).joined())#\(linkSimilar)"
    }

    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: sim.settled)) { _ in
                let _ = sim.tick()
                canvas(byID: byID, size: geometry.size)
            }
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
        .onChange(of: signature) { _, _ in sim.rebuild(items: items, spaces: spaces, linkSimilar: linkSimilar) }
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
        let showFileNames = alwaysShowNames || scale > 1.1

        return Canvas { ctx, size in
            ctx.translateBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            ctx.scaleBy(x: scale, y: scale)
            let nodes = sim.nodes

            func dimmed(_ i: Int) -> Bool {
                if let focus, !focus.contains(i) { return true }
                if let matches, !matches.contains(i) { return true }
                return false
            }

            // Links
            for link in sim.links {
                let a = nodes[link.a], b = nodes[link.b]
                var path = Path()
                path.move(to: CGPoint(x: a.x, y: a.y))
                path.addLine(to: CGPoint(x: b.x, y: b.y))
                let lit = focus.map { $0.contains(link.a) && $0.contains(link.b) } ?? false
                let faded = dimmed(link.a) || dimmed(link.b)
                let base = link.isSimilarity ? Color.secondary : color(of: a)
                let opacity: Double = faded ? 0.05 : (lit ? 0.85 : (link.isSimilarity ? 0.25 : 0.35))
                ctx.stroke(path, with: .color(base.opacity(opacity)),
                           style: StrokeStyle(lineWidth: (lit ? 2.2 : 1.2) / max(scale, 0.6),
                                              lineCap: .round, dash: link.isSimilarity ? [3, 4] : []))
            }

            // Nodes
            for (i, node) in nodes.enumerated() {
                let c = color(of: node)
                let faded = dimmed(i)
                let isHovered = hovered == i
                var r = node.radius * (isHovered ? 1.25 : 1)
                var selected = false
                if case .item(let id) = node.kind {
                    selected = selection == id
                    if selected { r *= 1.3 }
                }
                let rect = CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2)
                ctx.opacity = faded ? 0.15 : 1

                switch node.kind {
                case .concept(_, let isSpace):
                    // Glow, then a gradient disc.
                    ctx.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.6, dy: -r * 0.6)), with: .color(c.opacity(0.14)))
                    let shape = isSpace ? Path(roundedRect: rect, cornerRadius: r * 0.45) : Path(ellipseIn: rect)
                    ctx.fill(shape, with: .linearGradient(Gradient(colors: [c.opacity(0.95), c.opacity(0.7)]),
                                                         startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                                         endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                    if selectedConcept == node.id {
                        ctx.stroke(shape, with: .color(.primary), lineWidth: 2.5 / scale)
                    }
                case .item(let id):
                    if let image = sim.images[id], scale > 0.8 || isHovered || selected {
                        let big = rect.insetBy(dx: -r * 0.5, dy: -r * 0.5)
                        ctx.drawLayer { layer in
                            layer.clip(to: Path(ellipseIn: big))
                            layer.draw(image, in: big)
                        }
                        ctx.stroke(Path(ellipseIn: big), with: .color(c), lineWidth: 2 / scale)
                    } else {
                        ctx.fill(Path(ellipseIn: rect), with: .color(c))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.7)), lineWidth: 1 / scale)
                    }
                    if selected {
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -r * 0.7, dy: -r * 0.7)), with: .color(c), lineWidth: 2.5 / scale)
                    }
                }
                ctx.opacity = 1
            }

            // Labels last so they sit on top.
            for (i, node) in nodes.enumerated() {
                let faded = dimmed(i)
                switch node.kind {
                case .concept(let name, _):
                    let fontSize = min(22, max(11, 13 / scale.squareRoot()))
                    ctx.opacity = faded ? 0.2 : 1
                    ctx.draw(Text(name.capitalized).font(.system(size: fontSize, weight: .bold)).foregroundStyle(.primary),
                             at: CGPoint(x: node.x, y: node.y + node.radius + 4), anchor: .top)
                case .item(let id):
                    let wanted = showFileNames || hovered == i || selection == id || (focus?.contains(i) ?? false) || (matches?.contains(i) ?? false)
                    guard wanted, !faded, let item = byID[id] else { continue }
                    let title = item.displayTitle
                    let short = title.count > 32 ? String(title.prefix(30)) + "…" : title
                    ctx.opacity = 1
                    ctx.draw(Text(short).font(.system(size: max(9, 11 / scale.squareRoot()), weight: .medium)).foregroundStyle(.secondary),
                             at: CGPoint(x: node.x, y: node.y + node.radius + 3), anchor: .top)
                }
            }
            ctx.opacity = 1
        }
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

    private var background: some View {
        ZStack {
            Color(white: 0.5).opacity(0.04)
            RadialGradient(colors: [Color.accentColor.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 700)
        }
        .background(.background)
    }

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
            withAnimation(.easeOut(duration: 0.2)) { selectedConcept = nil }
            return
        }
        switch sim.nodes[i].kind {
        case .item(let id):
            selection = id
        case .concept:
            let id = sim.nodes[i].id
            withAnimation(.easeOut(duration: 0.2)) { selectedConcept = selectedConcept == id ? nil : id }
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

    private func focus(on id: String) {
        guard let p = sim.position(of: id) else { return }
        let s = max(scale, 1.2)
        withAnimation(.spring(duration: 0.5)) {
            scale = s
            baseScale = s
            pan = CGSize(width: -p.x * s, height: -p.y * s)
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.spring) { scale = clampScale(scale * 1.3); baseScale = scale } } label: {
                Image(systemName: "plus").frame(width: 38, height: 38)
            }
            Divider().frame(width: 38)
            Button { withAnimation(.spring) { scale = clampScale(scale / 1.3); baseScale = scale } } label: {
                Image(systemName: "minus").frame(width: 38, height: 38)
            }
            Divider().frame(width: 38)
            Button { withAnimation(.spring) { fit() } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 38, height: 38)
            }
        }
        .buttonStyle(.plain)
        .font(.body.weight(.semibold))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.trailing, 16)
        .padding(.bottom, 96)
    }

    // MARK: Overlays

    /// Preview card that follows the pointer on Mac / iPad.
    @ViewBuilder
    private func hoverCard(byID: [UUID: Item], size: CGSize) -> some View {
        if dragMode == nil, let i = hovered, sim.nodes.indices.contains(i), case .item(let id) = sim.nodes[i].kind, let item = byID[id] {
            MapItemCard(item: item, color: color(of: sim.nodes[i]))
                .allowsHitTesting(false)
                .offset(x: min(hoverLocation.x + 16, size.width - 200), y: min(hoverLocation.y + 16, size.height - 160))
                .transition(.opacity)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Array(ItemKind.allCases.enumerated()), id: \.offset) { i, kind in
                HStack(spacing: 4) {
                    Circle().fill(Self.kindColors[i]).frame(width: 8, height: 8)
                    Text(kind.label).font(.caption2.weight(.medium))
                }
            }
            Menu {
                Toggle("Link Related Files", isOn: $linkSimilar)
                Toggle("Always Show File Names", isOn: $alwaysShowNames)
                Divider()
                Button("Fit to Screen") { withAnimation(.spring) { fit() } }
                Button("Shake Up Layout") { sim.resetLayout() }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.caption.weight(.bold)).frame(width: 26, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(.leading, 16)
        .padding(.top, 74)
    }

    /// Shown when a concept is selected: what it is and a shortcut to add to it.
    @ViewBuilder
    private var conceptChip: some View {
        if let id = selectedConcept, let i = sim.index[id], case .concept(let name, let isSpace) = sim.nodes[i].kind {
            HStack(spacing: 10) {
                Circle().fill(color(of: sim.nodes[i])).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.capitalized).font(.headline)
                    Text("\(sim.neighbors[i].count) connected").font(.caption).foregroundStyle(.secondary)
                }
                if !isSpace {
                    Button {
                        newNoteTags = [name]
                        showingNewNote = true
                    } label: { Label("New note here", systemImage: "square.and.pencil") }
                    .buttonStyle(.bordered)
                }
                Button { withAnimation { selectedConcept = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.leading, 16)
            .padding(.bottom, 92)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text("Your web grows as you save things").font(.title3.bold())
            Text("Add notes, links, photos, videos or files with +, or drop them here. The on-device AI finds the concepts and connects everything.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Preview card for a file (shown on hover).
struct MapItemCard: View {
    let item: Item
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data = item.thumbnail, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 100)
                    .clipped()
                    .overlay {
                        if item.kind == .video {
                            Image(systemName: "play.circle.fill").font(.system(size: 30))
                                .foregroundStyle(.white).shadow(radius: 3)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(color, in: RoundedRectangle(cornerRadius: 5))
                    Text(item.url?.host() ?? item.kind.label.dropLast().description)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                } else if !item.preview.isEmpty {
                    Text(item.preview).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
                ForEach(Array(item.takeaways.prefix(2).enumerated()), id: \.offset) { _, lesson in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                        Text(lesson).font(.caption2).lineLimit(2)
                    }
                }
                if !item.tags.isEmpty {
                    Text(item.tags.prefix(4).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(color).lineLimit(1)
                }
            }
            .padding(10)
        }
        .frame(width: 200, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}
