import Foundation

/// Last-used timestamps per snippet path. Usage is not part of the Markdown, which is an interchange
/// format a person edits, so it lives in its own file beside the library.
struct SnippetUsage: Sendable, Equatable {
    private var usedAt: [String: Date] = [:]

    func lastUsed(at path: String) -> Date? {
        usedAt[path]
    }

    /// Keeps the newest timestamp per path, so a reload cannot walk back a use recorded meanwhile.
    mutating func merge(_ other: SnippetUsage) {
        for (path, date) in other.usedAt {
            record(path: path, at: date)
        }
    }

    mutating func record(path: String, at date: Date) {
        if let existing = usedAt[path], existing >= date { return }
        usedAt[path] = date
    }

    /// An unreadable or absent file is an empty history rather than a failure: ordering is a nicety,
    /// and losing it must never stop a library loading.
    static func load(from fileURL: URL) -> SnippetUsage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? decoder.decode([String: Date].self, from: data)
        else { return SnippetUsage() }
        var usage = SnippetUsage()
        usage.usedAt = decoded
        return usage
    }

    func write(to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try encoder.encode(usedAt).write(to: fileURL, options: .atomic)
    }
}
