import SwiftUI

struct ReplyDocumentView: View {
    let source: String
    let accessibilityLabel: String
    let accessibilityID: String

    private nonisolated struct Section: Sendable {
        let table: Int?
        var blocks: [ReplyMarkdown.Block]
    }

    @State private var renderedSource: String?
    @State private var sections: [Section] = []

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if renderedSource == source {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections.indices, id: \.self) { index in
                            let section = sections[index]
                            if section.table != nil {
                                ReplyTableView(blocks: section.blocks)
                            } else if let block = section.blocks.first {
                                render(block, after: index == 0 ? nil : sections[index - 1].blocks.last)
                            }
                        }
                    }
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("reply-start")
                }
            }
            .accessibilityIdentifier(accessibilityID)
            .accessibilityLabel(accessibilityLabel)
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      url.host != nil else { return .discarded }
                return .systemAction
            })
            .task(id: source) {
                let sections = await Self.documentSections(source)
                guard !Task.isCancelled else { return }
                self.sections = sections
                renderedSource = source
            }
            .onChange(of: renderedSource) {
                scroll.scrollTo("reply-start", anchor: .top)
            }
        }
    }

    @concurrent private static func documentSections(_ source: String) async -> [Section] {
        guard !Task.isCancelled else { return [] }
        var sections: [Section] = []
        for block in ReplyMarkdown(source, retainSourcePositions: false).blocks {
            guard !Task.isCancelled else { return [] }
            let table = block.path.first {
                if case .table = $0.kind { return true }
                return false
            }?.identity
            if let table, let last = sections.indices.last, sections[last].table == table {
                sections[last].blocks.append(block)
            } else {
                sections.append(Section(table: table, blocks: [block]))
            }
        }
        return sections
    }

    private func render(_ block: ReplyMarkdown.Block, after previous: ReplyMarkdown.Block?) -> some View {
        let list = block.path.filter {
            if case .listItem = $0.kind { return true }
            return false
        }
        let quoted = block.path.contains { $0.kind == .blockQuote }
        let startsItem = list.first.map { previous?.path.contains($0) != true } ?? false
        let ordered = block.path.first { $0.kind == .orderedList || $0.kind == .unorderedList }?.kind == .orderedList

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let item = list.first, case .listItem(let ordinal) = item.kind {
                Text(verbatim: startsItem ? (ordered ? "\(ordinal)." : "•") : "")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 17, alignment: .trailing)
            }
            blockContent(block)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(max(0, list.count - 1)) * 18)
        .padding(.leading, quoted ? 12 : 0)
        .overlay(alignment: .leading) {
            if quoted {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func blockContent(_ block: ReplyMarkdown.Block) -> some View {
        switch block.path.first?.kind {
        case .header(let level):
            Text(block.text)
                .font(.system(size: level == 1 ? 23 : (level == 2 ? 19 : 16), weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 3)
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(verbatim: language)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    let code = String(block.text.characters)
                    Text(verbatim: code.hasSuffix("\n") ? String(code.dropLast()) : code)
                        .font(.system(size: 13, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("reply-code")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.10), in: .rect(cornerRadius: 8))
        case .thematicBreak:
            Divider()
                .accessibilityHidden(true)
        default:
            Text(block.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
