import SwiftUI
import SwiftData

/// How the map branches out from the center.
enum MapGrouping: String, CaseIterable, Identifiable {
    case tags, spaces, types

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tags: "Topics"
        case .spaces: "Spaces"
        case .types: "Types"
        }
    }
}

/// A branch of the map: a topic, space or type, and the items under it.
struct MapGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [Item]
    /// Tag to give new notes created from this branch.
    let tag: String?
    let space: Space?
}

enum MapNodeKind {
    case root
    case group(MapGroup)
    case item(Item)
}

struct MapNode: Identifiable {
    let id: String
    let kind: MapNodeKind
    /// Group the node belongs to (for items) or is (for groups). Used for colour and dragging.
    let groupID: String?
    let colorIndex: Int
    /// Position in map space, where the center of the map is (0, 0).
    var position: CGPoint
}

struct MapEdge: Identifiable {
    let from: String
    let to: String
    let colorIndex: Int
    /// Dashed edges link an item to a second topic it also belongs to.
    let isSecondary: Bool

    var id: String { "\(from)->\(to)" }
}

/// Radial layout: groups on a ring around the center, items fanned out behind each group.
enum MindMapLayout {
    static let itemSpacing: CGFloat = 165
    static let ringGap: CGFloat = 105

    static func groups(for items: [Item], spaces: [Space], grouping: MapGrouping) -> [MapGroup] {
        switch grouping {
        case .tags:
            var counts: [String: Int] = [:]
            for item in items { for tag in item.tags { counts[tag, default: 0] += 1 } }
            let topics = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(16).map(\.key)
            let shown = Set(topics)
            var buckets: [String: [Item]] = [:]
            var loose: [Item] = []
            for item in items {
                // Each item hangs off its first visible topic; other topics get a dashed link.
                if let primary = item.tags.first(where: shown.contains) {
                    buckets[primary, default: []].append(item)
                } else {
                    loose.append(item)
                }
            }
            var result = topics.map {
                MapGroup(id: "tag:\($0)", title: $0, symbol: "number", items: buckets[$0] ?? [], tag: $0, space: nil)
            }
            if !loose.isEmpty {
                result.append(MapGroup(id: "tag:", title: "Unsorted", symbol: "tray", items: loose, tag: nil, space: nil))
            }
            return result

        case .spaces:
            var result = spaces.map { space in
                MapGroup(id: "space:\(space.id)", title: "\(space.emoji) \(space.name)", symbol: "folder",
                         items: items.filter { $0.space?.id == space.id }, tag: nil, space: space)
            }
            let loose = items.filter { $0.space == nil }
            if !loose.isEmpty {
                result.append(MapGroup(id: "space:", title: "No space", symbol: "tray", items: loose, tag: nil, space: nil))
            }
            return result

        case .types:
            return ItemKind.allCases.compactMap { kind in
                let matching = items.filter { $0.kind == kind }
                return matching.isEmpty ? nil
                    : MapGroup(id: "type:\(kind.rawValue)", title: kind.label, symbol: kind.symbol,
                               items: matching, tag: nil, space: nil)
            }
        }
    }

    static func build(groups: [MapGroup], expanded: Set<String>, grouping: MapGrouping) -> (nodes: [MapNode], edges: [MapEdge]) {
        var nodes = [MapNode(id: "root", kind: .root, groupID: nil, colorIndex: 0, position: .zero)]
        var edges: [MapEdge] = []
        guard !groups.isEmpty else { return (nodes, edges) }

        let count = CGFloat(groups.count)
        let ringRadius = max(240, count * 62)
        // How wide each group's fan of items may spread before it runs into its neighbours.
        let fanSpan = min(.pi * 0.95, (2 * .pi / count) * 0.92)

        for (index, group) in groups.enumerated() {
            let angle = 2 * .pi * CGFloat(index) / count - .pi / 2
            let groupPosition = CGPoint(x: cos(angle) * ringRadius, y: sin(angle) * ringRadius)
            nodes.append(MapNode(id: group.id, kind: .group(group), groupID: group.id, colorIndex: index, position: groupPosition))
            edges.append(MapEdge(from: "root", to: group.id, colorIndex: index, isSecondary: false))

            guard expanded.contains(group.id) else { continue }
            var remaining = group.items[...]
            var ring = 0
            while !remaining.isEmpty {
                let distance = 175 + CGFloat(ring) * ringGap
                let capacity = max(1, Int((fanSpan * (ringRadius + distance) / ringRadius) * distance / itemSpacing))
                let row = remaining.prefix(capacity)
                remaining = remaining.dropFirst(row.count)
                for (k, item) in row.enumerated() {
                    let t = row.count == 1 ? 0 : (CGFloat(k) / CGFloat(row.count - 1) - 0.5)
                    let theta = angle + t * fanSpan * min(1, CGFloat(row.count) / CGFloat(capacity) + 0.25)
                    let position = CGPoint(x: groupPosition.x + cos(theta) * distance,
                                           y: groupPosition.y + sin(theta) * distance)
                    let id = "item:\(item.id)"
                    nodes.append(MapNode(id: id, kind: .item(item), groupID: group.id, colorIndex: index, position: position))
                    edges.append(MapEdge(from: group.id, to: id, colorIndex: index, isSecondary: false))
                }
                ring += 1
            }
        }

        // Cross-links: an item tagged with several visible topics also connects to the others.
        if grouping == .tags {
            let visibleGroups = Dictionary(uniqueKeysWithValues: groups.enumerated().compactMap { i, g in g.tag.map { ($0, (g.id, i)) } })
            for node in nodes {
                guard case .item(let item) = node.kind else { continue }
                for tag in item.tags {
                    guard let match = visibleGroups[tag], match.0 != node.groupID else { continue }
                    edges.append(MapEdge(from: match.0, to: node.id, colorIndex: match.1, isSecondary: true))
                }
            }
        }
        return (nodes, edges)
    }

    static let palette: [Color] = [.orange, .blue, .green, .pink, .purple, .teal, .red, .indigo, .mint, .brown, .cyan, .yellow]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

/// The home screen: your whole library as a zoomable, draggable mind map.
struct MindMapView: View {
    @Environment(Librarian.self) private var librarian
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @Query(sort: \Space.createdAt) private var spaces: [Space]

    @AppStorage("mindMap.grouping") private var grouping: MapGrouping = .tags
    @State private var expanded: Set<String> = []
    @State private var didSetInitialExpansion = false

    // Camera
    @State private var scale: CGFloat = 0.8
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var panDrag: CGSize = .zero

    // Manual node moves, saved per grouping so your arrangement sticks.
    @State private var offsets: [String: CGSize] = [:]
    @State private var dragging: (id: String, translation: CGSize)?

    @State private var noteSheet: MapGroup?
    @State private var showingNewNote = false
    @State private var highlight = ""

    var body: some View {
        let groups = MindMapLayout.groups(for: items, spaces: spaces, grouping: grouping)
        let layout = MindMapLayout.build(groups: groups, expanded: expanded, grouping: grouping)
        let positions = resolvedPositions(layout.nodes)
        let liveScale = scale * pinch

        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                // Background catches pans and zooms.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                ZStack {
                    Canvas { context, _ in
                        for edge in layout.edges {
                            guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                            let start = CGPoint(x: center.x + a.x, y: center.y + a.y)
                            let end = CGPoint(x: center.x + b.x, y: center.y + b.y)
                            var path = Path()
                            path.move(to: start)
                            path.addCurve(to: end,
                                          control1: CGPoint(x: (start.x + end.x) / 2, y: start.y),
                                          control2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
                            let color = edge.from == "root" ? Color.secondary : MindMapLayout.color(edge.colorIndex)
                            context.stroke(path, with: .color(color.opacity(edge.isSecondary ? 0.35 : 0.6)),
                                           style: StrokeStyle(lineWidth: edge.from == "root" ? 3 : (edge.isSecondary ? 1.2 : 2),
                                                              lineCap: .round, dash: edge.isSecondary ? [5, 5] : []))
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(layout.nodes) { node in
                        if let p = positions[node.id] {
                            // Gesture goes before .position, which would otherwise make it cover the whole map.
                            nodeView(node, groups: groups)
                                .opacity(matchesHighlight(node) ? 1 : 0.25)
                                .gesture(nodeDrag(node))
                                .position(x: center.x + p.x, y: center.y + p.y)
                        }
                    }
                }
                .scaleEffect(liveScale)
                .offset(x: pan.width + panDrag.width, y: pan.height + panDrag.height)
            }
            .clipped()
            .simultaneousGesture(zoomGesture)
            .overlay(alignment: .bottomTrailing) { zoomControls(positions: positions, size: geometry.size) }
            .overlay {
                if items.isEmpty { emptyState }
            }
            .onAppear {
                viewSize = geometry.size
                setInitialExpansion(groups)
                loadOffsets()
                fit(groups: groups)
            }
            .onChange(of: geometry.size) { _, size in viewSize = size }
            .onChange(of: grouping) { _, _ in
                didSetInitialExpansion = false
                setInitialExpansion(MindMapLayout.groups(for: items, spaces: spaces, grouping: grouping))
                loadOffsets()
            }
        }
        .background(.background)
        .navigationTitle("Mind Map")
        .navigationDestination(for: UUID.self) { id in
            if let item = items.first(where: { $0.id == id }) { ItemDetailView(item: item) }
        }
        .searchable(text: $highlight, prompt: "Highlight on the map")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Group by", selection: $grouping) {
                    ForEach(MapGrouping.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingNewNote = true } label: { Label("New Note", systemImage: "square.and.pencil") }
                    Divider()
                    Button("Expand All") { withAnimation(.spring) { expanded = Set(groups.map(\.id)) } }
                    Button("Collapse All") { withAnimation(.spring) { expanded = [] } }
                    Button("Reset Layout") { withAnimation(.spring) { offsets = [:]; saveOffsets() } }
                } label: {
                    Label("Map", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingNewNote) { NoteEditorSheet() }
        .sheet(item: $noteSheet) { group in
            NoteEditorSheet(space: group.space, tags: group.tag.map { [$0] } ?? [])
        }
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ node: MapNode, groups: [MapGroup]) -> some View {
        switch node.kind {
        case .root:
            VStack(spacing: 4) {
                Image(systemName: "brain.head.profile").font(.system(size: 30))
                Text("My Brain").font(.headline)
                Text("\(items.count) items").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, height: 130)
            .background(Circle().fill(Color.accentColor.opacity(0.18)))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .onTapGesture { withAnimation(.spring) { fit(groups: groups) } }

        case .group(let group):
            let color = MindMapLayout.color(node.colorIndex)
            let isOpen = expanded.contains(group.id)
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                Text(group.title).lineLimit(1)
                Text("\(group.items.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.25), in: Capsule())
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption)
            }
            .font(.headline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color, lineWidth: 2))
            .frame(maxWidth: 260)
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(duration: 0.35)) {
                    if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
            }
            .contextMenu {
                Button { noteSheet = group } label: { Label("New Note Here", systemImage: "square.and.pencil") }
                Button(isOpen ? "Collapse" : "Expand") {
                    withAnimation(.spring) { if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) } }
                }
            }

        case .item(let item):
            NavigationLink(value: item.id) {
                MapItemCard(item: item, color: MindMapLayout.color(node.colorIndex))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") { item.isFavorite.toggle() }
                Button("Organize with AI") { librarian.reorganize(item) }
                Divider()
                Button("Delete", role: .destructive) { librarian.delete(item) }
            }
        }
    }

    private func matchesHighlight(_ node: MapNode) -> Bool {
        let q = highlight.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        switch node.kind {
        case .root: return true
        case .group(let group): return group.title.lowercased().contains(q)
        case .item(let item):
            return item.displayTitle.lowercased().contains(q) || item.summary.lowercased().contains(q)
                || item.tags.contains { $0.contains(q) } || item.body.lowercased().contains(q)
        }
    }

    // MARK: Positions & dragging

    /// Layout position + the user's saved moves. Moving a group carries its items with it.
    private func resolvedPositions(_ nodes: [MapNode]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for node in nodes {
            var offset = offsets[node.id] ?? .zero
            if case .item = node.kind, let groupID = node.groupID {
                let groupOffset = offsets[groupID] ?? .zero
                offset.width += groupOffset.width
                offset.height += groupOffset.height
                if let d = dragging, d.id == groupID { offset.width += d.translation.width; offset.height += d.translation.height }
            }
            if let d = dragging, d.id == node.id { offset.width += d.translation.width; offset.height += d.translation.height }
            result[node.id] = CGPoint(x: node.position.x + offset.width, y: node.position.y + offset.height)
        }
        return result
    }

    private func nodeDrag(_ node: MapNode) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let s = max(scale, 0.1)
                dragging = (node.id, CGSize(width: value.translation.width / s, height: value.translation.height / s))
            }
            .onEnded { value in
                let s = max(scale, 0.1)
                var offset = offsets[node.id] ?? .zero
                offset.width += value.translation.width / s
                offset.height += value.translation.height / s
                offsets[node.id] = offset
                dragging = nil
                saveOffsets()
            }
    }

    private var offsetsKey: String { "mindMap.offsets.\(grouping.rawValue)" }

    private func loadOffsets() {
        guard let data = UserDefaults.standard.data(forKey: offsetsKey),
              let stored = try? JSONDecoder().decode([String: [CGFloat]].self, from: data)
        else { offsets = [:]; return }
        offsets = stored.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }

    private func saveOffsets() {
        let stored = offsets.mapValues { [$0.width, $0.height] }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: offsetsKey) }
    }

    private func setInitialExpansion(_ groups: [MapGroup]) {
        guard !didSetInitialExpansion else { return }
        didSetInitialExpansion = true
        // Small libraries open fully; big ones open the largest few branches.
        if items.count <= 60 {
            expanded = Set(groups.map(\.id))
        } else {
            expanded = Set(groups.sorted { $0.items.count > $1.items.count }.prefix(3).map(\.id))
        }
    }

    // MARK: Camera

    private var panGesture: some Gesture {
        DragGesture()
            .updating($panDrag) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in scale = clampScale(scale * value.magnification) }
    }

    private func clampScale(_ s: CGFloat) -> CGFloat { min(2.5, max(0.15, s)) }

    private func zoomControls(positions: [String: CGPoint], size: CGSize) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation(.spring) { scale = clampScale(scale * 1.25) } } label: {
                Image(systemName: "plus").frame(width: 36, height: 36)
            }
            Divider().frame(width: 36)
            Button { withAnimation(.spring) { scale = clampScale(scale / 1.25) } } label: {
                Image(systemName: "minus").frame(width: 36, height: 36)
            }
            Divider().frame(width: 36)
            Button { withAnimation(.spring) { fit(positions: positions, size: size) } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
        .font(.body.weight(.semibold))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    @State private var viewSize: CGSize = .zero

    private func fit(groups: [MapGroup]) {
        let layout = MindMapLayout.build(groups: groups, expanded: expanded, grouping: grouping)
        fit(positions: resolvedPositions(layout.nodes), size: viewSize == .zero ? CGSize(width: 900, height: 700) : viewSize)
    }

    /// Zooms and centers so every visible node is on screen.
    private func fit(positions: [String: CGPoint], size: CGSize) {
        viewSize = size
        guard !positions.isEmpty, size.width > 0, size.height > 0 else { return }
        let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
        let minX = xs.min()! - 110, maxX = xs.max()! + 110
        let minY = ys.min()! - 70, maxY = ys.max()! + 70
        let s = clampScale(min(size.width / (maxX - minX), size.height / (maxY - minY)) * 0.95)
        scale = s
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        pan = CGSize(width: -midX * s, height: -midY * s)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Your mind map grows as you save things").font(.title3.bold())
            Text("Add notes, links, photos or files. The on-device AI tags them, and each tag becomes a branch here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Button { showingNewNote = true } label: { Label("New Note", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .offset(y: 140)
    }
}

/// A leaf on the map.
struct MapItemCard: View {
    let item: Item
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            if let data = item.thumbnail, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).font(.caption.weight(.semibold)).lineLimit(2)
                if item.aiStatus == .processing || item.aiStatus == .pending {
                    Text("Organizing…").font(.caption2).foregroundStyle(.secondary)
                } else if let host = item.url?.host() {
                    Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
        }
        .padding(7)
        .frame(width: 150)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}
