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
        let kinds = kindFilter.isEmpty ? nil : kindNodes(kindFilter, byID: byID)
        let showFileNames = alwaysShowNames || scale > 1.1
        let busy = librarian.busyItemIDs

        return Canvas { ctx, size in
            drawGrid(&ctx, size: size)
            ctx.translateBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            ctx.scaleBy(x: scale, y: scale)
            let nodes = sim.nodes
            let compact = scale < 0.42

            // The celadon → terracotta light at the map center.
            let glowRadius: CGFloat = 520
            ctx.fill(Path(ellipseIn: CGRect(x: -glowRadius, y: -glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                     with: .radialGradient(Gradient(stops: [.init(color: Theme.glowSignal, location: 0),
                                                            .init(color: Theme.glowAccent, location: 0.45),
                                                            .init(color: .clear, location: 1)]),
                                           center: .zero, startRadius: 0, endRadius: glowRadius))

            func dimmed(_ i: Int) -> Bool {
                if let focus, !focus.contains(i) { return true }
                if let matches, !matches.contains(i) { return true }
                if let kinds, !kinds.contains(i) { return true }
                return false
            }

            // Edges: thin curves in the branch color, no glow. Related files get a faint dashed link.
            for link in sim.links {
                let a = nodes[link.a], b = nodes[link.b]
                let from = CGPoint(x: a.x, y: a.y), to = CGPoint(x: b.x, y: b.y)
                var path = Path()
                path.move(to: from)
                let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                let bend: CGFloat = 0.12
                path.addQuadCurve(to: to, control: CGPoint(x: mid.x - (to.y - from.y) * bend, y: mid.y + (to.x - from.x) * bend))
                let lit = focus.map { $0.contains(link.a) && $0.contains(link.b) } ?? false
                let faded = dimmed(link.a) || dimmed(link.b)
                let width = (lit ? 2 : 1.5) / max(scale, 0.6)
                if link.isSimilarity {
                    ctx.stroke(path, with: .color(Theme.labelTertiary.opacity(faded ? 0.05 : (lit ? 0.7 : 0.3))),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [4 / max(scale, 0.6), 6 / max(scale, 0.6)]))
                } else {
                    ctx.stroke(path, with: .color(color(of: a).opacity(faded ? 0.05 : (lit ? 0.8 : 0.45))),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }

            // Files: white discs with a hairline, the kind symbol and a ring in the branch color.
            // Zoomed far out they become plain branch-colored dots.
            ctx.drawLayer { layer in
                if !compact { layer.addFilter(.shadow(color: Color(hex: 0x2b1d16, opacity: 0.12), radius: 3, x: 0, y: 1)) }
                for (i, node) in nodes.enumerated() {
                    guard case .item(let id) = node.kind else { continue }
                    let c = color(of: node)
                    let isHovered = hovered == i
                    let selected = selection == id
                    var r = node.radius + (compact ? 0 : 3)
                    if isHovered || selected { r *= 1.2 }
                    let rect = CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2)
                    layer.opacity = dimmed(i) ? Theme.dimmedOpacity : 1

                    if compact {
                        layer.fill(Path(ellipseIn: rect), with: .color(c))
                    } else if let image = sim.images[id], scale > 0.8 || isHovered || selected {
                        let big = rect.insetBy(dx: -r * 0.4, dy: -r * 0.4)
                        layer.drawLayer { inner in
                            inner.clip(to: Path(ellipseIn: big))
                            inner.draw(image, in: big)
                        }
                        layer.stroke(Path(ellipseIn: big), with: .color(c), lineWidth: 1.5 / scale)
                    } else {
                        layer.fill(Path(ellipseIn: rect), with: .color(Theme.surface))
                        layer.stroke(Path(ellipseIn: rect.insetBy(dx: 0.75 / scale, dy: 0.75 / scale)), with: .color(c), lineWidth: 1.5 / scale)
                        if r * scale >= 9, let item = byID[id] {
                            layer.draw(Text(Image(systemName: item.kind.symbol))
                                        .font(.system(size: r * 0.95, weight: .medium))
                                        .foregroundStyle(Theme.labelSecondary),
                                       at: CGPoint(x: node.x, y: node.y))
                        }
                    }
                    if selected {
                        // Selection: a 2px ring in the branch color, offset 2px.
                        let outer = (sim.images[id] != nil && (scale > 0.8 || isHovered || selected)) ? r * 1.4 : r
                        let gap = 2 / scale
                        layer.stroke(Path(ellipseIn: CGRect(x: node.x - outer - gap - 1 / scale, y: node.y - outer - gap - 1 / scale,
                                                            width: (outer + gap + 1 / scale) * 2, height: (outer + gap + 1 / scale) * 2)),
                                     with: .color(c), lineWidth: 2 / scale)
                    }
                    if busy.contains(id) {
                        // Still being copied, read or summarized.
                        layer.stroke(Path(ellipseIn: rect.insetBy(dx: -r * 0.9, dy: -r * 0.9)), with: .color(Theme.accentInk),
                                     style: StrokeStyle(lineWidth: 1.5 / scale, dash: [4 / scale, 3 / scale]))
                    }
                }
            }

            // File names under the discs.
            for (i, node) in nodes.enumerated() {
                guard case .item(let id) = node.kind else { continue }
                let wanted = showFileNames || hovered == i || selection == id || (focus?.contains(i) ?? false) || (matches?.contains(i) ?? false)
                guard wanted, !dimmed(i), !compact, let item = byID[id] else { continue }
                let title = item.displayTitle
                let short = title.count > 32 ? String(title.prefix(30)) + "…" : title
                ctx.draw(Text(short).font(.system(size: max(9, 11 / scale.squareRoot()), weight: .medium)).foregroundStyle(Theme.labelSecondary),
                         at: CGPoint(x: node.x, y: node.y + node.radius + 6), anchor: .top)
            }

            // Concepts: white surface pills with a hairline, a branch-color dot, the name and a count.
            let fontSize = min(24, max(13, 15 / scale.squareRoot()))
            var pills: [(index: Int, rect: CGRect, name: GraphicsContext.ResolvedText, count: GraphicsContext.ResolvedText,
                         nameSize: CGSize, countSize: CGSize)] = []
            for (i, node) in nodes.enumerated() {
                guard case .concept(let name, let isSpace) = node.kind else { continue }
                let label = ctx.resolve(Text(isSpace ? name : name.capitalized)
                    .font(.system(size: fontSize, weight: .semibold)).foregroundStyle(Theme.label))
                let count = ctx.resolve(Text("\(node.count)")
                    .font(.system(size: fontSize * 0.72, weight: .bold)).foregroundStyle(Theme.labelSecondary))
                let nameSize = label.measure(in: CGSize(width: 1000, height: 200))
                let countSize = count.measure(in: CGSize(width: 200, height: 200))
                let width = fontSize * 0.9 + fontSize * 0.5 + fontSize * 0.45 + nameSize.width + fontSize * 0.5 + countSize.width + fontSize * 0.8 + fontSize * 0.5
                let height = nameSize.height + fontSize * 0.8
                let rect = CGRect(x: node.x - width / 2, y: node.y - height / 2, width: width, height: height)
                pills.append((i, rect, label, count, nameSize, countSize))
                sim.pillHalfSizes[i] = CGSize(width: width / 2, height: height / 2)
            }
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: Color(hex: 0x2b1d16, opacity: 0.08), radius: 6, x: 0, y: 3))
                for pill in pills {
                    layer.opacity = dimmed(pill.index) ? Theme.dimmedOpacity : 1
                    layer.fill(Path(roundedRect: pill.rect, cornerRadius: pill.rect.height / 2), with: .color(Theme.surface))
                }
            }
            for pill in pills {
                let node = nodes[pill.index]
                let c = color(of: node)
                let rect = pill.rect
                ctx.opacity = dimmed(pill.index) ? Theme.dimmedOpacity : 1
                let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2)
                ctx.stroke(capsule, with: .color(Theme.hairline), lineWidth: 1 / scale)
                if selectedConcept == node.id || hovered == pill.index {
                    let gap = 2 / scale
                    let ring = rect.insetBy(dx: -gap - 1 / scale, dy: -gap - 1 / scale)
                    ctx.stroke(Path(roundedRect: ring, cornerRadius: ring.height / 2),
                               with: .color(selectedConcept == node.id ? c : Theme.hairline), lineWidth: 2 / scale)
                }
                var x = rect.minX + fontSize * 0.9
                let dot = fontSize * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot)), with: .color(c))
                x += dot + fontSize * 0.45
                ctx.draw(pill.name, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
                x += pill.nameSize.width + fontSize * 0.5
                let countRect = CGRect(x: x, y: rect.midY - (pill.countSize.height + fontSize * 0.3) / 2,
                                       width: pill.countSize.width + fontSize * 0.8, height: pill.countSize.height + fontSize * 0.3)
                ctx.fill(Path(roundedRect: countRect, cornerRadius: countRect.height / 2), with: .color(Theme.surfaceSunken))
                ctx.draw(pill.count, at: CGPoint(x: countRect.midX, y: countRect.midY))
            }
            ctx.opacity = 1
        }
    }

    /// The map's dot grid: 30pt pitch at 1× zoom (never tighter than 14pt on screen), moving with the map.
    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        var pitch = Theme.Space.s30 * scale
        while pitch < 14 { pitch *= 2 }
        let originX = (size.width / 2 + pan.width).truncatingRemainder(dividingBy: pitch)
        let originY = (size.height / 2 + pan.height).truncatingRemainder(dividingBy: pitch)
        var dots = Path()
        var y = originY < 0 ? originY + pitch : originY
        while y < size.height {
            var x = originX < 0 ? originX + pitch : originX
            while x < size.width {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                x += pitch
            }
            y += pitch
        }
        ctx.fill(dots, with: .color(Theme.mapDot))
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
        if sim.position(of: id) == nil { sim.rebuild(items: items, spaces: spaces, linkSimilar: linkSimilar) }
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
                Image(systemName: "plus").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            Rectangle().fill(Theme.hairline).frame(width: 24, height: 1)
            Button { withAnimation(.spring) { scale = clampScale(scale / 1.3); baseScale = scale } } label: {
                Image(systemName: "minus").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            Rectangle().fill(Theme.hairline).frame(width: 24, height: 1)
            Button { withAnimation(.spring) { fit() } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 40, height: 40).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .font(.body.weight(.medium))
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
                Button("Fit to Screen") { withAnimation(.spring) { fit() } }
                Button("Shake Up Layout") { sim.resetLayout() }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.caption.weight(.semibold))
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
        .floatingChrome(Capsule(), interactive: false)
        .padding(.leading, Theme.Space.s20)
        .padding(.top, 80)
    }

    private func kindKey(showNames: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(ItemKind.allCases) { kind in
                let on = kindFilter.contains(kind)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if on { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
                    }
                } label: {
                    HStack(spacing: Theme.Space.s4) {
                        Image(systemName: kind.symbol).font(.caption2.weight(.medium))
                        if showNames { Text(kind.label).font(.caption2.weight(.medium)) }
                    }
                    .foregroundStyle(on ? Theme.accentInk : Theme.labelSecondary)
                    .padding(.horizontal, showNames ? Theme.Space.s6 : Theme.Space.s8)
                    .frame(minWidth: 30, minHeight: 36)
                    .background(on ? Theme.accentTint : .clear, in: Capsule())
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
                    Text(isSpace ? name : name.capitalized).font(.headline).foregroundStyle(Theme.label)
                    Text("\(sim.neighbors[i].count) connected").font(.caption).foregroundStyle(Theme.labelSecondary)
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
            Image(systemName: "brain.head.profile").font(.system(size: 36, weight: .regular)).foregroundStyle(Theme.labelSecondary)
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
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - Theme.Space.s6))
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
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.labelSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.favorite)
                    }
                }
                Text(item.displayTitle)
                    .font(.footnote.weight(.semibold))
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
                        .font(.caption2).foregroundStyle(Theme.labelSecondary).lineLimit(1)
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
