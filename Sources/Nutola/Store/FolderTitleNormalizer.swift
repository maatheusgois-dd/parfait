import Foundation

enum FolderTitleNormalizer {
    /// Trim, collapse internal whitespace, lowercase for comparison.
    /// Display title unchanged; only the key is normalized.
    static func key(for title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
