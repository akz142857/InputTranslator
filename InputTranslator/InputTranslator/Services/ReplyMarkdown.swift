import Foundation

nonisolated struct ReplyMarkdown: Sendable {
    struct Block: Sendable {
        let text: AttributedString
        let path: [PresentationIntent.IntentType]
    }

    let source: String
    private let attributed: AttributedString

    init(_ source: String, retainSourcePositions: Bool = true) {
        self.source = source
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                               appliesSourcePositionAttributes: retainSourcePositions)
        let parsed = try? AttributedString(markdown: source, options: options)
        attributed = parsed.flatMap { $0.characters.isEmpty ? nil : $0 } ?? AttributedString(source)
    }

    var hasFormatting: Bool {
        attributed.runs.contains { run in
            run.link != nil || run.imageURL != nil || !styles(of: run).isEmpty
                || run.presentationIntent?.components.contains { $0.kind != .paragraph } == true
        }
    }

    var blocks: [Block] {
        let runs = attributed.runs
        guard let first = runs.first else { return [] }
        var blocks: [Block] = []
        var start = first.range.lowerBound
        var currentPath = first.presentationIntent?.components ?? []
        for run in runs.dropFirst() {
            let path = run.presentationIntent?.components ?? []
            if currentPath != path {
                let end = run.range.lowerBound
                blocks.append(Block(text: AttributedString(attributed[start..<end]), path: currentPath))
                start = end
                currentPath = path
            }
        }
        blocks.append(Block(text: AttributedString(attributed[start..<attributed.endIndex]), path: currentPath))
        return blocks
    }

    func translationRanges(in pair: TranslationPair) -> [Range<String.Index>] {
        attributed.runs.compactMap { run in
            let intent = run.inlinePresentationIntent ?? []
            let literal: InlinePresentationIntent = [.code, .inlineHTML, .blockHTML, .lineBreak, .softBreak]
            guard intent.isDisjoint(with: literal),
                  run.presentationIntent?.components.contains(where: {
                      if case .codeBlock = $0.kind { return true }
                      return false
                  }) != true,
                  let position = run.markdownSourcePosition,
                  let range = Range(position, in: source),
                  let start = source[range].firstIndex(where: { !$0.isWhitespace }),
                  let end = source[range].lastIndex(where: { !$0.isWhitespace }) else { return nil }
            let trimmed = start..<source.index(after: end)
            let text = source[trimmed]
            // An autolink's label is also its address.
            if let link = run.link, text == link.absoluteString || "mailto:" + text == link.absoluteString { return nil }
            guard ProtectedPrompt.hasTranslatableProse(text, in: pair) else { return nil }
            return trimmed
        }
    }

    func replacingProse(at ranges: [Range<String.Index>], with translations: [Int: String]) -> String {
        var result = ""
        var cursor = source.startIndex
        for (index, range) in ranges.enumerated() {
            guard range.lowerBound >= cursor, let translation = translations[index] else { continue }
            let prose = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prose.isEmpty else { continue }
            result += source[cursor..<range.lowerBound]
            // Each span stays inline. Escape characters that could create new Markdown syntax.
            for character in prose {
                if character.isNewline {
                    result.append(" ")
                } else {
                    if #"\`*_[]<>|~#"#.contains(character) { result.append("\\") }
                    result.append(character)
                }
            }
            cursor = range.upperBound
        }
        return result + source[cursor...]
    }

    private func styles(of run: AttributedString.Runs.Run) -> InlinePresentationIntent {
        (run.inlinePresentationIntent ?? []).intersection([.stronglyEmphasized, .emphasized, .code, .strikethrough])
    }
}
