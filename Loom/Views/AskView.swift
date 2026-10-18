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
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty && streaming == nil { intro }
                        ForEach(messages) { message in
                            MessageBubble(isUser: message.isUser, text: message.text, sources: sources(message.sourceIDs))
                        }
                        if let streaming {
                            MessageBubble(isUser: false, text: streaming.isEmpty ? "…" : streaming, sources: sources(streamingSources))
                        }
                        if let errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: streaming) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider()
            inputBar
        }
        .navigationTitle(conversation?.title ?? "Ask")
        .navigationDestination(for: UUID.self) { id in
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
        VStack(alignment: .leading, spacing: 10) {
            Label("Ask your library", systemImage: "sparkles").font(.title2.bold())
            Text("Questions are answered by the model on this device using your saved notes, links and files. Nothing leaves your \(deviceName).")
                .foregroundStyle(.secondary)
            ForEach(["What did I save about productivity?", "Summarize my notes from this week", "Which links mention SwiftUI?"], id: \.self) { s in
                Button(s) { input = s; send() }.buttonStyle(.bordered)
            }
            if !llm.isReady {
                Text("Load a model in Settings → AI Model to start.").font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.vertical)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything about your stuff…", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
            if streaming != nil {
                Button { task?.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                    .buttonStyle(.plain)
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !llm.isReady)
            }
        }
        .padding(10)
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

        let prompt = Self.buildPrompt(question: question, sources: Array(hits.prefix(6)), history: Array(history))

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

    static func buildPrompt(question: String, sources: [Item], history: [ChatMessage]) -> String {
        #if os(macOS)
        let perItem = 1800
        #else
        let perItem = 900
        #endif
        var out = ""
        if !sources.isEmpty {
            out += "LIBRARY ITEMS:\n"
            for (i, item) in sources.enumerated() {
                let date = item.createdAt.formatted(date: .abbreviated, time: .omitted)
                var text = item.summary.isEmpty ? "" : "Summary: \(item.summary)\n"
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

struct MessageBubble: View {
    let isUser: Bool
    let text: String
    let sources: [Item]

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            Text(markdown)
                .textSelection(.enabled)
                .padding(12)
                .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 14))
            if !isUser && !sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { i, item in
                            NavigationLink(value: item.id) {
                                Label(item.displayTitle, systemImage: item.kind.symbol)
                                    .lineLimit(1)
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
