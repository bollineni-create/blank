import SwiftUI
import UniformTypeIdentifiers

/// The "Save to Loom" sheet shown from the system Share menu.
struct ShareView: View {
    let extensionItems: [NSExtensionItem]
    let onDone: () -> Void
    let onCancel: () -> Void

    /// Something found in what was shared, ready to save.
    struct Shared: Identifiable {
        let id = UUID()
        var entry: ShareInbox.Entry
        var label: String
        var symbol: String
    }

    @State private var shared: [Shared] = []
    @State private var comment = ""
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Text("Save to Loom").font(.headline)
                Spacer()
                Button("Save", action: save)
                    .bold()
                    .disabled(loading || shared.isEmpty)
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading what you shared…").foregroundStyle(.secondary)
                }
            } else if shared.isEmpty {
                Text(errorText ?? "Loom couldn't find anything it can save here.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shared.prefix(6)) { item in
                        Label {
                            Text(item.label).lineLimit(2)
                        } icon: {
                            Image(systemName: item.symbol).foregroundStyle(Color.accentColor)
                        }
                    }
                    if shared.count > 6 {
                        Text("+ \(shared.count - 6) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            TextField("Add a note (optional)", text: $comment, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            Text("Loom reads and summarizes it on your device next time it's open.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(18)
        .task { await load() }
    }

    // MARK: Reading the shared items

    private func load() async {
        var found: [Shared] = []
        var seenURLs = Set<String>()
        let providers = extensionItems.flatMap { $0.attachments ?? [] }

        for provider in providers {
            // Files first (photos, videos, PDFs, documents), then web links, then plain text.
            if let type = [UTType.movie, .image, .pdf].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
               !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let name = await stageRepresentation(of: provider, as: type) {
                let symbol = type == .movie ? "video" : (type == .pdf ? "doc.richtext" : "photo")
                found.append(Shared(entry: .init(kind: .file, fileName: name), label: displayName(name), symbol: symbol))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                      let url = await loadURL(provider, type: .fileURL),
                      let name = try? ShareInbox.stageFile(at: url) {
                found.append(Shared(entry: .init(kind: .file, fileName: name), label: displayName(name), symbol: "doc"))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadURL(provider, type: .url), !url.isFileURL {
                guard seenURLs.insert(url.absoluteString).inserted else { continue }
                found.append(Shared(entry: .init(kind: .link, url: url.absoluteString), label: url.host() ?? url.absoluteString, symbol: "link"))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await loadText(provider) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seenURLs.contains(trimmed) else { continue }
                if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
                    guard seenURLs.insert(trimmed).inserted else { continue }
                    found.append(Shared(entry: .init(kind: .link, url: trimmed), label: url.host() ?? trimmed, symbol: "link"))
                } else {
                    found.append(Shared(entry: .init(kind: .text, text: trimmed), label: String(trimmed.prefix(120)), symbol: "note.text"))
                }
            }
        }
        shared = found
        loading = false
    }

    /// Copies a file-backed item (e.g. a photo or video from Photos) into the inbox before the
    /// system deletes its temporary copy.
    private func stageRepresentation(of provider: NSItemProvider, as type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? ShareInbox.stageFile(at: $0) })
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { return nil }
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) else { return nil }
        if let text = item as? String { return text }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func displayName(_ stagedName: String) -> String {
        (stagedName as NSString).lastPathComponent
    }

    // MARK: Actions

    private func save() {
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            for item in shared {
                var entry = item.entry
                entry.comment = note
                try ShareInbox.add(entry)
            }
            ShareInbox.notifyApp()
            onDone()
        } catch {
            errorText = "Couldn't save: \(error.localizedDescription)"
            shared = []
        }
    }

    private func cancel() {
        for item in shared { if let name = item.entry.fileName { ShareInbox.discardStagedFile(name) } }
        onCancel()
    }
}
