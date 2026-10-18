import SwiftUI

/// What Loom is doing right now, as one colour: red while files are being added,
/// orange while the AI is working, green when everything is ready.
enum ActivityLevel {
    case adding, thinking, ready, unavailable

    var color: Color {
        switch self {
        case .adding: Theme.statusUploading
        case .thinking: Theme.statusBusy
        case .ready: Theme.statusReady
        case .unavailable: Theme.labelTertiary
        }
    }

    @MainActor
    static func current(_ librarian: Librarian, _ llm: LLMService) -> ActivityLevel {
        let activities = librarian.activities
        if activities.contains(where: \.stage.isAdding) { return .adding }
        let aiWorking = librarian.processingCount > 0
            || activities.contains { $0.stage == .queued || $0.stage == .summarizing }
        switch llm.state {
        case .downloading, .loading: return .thinking
        default: break
        }
        if aiWorking { return .thinking }
        if llm.isReady { return .ready }
        // Apple Intelligence still preparing counts as busy, not missing.
        if case .notReady = llm.appleAvailability, llm.preferAppleIntelligence { return .thinking }
        return .unavailable
    }
}

/// The status button on iPhone: just a coloured dot. Tap it to see each file's progress and cancel work.
struct ActivityDot: View {
    @Environment(Librarian.self) private var librarian
    @Environment(LLMService.self) private var llm
    var onOpen: (UUID) -> Void
    @State private var showingPanel = false

    var body: some View {
        let level = ActivityLevel.current(librarian, llm)
        Button { showingPanel = true } label: {
            Circle()
                .fill(level.color)
                .frame(width: 14, height: 14)
                .phaseAnimator([false, true], trigger: level) { dot, phase in
                    // A gentle pulse while something is happening.
                    dot.scaleEffect(level == .adding || level == .thinking ? (phase ? 1.25 : 0.9) : 1)
                } animation: { _ in .easeInOut(duration: 0.8) }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .floatingChrome(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ActivityPanel.headline(level, librarian))
        .popover(isPresented: $showingPanel, arrowEdge: .top) {
            ActivityPanel { id in
                showingPanel = false
                onOpen(id)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Every file being added or organized, with a mini progress bar and a cancel button each.
struct ActivityPanel: View {
    @Environment(Librarian.self) private var librarian
    @Environment(LLMService.self) private var llm
    var onOpen: (UUID) -> Void

    var body: some View {
        let level = ActivityLevel.current(librarian, llm)
        let activities = librarian.activities
        let working = activities.filter { !$0.stage.isFinished }.count
        let background = max(0, librarian.processingCount - working)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                Circle().fill(level.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    let headline = Self.headline(level, librarian)
                    Text(headline).font(.subheadline.weight(.semibold))
                    if headline != Self.gettingReady {
                        Text(modelLine).font(.caption).foregroundStyle(Theme.labelSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.label)
            .padding(Theme.Space.s12)

            if case .downloading(let p) = llm.state {
                ProgressView(value: p).tint(Theme.statusBusy)
                    .padding(.horizontal, Theme.Space.s12).padding(.bottom, Theme.Space.s8)
            }

            if !activities.isEmpty || background > 0 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(activities) { activity in
                            row(activity)
                        }
                        if background > 0 {
                            Label("Updating \(background) older \(background == 1 ? "item" : "items") in the background",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(Theme.labelSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Space.s12).padding(.vertical, Theme.Space.s8)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)

                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack {
                    if activities.contains(where: \.stage.isFinished) {
                        Button("Clear finished") { withAnimation { librarian.clearFinishedActivities() } }
                    }
                    Spacer()
                    if working > 0 || background > 0 {
                        Button("Cancel all", role: .destructive) { withAnimation { librarian.cancelAll() } }
                            .foregroundStyle(Theme.destructive)
                    }
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentInk)
                .padding(Theme.Space.s12)
            }
        }
        .frame(width: 320)
        .background(Theme.surface)
        .animation(.snappy, value: activities)
    }

    private func row(_ activity: Librarian.Activity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activity.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.label)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.badge + 2))
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title).font(.callout.weight(.medium)).foregroundStyle(Theme.label).lineLimit(1)
                ProgressView(value: activity.stage.progress)
                    .tint(color(for: activity.stage))
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
                Text(activity.stage.label)
                    .font(.caption)
                    .foregroundStyle(Theme.labelSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !activity.isPlaceholder { onOpen(activity.id) } }
            Spacer(minLength: 0)
            if !activity.stage.isFinished && !activity.isPlaceholder {
                Button { withAnimation { librarian.cancel(activity.id) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.labelTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel \(activity.title)")
            } else {
                switch activity.stage {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusReady)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarning)
                case .waitingForModel: Image(systemName: "pause.circle.fill").foregroundStyle(Theme.labelSecondary)
                default: ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func color(for stage: Librarian.Stage) -> Color {
        switch stage {
        case .copying, .reading: Theme.statusUploading
        case .queued, .summarizing, .waitingForModel: Theme.statusBusy
        case .done: Theme.statusReady
        case .failed: Theme.statusWarning
        }
    }

    private var modelLine: String {
        switch llm.state {
        case .downloading(let p): return "Downloading the AI model… \(Int(p * 100))%"
        case .loading: return "Loading the AI model…"
        default: return llm.isReady ? (llm.activeModelName ?? "AI ready") : AIAvailabilityNotice.message(for: llm)
        }
    }

    static let gettingReady = "AI is getting ready…"

    @MainActor
    static func headline(_ level: ActivityLevel, _ librarian: Librarian) -> String {
        let adding = librarian.activities.filter(\.stage.isAdding).count
        switch level {
        case .adding: return "Adding \(adding) \(adding == 1 ? "file" : "files")…"
        case .thinking:
            let n = max(librarian.processingCount, librarian.activities.filter { $0.stage == .queued || $0.stage == .summarizing }.count)
            return n > 0 ? "AI is organizing \(n) \(n == 1 ? "item" : "items")…" : gettingReady
        case .ready: return "All caught up"
        case .unavailable: return "No AI model"
        }
    }
}
