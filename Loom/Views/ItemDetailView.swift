import SwiftUI
import SwiftData
import QuickLook

struct ItemDetailView: View {
    @Bindable var item: Item
    @Environment(Librarian.self) private var librarian
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query(sort: \Space.createdAt) private var spaces: [Space]

    @State private var newTag = ""
    @State private var showExtracted = false
    @State private var previewURL: URL?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $item.title, axis: .vertical)
                    .font(.title2.bold())
                    .onSubmit { librarian.itemEdited(item) }
                if let url = item.url {
                    Button { openURL(url) } label: {
                        Label(url.absoluteString, systemImage: "safari").lineLimit(1)
                    }
                }
                if let data = item.thumbnail, let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { previewURL = item.attachmentURL }
                }
                if let fileURL = item.attachmentURL, item.kind != .image {
                    Button { previewURL = fileURL } label: { Label("Open \(item.kind == .pdf ? "PDF" : "File")", systemImage: "eye") }
                }
            }

            Section(item.kind == .note ? "Note" : "Your notes") {
                TextEditor(text: $item.body)
                    .frame(minHeight: item.kind == .note ? 240 : 90)
                    .font(.body)
            }

            Section {
                if item.summary.isEmpty {
                    Text(statusText).foregroundStyle(.secondary)
                } else {
                    Text(item.summary).textSelection(.enabled)
                }
                Button { librarian.reorganize(item) } label: {
                    Label(item.summary.isEmpty ? "Organize with AI" : "Regenerate", systemImage: "sparkles")
                }
                .disabled(item.aiStatus == .processing)
            } header: {
                Text("AI summary")
            }

            Section("Tags") {
                if !item.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(item.tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text("#\(tag)")
                                Button { item.tags.removeAll { $0 == tag }; librarian.itemEdited(item) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
                TextField("Add tag", text: $newTag)
                    .onSubmit {
                        let tag = newTag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
                        if !tag.isEmpty, !item.tags.contains(tag) { item.tags.append(tag); librarian.itemEdited(item) }
                        newTag = ""
                    }
            }

            Section {
                Picker("Space", selection: $item.space) {
                    Text("None").tag(Space?.none)
                    ForEach(spaces) { space in Text("\(space.emoji) \(space.name)").tag(Space?.some(space)) }
                }
                Toggle("Favorite", isOn: $item.isFavorite)
                LabeledContent("Saved", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            if !item.extractedText.isEmpty {
                Section {
                    DisclosureGroup("Extracted text (\(item.extractedText.count) characters)", isExpanded: $showExtracted) {
                        Text(item.extractedText.prefix(8000))
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.kind.label.dropLast().description)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let url = item.url ?? item.attachmentURL {
                ToolbarItem { ShareLink(item: url) }
            }
        }
        .quickLookPreview($previewURL)
        .onDisappear { librarian.itemEdited(item) }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                dismiss()
                librarian.delete(item)
            }
        }
    }

    private var statusText: String {
        switch item.aiStatus {
        case .pending: "Waiting for the on-device model…"
        case .processing: "Reading and organizing…"
        case .failed: "The model couldn't organize this item. Try again."
        case .skipped: "Auto-organize is off."
        case .done: "No summary."
        }
    }
}

/// Wraps tag chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct NoteEditorSheet: View {
    var space: Space?
    @Environment(Librarian.self) private var librarian
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (optional — AI can name it)", text: $title)
                TextEditor(text: $text).frame(minHeight: 260)
            }
            .formStyle(.grouped)
            .navigationTitle("New Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        librarian.addNote(text, title: title, space: space)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}

struct AddLinkSheet: View {
    var space: Space?
    @Environment(Librarian.self) private var librarian
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var comment = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://…", text: $urlText)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("Why are you saving this? (optional)", text: $comment, axis: .vertical)
            }
            .formStyle(.grouped)
            .navigationTitle("Save Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let url = normalizedURL { librarian.addLink(url, comment: comment, space: space) }
                        dismiss()
                    }
                    .disabled(normalizedURL == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 220)
        #endif
    }

    private var normalizedURL: URL? {
        var s = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }
}
