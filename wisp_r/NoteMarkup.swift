import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Translates between ``NoteBlock`` values and the marker-prefixed text the
/// editor works with.
///
/// A line looks like `\t\t• Buy milk`: leading tabs set the indent level and the
/// marker sets the list kind. Keeping the structure in the text itself is what
/// lets a single `TextEditor` offer Notes-style lists.
enum NoteMarkup {
    static let unchecked = "☐ "
    static let checked = "☑ "
    static let bullet = "• "
    static let indentUnit = "\t"
    static let maxIndent = 4

    // MARK: - Markers

    enum Marker: Equatable {
        case unchecked
        case checked
        case bullet
        case numbered(Int)

        var text: String {
            switch self {
            case .unchecked: NoteMarkup.unchecked
            case .checked: NoteMarkup.checked
            case .bullet: NoteMarkup.bullet
            case .numbered(let number): "\(number). "
            }
        }

        var blockKind: NoteBlock.Kind {
            switch self {
            case .unchecked: .checklist(isChecked: false)
            case .checked: .checklist(isChecked: true)
            case .bullet: .bullet
            case .numbered: .numbered
            }
        }
    }

    struct ParsedLine {
        var indent: Int
        var marker: Marker?
        /// Offset from the start of the line to where its text content begins.
        var contentOffset: Int

        var markerLength: Int { contentOffset - indent }
    }

    static func parseLine(_ line: String) -> ParsedLine {
        var rest = Substring(line)
        var indent = 0
        while rest.hasPrefix(indentUnit), indent < maxIndent {
            rest = rest.dropFirst()
            indent += 1
        }

        if rest.hasPrefix(unchecked) {
            return ParsedLine(indent: indent, marker: .unchecked, contentOffset: indent + unchecked.count)
        }
        if rest.hasPrefix(checked) {
            return ParsedLine(indent: indent, marker: .checked, contentOffset: indent + checked.count)
        }
        if rest.hasPrefix(bullet) {
            return ParsedLine(indent: indent, marker: .bullet, contentOffset: indent + bullet.count)
        }
        if let number = leadingNumber(in: rest) {
            return ParsedLine(indent: indent, marker: .numbered(number.value), contentOffset: indent + number.length)
        }
        return ParsedLine(indent: indent, marker: nil, contentOffset: indent)
    }

    /// Matches a `12. ` style prefix.
    private static func leadingNumber(in string: Substring) -> (value: Int, length: Int)? {
        let digits = string.prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        guard string.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (value, digits.count + 2)
    }

    // MARK: - Blocks to text

    static func text(from blocks: [NoteBlock]) -> AttributedString {
        let numbers = numbers(for: blocks)
        var result = AttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 { result += AttributedString("\n") }

            var prefix = String(repeating: indentUnit, count: block.indent)
            switch block.kind {
            case .paragraph:
                break
            case .checklist(let isChecked):
                prefix += isChecked ? checked : unchecked
            case .bullet:
                prefix += bullet
            case .numbered:
                prefix += "\(numbers[block.id] ?? 1). "
            }

            if !prefix.isEmpty { result += AttributedString(prefix) }
            result += block.text
        }

        return applyingEditorMarkerStyle(to: result)
    }

    /// Gives checklist glyphs the same footprint as the drawn mark on a day
    /// card while leaving the editable text at the shared body size.
    static func applyingEditorMarkerStyle(to value: AttributedString) -> AttributedString {
        var styled = value
        // Clear editor-only layout left over after changing a checklist back
        // into a paragraph. Rich character formatting remains untouched.
        styled[styled.startIndex..<styled.endIndex].lineHeight = nil

        let plainText = String(styled.characters)
        let native = NSMutableAttributedString(attributedString: NSAttributedString(styled))
        native.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: native.length))
        var lineStart = 0

        for line in plainText.split(separator: "\n", omittingEmptySubsequences: false) {
            let parsed = parseLine(String(line))
            if parsed.marker == .unchecked || parsed.marker == .checked {
                let start = plainText.index(plainText.startIndex, offsetBy: lineStart)
                let end = plainText.index(start, offsetBy: line.count)
                let range = NSRange(start..<end, in: plainText)
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = CGFloat(parsed.indent) * NoteTextMetrics.indentWidth
                    + NoteTextMetrics.editorChecklistAdvance
                paragraph.defaultTabInterval = NoteTextMetrics.indentWidth
                paragraph.paragraphSpacingBefore = NoteTextMetrics.checklistVerticalPadding
                paragraph.paragraphSpacing = NoteTextMetrics.checklistVerticalPadding
                native.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            lineStart += line.count + 1
        }

        styled = AttributedString(native)

        lineStart = 0
        for line in plainText.split(separator: "\n", omittingEmptySubsequences: false) {
            let parsed = parseLine(String(line))
            if parsed.marker == .unchecked || parsed.marker == .checked {
                let markerOffset = lineStart + parsed.indent
                let lower = styled.index(atCharacterOffset: markerOffset)
                let upper = styled.index(atCharacterOffset: markerOffset + 1)
                styled[lower..<upper].font = .system(
                    size: NoteTextMetrics.editorChecklistMarkSize
                        * AppSettings.shared.textSize(for: .note).scale
                )
            }
            lineStart += line.count + 1
        }

        return styled
    }

    // MARK: - Text to blocks

    static func blocks(from text: AttributedString) -> [NoteBlock] {
        lines(of: text).map { line in
            var line = line
            let parsed = parseLine(String(line.characters))

            if parsed.contentOffset > 0 {
                let contentStart = line.characters.index(line.startIndex, offsetBy: parsed.contentOffset)
                line.removeSubrange(line.startIndex..<contentStart)
            }

            return NoteBlock(
                text: line,
                kind: parsed.marker?.blockKind ?? .paragraph,
                indent: parsed.indent
            )
        }
    }

    /// Splits attributed text on newlines, keeping each line's formatting.
    static func lines(of text: AttributedString) -> [AttributedString] {
        var result: [AttributedString] = []
        var lineStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            if text.characters[index] == "\n" {
                result.append(AttributedString(text[lineStart..<index]))
                index = text.characters.index(after: index)
                lineStart = index
            } else {
                index = text.characters.index(after: index)
            }
        }
        result.append(AttributedString(text[lineStart..<text.endIndex]))

        return result
    }

    // MARK: - Numbering

    /// Display numbers for `.numbered` blocks. A run restarts after any other
    /// kind of line, and deeper levels restart when an outer level advances.
    static func numbers(for blocks: [NoteBlock]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var counters: [Int: Int] = [:]

        for block in blocks {
            guard case .numbered = block.kind else {
                counters.removeAll()
                continue
            }

            let next = (counters[block.indent] ?? 0) + 1
            counters[block.indent] = next
            for level in counters.keys where level > block.indent {
                counters[level] = nil
            }
            result[block.id] = next
        }

        return result
    }
}

// MARK: - Offset helpers

extension AttributedString {
    func index(atCharacterOffset offset: Int) -> AttributedString.Index {
        characters.index(startIndex, offsetBy: offset)
    }

    func characterOffset(of index: AttributedString.Index) -> Int {
        characters.distance(from: startIndex, to: index)
    }
}
