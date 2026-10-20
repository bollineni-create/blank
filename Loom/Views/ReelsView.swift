import SwiftUI
import SwiftData
import AVFoundation

/// Your saved videos as a feed: one fills the screen, swipe (or scroll, or press an arrow key) for the next,
/// in a fresh random order each time it opens. Each plays as it arrives and loops until you move on.
struct ReelsView: View {
    @Environment(Librarian.self) private var librarian
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Item> { $0.kindRaw == "video" && $0.attachmentName != nil },
           sort: \Item.createdAt, order: .reverse)
    private var videos: [Item]
    /// Called with an item to open it in the main page's detail panel.
    var onOpen: ((UUID) -> Void)? = nil

    /// The shuffled order, as item IDs; the videos themselves come from the query, so edits show up live.
    @State private var order: [UUID] = []
    @State private var current: UUID?
    @State private var paused = false
    @AppStorage("reelsMuted") private var muted = false
    @FocusState private var focused: Bool

    private var feed: [Item] {
        let byID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byID[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if feed.isEmpty {
                    ContentUnavailableView(
                        "No videos yet",
                        systemImage: "play.rectangle",
                        description: Text("Add videos to your brain and they show up here, in a random order.")
                    )
                    .foregroundStyle(.white)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(feed) { item in
                                ReelPage(
                                    item: item,
                                    isCurrent: item.id == current,
                                    paused: $paused,
                                    muted: $muted,
                                    onOpen: openAction(for: item.id)
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $current)
                }

                VStack {
                    HStack(spacing: Theme.Space.s8) {
                        Button { dismiss() } label: { chrome("xmark") }
                            .keyboardShortcut(.escape, modifiers: [])
                            .help("Close")
                        Spacer()
                        if !feed.isEmpty, let index = feed.firstIndex(where: { $0.id == current }) {
                            Text("\(index + 1) / \(feed.count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.black.opacity(0.35), in: Capsule())
                        }
                        Spacer()
                        Button { muted.toggle() } label: { chrome(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                            .keyboardShortcut("m", modifiers: [])
                            .help(muted ? "Unmute" : "Mute")
                        Button { reshuffle() } label: { chrome("shuffle") }
                            .keyboardShortcut("s", modifiers: [])
                            .help("Shuffle again")
                    }
                    .padding(Theme.Space.s16)
                    Spacer()
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            if order.isEmpty { reshuffle() }
            focused = true
        }
        // A video added while the feed is open joins it; a deleted one leaves it.
        .onChange(of: videos.map(\.id)) { _, ids in
            let known = Set(order)
            let have = Set(ids)
            order.removeAll { !have.contains($0) }
            order.append(contentsOf: ids.filter { !known.contains($0) }.shuffled())
            if let current, !have.contains(current) { self.current = order.first }
        }
        .onChange(of: current) { _, _ in paused = false }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.space) { paused.toggle(); return .handled }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 640)
        #endif
    }

    private func chrome(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.35), in: Circle())
            .contentShape(Circle())
    }

    /// Opens the item in the main page's panel and closes the feed; nil when the feed has nowhere to open it.
    private func openAction(for id: UUID) -> (() -> Void)? {
        guard let onOpen else { return nil }
        return { onOpen(id); dismiss() }
    }

    private func reshuffle() {
        order = videos.map(\.id).shuffled()
        withAnimation(Theme.motion) { current = order.first }
    }

    private func step(_ delta: Int) {
        guard !order.isEmpty else { return }
        let index = current.flatMap { order.firstIndex(of: $0) } ?? 0
        let next = min(max(index + delta, 0), order.count - 1)
        withAnimation(Theme.motion) { current = order[next] }
    }
}

/// One screen of the feed: the video, its title, summary and tags, and a few actions.
private struct ReelPage: View {
    @Bindable var item: Item
    var isCurrent: Bool
    @Binding var paused: Bool
    @Binding var muted: Bool
    var onOpen: (() -> Void)?
    @Environment(Librarian.self) private var librarian

    @State private var player: AVPlayer?
    @State private var loop: NSObjectProtocol?
    @State private var progress: Double = 0
    @State private var timeObserver: Any?
    @State private var heartPulse = false
    @State private var showMore = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            } else if let data = item.thumbnail, let image = PlatformImage(data: data) {
                Image(platformImage: image).resizable().scaledToFit()
            }

            // Tap to pause or resume; double-tap to favorite, like the apps this borrows from.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { favorite() }
                .onTapGesture { paused.toggle() }

            if paused && isCurrent {
                Image(systemName: "pause.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(radius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if heartPulse {
                Image(systemName: "heart.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Theme.favorite)
                    .shadow(radius: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // The caption and the action rail, over a gradient so white text stays readable.
            HStack(alignment: .bottom, spacing: Theme.Space.s12) {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text(item.displayTitle)
                        .font(.loomTitle3)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(showMore ? nil : 2)
                            .onTapGesture { withAnimation(Theme.motion) { showMore.toggle() } }
                    }
                    if !item.tags.isEmpty {
                        Text(item.tags.prefix(5).map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .shadow(color: .black.opacity(0.5), radius: 4)

                VStack(spacing: Theme.Space.s20) {
                    railButton(item.isFavorite ? "heart.fill" : "heart",
                               tint: item.isFavorite ? Theme.favorite : .white,
                               label: "Favorite") { favorite() }
                    if let onOpen {
                        railButton("info.circle", label: "Details", action: onOpen)
                    }
                    if let url = item.attachmentURL {
                        ShareLink(item: url) {
                            railIcon("square.and.arrow.up", tint: .white, label: "Share")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s20)
            .padding(.bottom, Theme.Space.s32)
            .padding(.top, 120)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )

            // How far through the video we are: a thin line along the bottom edge.
            GeometryReader { geo in
                Rectangle().fill(.white.opacity(0.9))
                    .frame(width: geo.size.width * progress, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.2))
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
        .background(Color.black)
        .onAppear { load() }
        .onDisappear { unload() }
        .onChange(of: isCurrent) { _, now in sync(playing: now && !paused) }
        .onChange(of: paused) { _, p in sync(playing: isCurrent && !p) }
        .onChange(of: muted) { _, m in player?.isMuted = m }
    }

    private func railButton(_ symbol: String, tint: Color = .white, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { railIcon(symbol, tint: tint, label: label) }
            .buttonStyle(.plain)
            .help(label)
    }

    private func railIcon(_ symbol: String, tint: Color, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.3), in: Circle())
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private func favorite() {
        item.isFavorite.toggle()
        librarian.itemEdited(item)
        if item.isFavorite {
            withAnimation(.spring(duration: 0.35)) { heartPulse = true }
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.25)) { heartPulse = false }
            }
        }
    }

    // MARK: Playback

    private func load() {
        guard player == nil, let url = item.attachmentURL else { return }
        let p = AVPlayer(url: url)
        p.isMuted = muted
        p.actionAtItemEnd = .none
        loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                      object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero)
            p.play()
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                 queue: .main) { time in
            guard let duration = p.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
            progress = min(max(time.seconds / duration, 0), 1)
        }
        player = p
        sync(playing: isCurrent && !paused)
    }

    private func unload() {
        if let loop { NotificationCenter.default.removeObserver(loop) }
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        loop = nil
        timeObserver = nil
        player?.pause()
        player = nil
        progress = 0
    }

    private func sync(playing: Bool) {
        guard let player else { return }
        if playing {
            if let current = player.currentItem, current.duration.isNumeric,
               current.currentTime() >= current.duration {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
            // Leaving a video rewinds it, so coming back starts it over, as reels do.
            if !isCurrent { player.seek(to: .zero) }
        }
    }
}

/// A bare `AVPlayerLayer`, with no transport controls: the feed draws its own.
#if os(macOS)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

private final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#else
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
