import Foundation

/// An action item extracted from a meeting summary's markdown checkboxes.
struct ActionItem: Identifiable, Equatable, Sendable, Codable {
    var id: UUID = UUID()
    var text: String
    var owner: String?
    var isChecked: Bool
    var lineNumber: Int

    /// A stable key for matching across re-parses: the checkbox text, lowercased.
    var key: String { text.lowercased().trimmingCharacters(in: .whitespaces) }
}

/// Parses `- [ ]` and `- [x]` markdown checkboxes from a summary string.
/// Extracts optional owner from "task — owner" or "task (owner)" patterns.
enum ActionItemParser {
    /// Extract all checkbox lines from markdown text.
    /// Supports both `- [ ]` (unchecked) and `- [x]` (checked) patterns,
    /// plus `- [X]` (uppercase checked).
    static func parse(_ markdown: String) -> [ActionItem] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        let pattern = #/^\s*[-*]\s*\[([ xX])\]\s*(.+)$/#
        var items: [ActionItem] = []
        for (index, line) in lines {
            let trimmed = String(line)
            do {
                guard let match = try pattern.wholeMatch(in: trimmed) else { continue }
                let checkChar = String(match.1)
                let isChecked = checkChar == "x" || checkChar == "X"
                let body = String(match.2).trimmingCharacters(in: .whitespaces)
                let (text, owner) = extractOwner(from: body)
                items.append(ActionItem(
                    text: text,
                    owner: owner,
                    isChecked: isChecked,
                    lineNumber: index))
            } catch {
                // A malformed regex match on a single line shouldn't drop the whole
                // document — log it and skip that line.
                NutolaConsoleLog.intelligence("action item parse skipped line \(index): \(error.localizedDescription)")
                continue
            }
        }
        return items
    }

    /// Parse only unchecked items (open action items).
    static func openItems(_ markdown: String) -> [ActionItem] {
        parse(markdown).filter { !$0.isChecked }
    }

    /// Count unchecked items without allocating the full array (for badges).
    static func openCount(_ markdown: String) -> Int {
        let pattern = #/^\s*[-*]\s*\[ \]\s*.+/#
        var count = 0
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false)
        where (try? pattern.wholeMatch(in: String(line))) != nil {
            count += 1
        }
        return count
    }

    /// Extract owner from patterns like "Task — Alice" or "Task (Alice)".
    /// Returns (cleaned text, owner name or nil).
    private static func extractOwner(from body: String) -> (String, String?) {
        // "Task — owner" (em dash, en dash, or hyphen)
        for dash in ["—", "–", " - ", " — "] {
            if let range = body.range(of: dash) {
                let task = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let owner = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !task.isEmpty && !owner.isEmpty {
                    return (task, owner)
                }
            }
        }
        // "Task (owner)"
        if let openParen = body.lastIndex(of: "("), let closeParen = body.lastIndex(of: ")"),
           openParen < closeParen {
            let task = body[..<openParen].trimmingCharacters(in: .whitespaces)
            let owner = body[body.index(after: openParen)..<closeParen].trimmingCharacters(in: .whitespaces)
            if !task.isEmpty && !owner.isEmpty {
                return (task, owner)
            }
        }
        return (body, nil)
    }
}
