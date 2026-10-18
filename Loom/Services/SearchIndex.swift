import Foundation
import NaturalLanguage

/// Semantic search with Apple's built-in sentence embeddings (no download, fully offline),
/// mixed with plain keyword matching so exact words still win.
enum SearchIndex {
    private static let embedder = NLEmbedding.sentenceEmbedding(for: .english)

    /// Embeds the first part of a text. Returns nil if embeddings aren't available on this device.
    static func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedder else { return nil }
        // Sentence embeddings work best on short passages; average a few chunks.
        let chunks = chunk(trimmed, size: 600).prefix(6)
        var sum: [Double] = []
        var count = 0.0
        for c in chunks {
            guard let v = embedder.vector(for: c) else { continue }
            if sum.isEmpty { sum = v } else { for i in sum.indices { sum[i] += v[i] } }
            count += 1
        }
        guard count > 0 else { return nil }
        return normalize(sum.map { Float($0 / count) })
    }

    static func pack(_ vector: [Float]?) -> Data? {
        vector.map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
    }

    static func unpack(_ data: Data?) -> [Float]? {
        guard let data, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot // vectors are normalized
    }

    /// Ranks items for a query. Higher score is better.
    static func rank(_ items: [Item], query: String, limit: Int = 50) -> [(item: Item, score: Float)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let qVector = embed(q)
        let words = q.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }

        var results: [(Item, Float)] = []
        for item in items {
            let haystack = (item.fullText + " " + item.summary + " " + item.takeaways.joined(separator: " ") + " " + item.tags.joined(separator: " ")).lowercased()
            var keyword: Float = 0
            if haystack.contains(q.lowercased()) { keyword += 1 }
            if !words.isEmpty {
                let hits = words.filter { haystack.contains($0) }.count
                keyword += Float(hits) / Float(words.count)
            }
            if item.title.lowercased().contains(q.lowercased()) { keyword += 0.5 }
            if item.tags.contains(where: { $0.lowercased() == q.lowercased() }) { keyword += 0.5 }

            var semantic: Float = 0
            if let qVector, let v = unpack(item.embedding) { semantic = max(0, cosine(qVector, v)) }

            let score = keyword + semantic * 1.5
            if keyword > 0 || semantic > 0.35 { results.append((item, score)) }
        }
        return results.sorted { $0.1 > $1.1 }.prefix(limit).map { (item: $0.0, score: $0.1) }
    }

    static func chunk(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: .newlines) where !paragraph.isEmpty {
            if current.count + paragraph.count > size, !current.isEmpty {
                out.append(current)
                current = ""
            }
            if paragraph.count > size {
                var rest = Substring(paragraph)
                while !rest.isEmpty {
                    out.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
            } else {
                current += (current.isEmpty ? "" : "\n") + paragraph
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
