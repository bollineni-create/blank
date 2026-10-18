import SwiftUI
import SwiftData

/// Chat with your library. Answers come from the on-device model, grounded in your saved items.
struct AskView: View {
    /// A question typed into the main page's ask bar, sent as soon as the panel opens.
    @Binding var pendingQuestion: String?
    @Environment(LLMService.self) private var llm
    @Environment(\.modelContext) private var context
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]

    @State private var conversation: Conversation?
    @State private var input = ""
    @State private var streaming: String?
    @State private var streamingSources: [UUID] = []
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?
    @State private var openedSource: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s20) {
                        if messages.isEmpty && streaming == nil { intro }
                        ForEach(messages) { message in
                            MessageLine(isUser: message.isUser, text: message.text, sources: sources(message.sourceIDs))
                        }
                        if let streaming {
                            if streaming.isEmpty {
                                SpeakerLine(isUser: false, status: "Thinking…")
                            } else {
                                MessageLine(isUser: false, text: streaming, sources: sources(streamingSources))
                            }
                        }
                        if let errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(Theme.label)
                                .symbolRenderingMode(.multicolor)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(Theme.Space.s24)
                }
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == Citations.scheme, let id = UUID(uuidString: url.host() ?? "") else { return .systemAction }
                    openedSource = id
                    return .handled
                })
                .onChange(of: streaming) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            inputBar
        }
        .background(Theme.background)
        .navigationTitle(conversation?.title ?? "Ask")
        .navigationDestination(for: UUID.self) { id in
            if let item = items.first(where: { $0.id == id }) { ItemDetailView(item: item) }
        }
        .navigationDestination(item: $openedSource) { id in
            if let item = items.first(where: { $0.id == id }) { ItemDetailView(item: item) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { startNew() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    if !conversations.isEmpty {
                        Divider()
                        ForEach(conversations.prefix(20)) { c in
                            Button(c.title) { conversation = c }
                        }
                        Divider()
                        if let conversation {
                            Button("Delete This Chat", role: .destructive) {
                                context.delete(conversation)
                                self.conversation = nil
                            }
                        }
                    }
                } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            }
        }
        .onDisappear { task?.cancel() }
        .onAppear(perform: sendPending)
        .onChange(of: pendingQuestion) { _, _ in sendPending() }
    }

    private func sendPending() {
        guard let q = pendingQuestion, streaming == nil else { return }
        pendingQuestion = nil
        input = q
        send()
    }

    private var messages: [ChatMessage] { conversation?.sortedMessages ?? [] }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.accentInk)
            Text("Ask your library").font(.loomTitle).serifTracking().foregroundStyle(Theme.label)
            Text("Answers come from the model on this device, using your saved notes, links and files. Nothing leaves your \(deviceName).")
                .foregroundStyle(Theme.labelSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                ForEach(["What did I save about productivity?", "Summarize my notes from this week", "Which links mention SwiftUI?"], id: \.self) { s in
                    Button { input = s; send() } label: {
                        Text(s)
                            .font(.callout)
                            .foregroundStyle(Theme.label)
                            .padding(.horizontal, Theme.Space.s12).padding(.vertical, Theme.Space.s8)
                            .background(Theme.surfaceSunken, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!llm.isReady)
                }
            }
            if !llm.isReady { AIAvailabilityNotice() }
        }
        .padding(.top, Theme.Space.s8)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s8) {
            TextField("Ask anything about your stuff…", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s12)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 22))
            Group {
                if streaming != nil {
                    Button { task?.cancel() } label: { Image(systemName: "stop.circle.fill") }
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !llm.isReady)
                }
            }
            .font(.system(size: 30))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func sources(_ ids: [UUID]) -> [Item] {
        ids.compactMap { id in items.first { $0.id == id } }
    }

    private func startNew() {
        task?.cancel()
        conversation = nil
        streaming = nil
        errorText = nil
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, streaming == nil, llm.isReady else { return }
        input = ""
        errorText = nil

        let convo: Conversation
        if let conversation { convo = conversation } else {
            convo = Conversation(title: String(question.prefix(50)))
            context.insert(convo)
            conversation = convo
        }
        let history = convo.sortedMessages.suffix(4)
        let userMessage = ChatMessage(isUser: true, text: question)
        context.insert(userMessage)
        userMessage.conversation = convo

        // Retrieve the most relevant items (use the last question too, for follow-ups).
        let lastQuestion = history.last(where: \.isUser)?.text ?? ""
        var hits = SearchIndex.rank(items, query: question, limit: 6).map(\.item)
        if hits.count < 3, !lastQuestion.isEmpty {
            for extra in SearchIndex.rank(items, query: lastQuestion + " " + question, limit: 4).map(\.item) where !hits.contains(extra) {
                hits.append(extra)
            }
        }
        let sourceIDs = Array(hits.prefix(6).map(\.id))
        streamingSources = sourceIDs
        streaming = ""

        let prompt = Self.buildPrompt(question: question, sources: Array(hits.prefix(llm.usesAppleModel ? 4 : 6)),
                                      history: Array(history), perItem: Self.perItemBudget(llm))

        task = Task {
            var answer = ""
            do {
                answer = try await llm.generate(system: Self.systemPrompt, prompt: prompt, maxTokens: 700, temperature: 0.5) { partial in
                    streaming = partial
                }
            } catch is CancellationError {
                answer = (streaming ?? "") + " _(stopped)_"
            } catch {
                errorText = error.localizedDescription
                answer = streaming ?? ""
            }
            if !answer.isEmpty {
                let reply = ChatMessage(isUser: false, text: answer, sourceIDs: Self.citedSources(in: answer, from: sourceIDs))
                context.insert(reply)
                reply.conversation = convo
            }
            streaming = nil
            try? context.save()
        }
    }

    static let systemPrompt = """
    You are Loom, a private assistant that lives on the user's own device and helps them use their personal library \
    of saved notes, links, images and files. Answer using the numbered library items provided. Cite items inline \
    like [1] or [2]. If the items don't contain the answer, say so briefly, then help from general knowledge and \
    make clear that part isn't from their library. Be concise and use Markdown for lists.
    """

    /// Characters of each source item to include; Apple's model has a smaller context window.
    @MainActor
    static func perItemBudget(_ llm: LLMService) -> Int {
        if llm.usesAppleModel { return 700 }
        #if os(macOS)
        return 1800
        #else
        return 900
        #endif
    }

    static func buildPrompt(question: String, sources: [Item], history: [ChatMessage], perItem: Int) -> String {
        var out = ""
        if !sources.isEmpty {
            out += "LIBRARY ITEMS:\n"
            for (i, item) in sources.enumerated() {
                let date = item.createdAt.formatted(date: .abbreviated, time: .omitted)
                var text = item.summary.isEmpty ? "" : "Summary: \(item.summary)\n"
                if !item.takeaways.isEmpty { text += "Takeaways: " + item.takeaways.joined(separator: " | ") + "\n" }
                text += String(item.fullText.prefix(perItem))
                if !item.tags.isEmpty { text += "\nTags: \(item.tags.joined(separator: ", "))" }
                out += "[\(i + 1)] \(item.displayTitle) (\(item.kind.rawValue), saved \(date))\n\(text)\n\n"
            }
        } else {
            out += "LIBRARY ITEMS: none matched this question.\n\n"
        }
        if !history.isEmpty {
            out += "EARLIER IN THIS CHAT:\n"
            for m in history { out += (m.isUser ? "User: " : "Loom: ") + String(m.text.prefix(600)) + "\n" }
            out += "\n"
        }
        out += "QUESTION: \(question)"
        return out
    }

    /// Keeps the sources the answer actually cited; falls back to all retrieved ones.
    static func citedSources(in answer: String, from ids: [UUID]) -> [UUID] {
        let cited = ids.enumerated().filter { answer.contains("[\($0.offset + 1)]") }.map(\.element)
        return cited.isEmpty ? ids.prefix(3).map { $0 } : cited
    }

    private var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

/// "You" or "Loom" above each turn, in place of chat bubbles.
struct SpeakerLine: View {
    let isUser: Bool
    var status: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.s6) {
            if isUser {
                Text("You")
            } else {
                Image(systemName: "sparkles").foregroundStyle(Theme.accentInk)
                Text("Loom")
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(Theme.labelSecondary)
            }
        }
        .font(.headline)
        .foregroundStyle(Theme.label)
    }
}

/// One turn in Ask: the speaker line, then the text as prose with citations underlined inline.
struct MessageLine: View {
    let isUser: Bool
    let text: String
    let sources: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            SpeakerLine(isUser: isUser)
            Text(isUser ? Citations.markdown(text) : Citations.attributed(text, sourceIDs: sources.map(\.id)))
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(isUser ? Theme.labelSecondary : Theme.label)
                .textSelection(.enabled)
            if !isUser && !sources.isEmpty {
                FlowLayout(spacing: Theme.Space.s6) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.element.id) { i, item in
                        NavigationLink(value: item.id) {
                            HStack(spacing: Theme.Space.s4) {
                                Text("\(i + 1)").fontWeight(.bold).foregroundStyle(Theme.accentInk)
                                Image(systemName: item.kind.symbol).foregroundStyle(Theme.labelSecondary)
                                Text(item.displayTitle).foregroundStyle(Theme.label).lineLimit(1)
                            }
                            .font(.caption)
                            .padding(.horizontal, Theme.Space.s8).padding(.vertical, Theme.Space.s4)
                            .background(Theme.surfaceSunken, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Theme.Space.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Turns the model's inline `[1]` citations into underlined accent-ink links to the sources.
enum Citations {
    static let scheme = "loom-item"

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Citations link to `loom-item://<id>` when `sourceIDs` has a matching item.
    static func attributed(_ text: String, sourceIDs: [UUID]) -> AttributedString {
        style(markdown(text)) { n in sourceIDs.indices.contains(n - 1) ? URL(string: "\(scheme)://\(sourceIDs[n - 1])") : nil }
    }

    /// For places without navigation (Siri snippets): underlined, unlinked.
    static func unlinked(_ text: String) -> AttributedString {
        style(markdown(text)) { _ in nil }
    }

    /// The answer without citation markers, for speaking aloud.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s?\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
    }

    private static func style(_ input: AttributedString, link: (Int) -> URL?) -> AttributedString {
        var result = input
        let characters = String(result.characters)
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return result }
        let matches = regex.matches(in: characters, range: NSRange(characters.startIndex..., in: characters))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: characters), let digits = Range(match.range(at: 1), in: characters),
                  let n = Int(characters[digits]) else { continue }
            let lower = characters.distance(from: characters.startIndex, to: whole.lowerBound)
            let upper = characters.distance(from: characters.startIndex, to: whole.upperBound)
            let start = result.index(result.startIndex, offsetByCharacters: lower)
            let end = result.index(result.startIndex, offsetByCharacters: upper)
            var cite = AttributedString(String(n))
            cite.foregroundColor = Theme.accentInk
            cite.underlineStyle = .single
            if let url = link(n) { cite.link = url }
            result.replaceSubrange(start..<end, with: cite)
        }
        return result
    }
}

/// One calm line and one action when no model can answer yet.
struct AIAvailabilityNotice: View {
    var showsAction = true
    @Environment(LLMService.self) private var llm

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s12) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accentInk)
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text(Self.message(for: llm)).font(.callout).foregroundStyle(Theme.label)
                if showsAction, llm.appleAvailability != .notReady {
                    Button("Choose a model") {
                        NotificationCenter.default.post(name: .loomOpenSettings, object: nil)
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accentInk)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile(RoundedRectangle(cornerRadius: Theme.Radius.panel))
    }

    @MainActor
    static func message(for llm: LLMService) -> String {
        switch llm.state {
        case .downloading: return "Your model is downloading…"
        case .loading: return "Loading your model…"
        case .failed: return "Your model couldn't load. Choose another in Settings."
        default: break
        }
        switch llm.appleAvailability {
        case .notEnabled:
            return "Apple Intelligence is off. Turn it on in Settings, or download a Loom model."
        case .deviceNotEligible:
            return "This device can't run Apple Intelligence. Loom will use a downloaded model instead."
        case .notReady:
            return "The model is getting ready…"
        case .available where !llm.preferAppleIntelligence:
            return "Apple Intelligence is turned off for Loom. Turn it back on, or download a Loom model."
        default:
            return "Download a Loom model to start. After that, nothing leaves your device."
        }
    }
}
