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
        if aiWorking { return .thinking }
        if llm.isReady { return .ready }
        // Apple Intelligence still preparing counts as busy, not missing.
        if case .notReady = llm.appleAvailability { return .thinking }
        return .unavailable
    }
}

/// The status button: a coloured dot, with a word or two beside it on the Mac. Tap it to see each file's
/// progress, cancel work, and retry or remove files that failed.
struct ActivityDot: View {
    @Environment(Librarian.self) private var librarian
    @Environment(LLMService.self) private var llm
    var onOpen: (UUID) -> Void
    @State private var showingPanel = false

    var body: some View {
        let level = ActivityLevel.current(librarian, llm)
        let headline = ActivityPanel.headline(level, librarian)
        Button { showingPanel = true } label: {
            HStack(spacing: Theme.Space.s8) {
                Circle()
                    .fill(level.color)
                    .frame(width: 14, height: 14)
                    .phaseAnimator([false, true], trigger: level) { dot, phase in
                        // A gentle pulse while something is happening.
                        dot.scaleEffect(level == .adding || level == .thinking ? (phase ? 1.25 : 0.9) : 1)
                    } animation: { _ in .easeInOut(duration: 0.8) }
                #if os(macOS)
                Text(label(level, headline: headline))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .fixedSize()
                #endif
            }
            .padding(.horizontal, Theme.Space.s12)
            .frame(minWidth: 44, minHeight: 44, maxHeight: 44)
            .contentShape(Theme.pillShape)
            .floatingChrome(Theme.pillShape)
        }
        .buttonStyle(.plain)
        .help(headline)
        .accessibilityLabel(headline)
        .popover(isPresented: $showingPanel, arrowEdge: .top) {
            ActivityPanel { id in
                showingPanel = false
                onOpen(id)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Beside the dot on the Mac: the model's name when all is quiet, otherwise what's happening.
    private func label(_ level: ActivityLevel, headline: String) -> String {
        let failed = librarian.activities.filter(\.stage.isFailed).count
        if level == .ready, failed > 0 { return "\(failed) \(failed == 1 ? "file needs" : "files need") attention" }
        if level == .ready { return llm.activeModelName ?? "Ready" }
        if level == .unavailable { return "No model" }
        return headline
    }
}

/// Every file being added or organized, with a mini progress bar and a cancel button each, and a line
/// for broken files with one button that cleans them all up.
struct ActivityPanel: View {
    @Environment(Librarian.self) private var librarian
    @Environment(LLMService.self) private var llm
    @Environment(SyncMonitor.self) private var sync
    var onOpen: (UUID) -> Void

    var body: some View {
        let level = ActivityLevel.current(librarian, llm)
        let activities = librarian.activities
        let working = activities.filter { !$0.stage.isFinished }.count
        let background = max(0, librarian.processingCount - working)
        let broken = librarian.brokenFiles(syncing: sync.hasCloudKit == true)
        let lastAdded = librarian.lastBatchFiles
        // Broken files that have no row in the list still need attention.
        let listed = Set(activities.map(\.id))
        let unlisted = broken.filter { !listed.contains($0.id) }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                Circle().fill(level.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    let headline = Self.headline(level, librarian, unlisted: unlisted)
                    Text(headline).font(.subheadline.weight(.semibold))
                    if headline != Self.gettingReady {
                        Text(modelLine).font(.caption).foregroundStyle(Theme.labelSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.label)
            .padding(Theme.Space.s12)

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
                        Button("Clear finished") { withAnimation(Theme.motion) { librarian.clearFinishedActivities() } }
                    }
                    Spacer()
                    if working > 0 || background > 0 {
                        Button("Cancel all", role: .destructive) { withAnimation(Theme.motion) { librarian.cancelAll() } }
                            .foregroundStyle(Theme.destructive)
                    }
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentInk)
                .padding(Theme.Space.s12)
            }

            if !broken.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: Theme.Space.s8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarning)
                    Text("\(broken.count) broken \(broken.count == 1 ? "file" : "files")")
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    CleanUpButton(files: broken)
                        .foregroundStyle(Theme.accentInk)
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .padding(Theme.Space.s12)
            }

            if !lastAdded.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: Theme.Space.s8) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Theme.labelSecondary)
                    Text("Last added: \(lastAdded.count) \(lastAdded.count == 1 ? "file" : "files")")
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    UndoAddButton(files: lastAdded)
                        .foregroundStyle(Theme.accentInk)
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .padding(Theme.Space.s12)
            }
        }
        .frame(width: 320)
        .background(Theme.surface)
        .animation(.snappy, value: activities)
        .animation(.snappy, value: broken)
        .animation(.snappy, value: lastAdded)
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
            if activity.stage.isFailed {
                // Try again, or let it go (and the item with it, if it made it into the library).
                Button { withAnimation(Theme.motion) { librarian.retry(activity.id) } } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Try again")
                .accessibilityLabel("Retry \(activity.title)")
                Button { withAnimation(Theme.motion) { librarian.discard(activity.id) } } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.destructive)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove \(activity.title)")
            } else if !activity.stage.isFinished && !activity.isPlaceholder {
                Button { withAnimation(Theme.motion) { librarian.cancel(activity.id) } } label: {
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
                case .alreadyAdded: Image(systemName: "doc.on.doc.fill").foregroundStyle(Theme.labelSecondary)
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
        case .done, .alreadyAdded: Theme.statusReady
        case .failed: Theme.statusWarning
        }
    }

    private var modelLine: String {
        llm.isReady ? (llm.activeModelName ?? "AI ready") : AIAvailabilityNotice.message(for: llm)
    }

    static let gettingReady = "AI is getting ready…"

    /// `unlisted` counts broken files that have no row in the list; the panel passes it, the dot leaves it out.
    @MainActor
    static func headline(_ level: ActivityLevel, _ librarian: Librarian, unlisted: Int = 0) -> String {
        let adding = librarian.activities.filter(\.stage.isAdding).count
        switch level {
        case .adding: return "Adding \(adding) \(adding == 1 ? "file" : "files")…"
        case .thinking:
            let n = max(librarian.processingCount, librarian.activities.filter { $0.stage == .queued || $0.stage == .summarizing }.count)
            return n > 0 ? "AI is organizing \(n) \(n == 1 ? "item" : "items")…" : gettingReady
        case .ready:
            let failed = librarian.activities.filter(\.stage.isFailed).count + unlisted
            return failed > 0 ? "\(failed) \(failed == 1 ? "file needs" : "files need") attention" : "All caught up"
        case .unavailable: return "No AI model"
        }
    }
}

/// One button that removes every broken file, after a dialog says what that covers. In the status panel and
/// in Settings. `files` is what `Librarian.brokenFiles` found, so what the dialog counts is what's removed.
struct CleanUpButton: View {
    @Environment(Librarian.self) private var librarian
    @Environment(SyncMonitor.self) private var sync
    var files: [Librarian.BrokenFile]
    var label = "Clean up…"
    @State private var confirming = false

    var body: some View {
        let count = files.count
        Button(label) { confirming = true }
            .disabled(files.isEmpty)
            .help("Remove every broken file")
            .confirmationDialog("Remove \(count) broken \(count == 1 ? "file" : "files")?",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove \(count) \(count == 1 ? "File" : "Files")", role: .destructive) {
                    withAnimation(Theme.motion) { librarian.cleanUp(files) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(message)
            }
    }

    private var message: String {
        let failed = files.filter { $0.reason == .copyFailed }.count
        let missing = files.filter { $0.reason == .fileMissing }.count
        let loose = files.filter { $0.reason == .loose }
        var parts: [String] = []
        if failed > 0 {
            parts.append("\(failed) couldn't be copied into your library")
        }
        if missing > 0 {
            parts.append("\(missing) \(missing == 1 ? "is" : "are") missing \(missing == 1 ? "its" : "their") file, on this device and in iCloud")
        }
        if !loose.isEmpty {
            parts.append("\(loose.count) \(loose.count == 1 ? "hangs" : "hang") off nothing on the map, with no tags and no space (\(Self.kinds(of: loose)))")
        }
        var text = parts.joined(separator: "; ") + ". "
        text += "Going: " + FileWords.names(files.map(\.title)) + ". "
        text += "They're taken out of the library and the status list."
        if missing > 0, sync.hasCloudKit == true {
            text += " A file that was saved on another device is removed there too. To keep it, open Settings on that device and tap Send everything on this device to iCloud first; its file then fills in here."
        }
        return text
    }

    private static func kinds(of files: [Librarian.BrokenFile]) -> String {
        FileWords.kinds(files.map { $0.kind ?? .file })
    }
}

/// One button that undoes the most recent batch of adds, after a dialog names what's going. In the status
/// panel and in Settings; the Mac's Edit menu opens the same dialog. `files` is what `Librarian.lastBatchFiles`
/// holds, so what the dialog counts is what's removed.
struct UndoAddButton: View {
    var files: [Librarian.AddedFile]
    var label = "Undo…"
    @State private var confirming = false

    var body: some View {
        Button(label) { confirming = true }
            .disabled(files.isEmpty)
            .help("Take the files added together most recently out of the library")
            .undoAddDialog(isPresented: $confirming)
    }
}

extension View {
    /// The confirmation that undoes the most recent batch of adds, over whatever presents it.
    func undoAddDialog(isPresented: Binding<Bool>) -> some View {
        modifier(UndoAddDialog(isPresented: isPresented))
    }
}

/// Names the last batch's files and, on Remove, takes them out. Reads the batch itself, so it says what undo
/// would do at the moment it opens, whichever view asked for it.
private struct UndoAddDialog: ViewModifier {
    @Environment(Librarian.self) private var librarian
    @Environment(SyncMonitor.self) private var sync
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        let files = librarian.lastBatchFiles
        let count = files.count
        content.confirmationDialog("Undo adding \(count) \(count == 1 ? "file" : "files")?",
                                   isPresented: $isPresented, titleVisibility: .visible) {
            Button("Remove \(count) \(count == 1 ? "File" : "Files")", role: .destructive) {
                withAnimation(Theme.motion) { librarian.undoLastBatch() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(message(files))
        }
    }

    private func message(_ files: [Librarian.AddedFile]) -> String {
        guard !files.isEmpty else { return "Nothing was added recently." }
        var text = "Added"
        if let started = librarian.lastBatch?.startedAt {
            text += " " + started.formatted(.relative(presentation: .named))
        }
        text += ": " + FileWords.names(files.map(\.title)) + " (" + FileWords.kinds(files.map(\.kind)) + "). "
        text += "They're taken out of the library and the status list, and any still being added are stopped."
        if let replaced = librarian.lastBatch?.replaced, replaced > 0 {
            text += " The \(replaced == 1 ? "file they replaced isn't" : "\(replaced) files they replaced aren't") brought back."
        }
        if sync.hasCloudKit == true {
            text += " A file that already reached your other devices is removed there too."
        }
        return text
    }
}

/// Words for lists of files in the dialogs that ask before removing them.
private enum FileWords {
    /// The first few names, then how many more.
    static func names(_ titles: [String]) -> String {
        let shown = titles.prefix(5).map { "“\($0)”" }
        let rest = titles.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    /// "3 images, 1 PDF and 2 files", most numerous first.
    static func kinds(_ kinds: [ItemKind]) -> String {
        var counts: [ItemKind: Int] = [:]
        for kind in kinds { counts[kind, default: 0] += 1 }
        let words = counts.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { kind, n -> String in
                let plural = kind == .pdf ? "PDFs" : kind.label.lowercased()
                let single = kind == .pdf ? "PDF" : String(kind.label.dropLast()).lowercased()
                return "\(n) \(n == 1 ? single : plural)"
            }
        if words.count <= 1 { return words.joined() }
        return words.dropLast().joined(separator: ", ") + " and " + words.last!
    }
}
