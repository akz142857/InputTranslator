import SwiftUI

struct ReplyTableView: View {
    let columns: [PresentationIntent.TableColumn]
    let rows: [[AttributedString]]

    init(blocks: [ReplyMarkdown.Block]) {
        columns = blocks.first?.path.compactMap { part -> [PresentationIntent.TableColumn]? in
            if case .table(let columns) = part.kind { return columns }
            return nil
        }.first ?? []
        let emptyRow = Array(repeating: AttributedString(), count: columns.count)
        var rows: [[AttributedString]] = []
        for block in blocks {
            guard case .tableCell(let column) = block.path.first?.kind, columns.indices.contains(column),
                  let row = block.path.lazy.compactMap({ part -> Int? in
                      switch part.kind {
                      case .tableHeaderRow: 0
                      case .tableRow(let index): index
                      default: nil
                      }
                  }).first else { continue }
            while rows.count <= row { rows.append(emptyRow) }
            var text = block.text
            // The surrounding view lays out the table. Keep inline formatting, without
            // asking Text to lay out the Markdown table's block-level intents again.
            text.presentationIntent = nil
            if !rows[row][column].characters.isEmpty { rows[row][column] += AttributedString("\n\n") }
            rows[row][column] += text
        }
        self.rows = rows
    }

    var body: some View {
        ScrollView(.horizontal) {
            content
        }
        .accessibilityIdentifier("reply-table")
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        cell(at: row, column: column)
                    }
                }
                .background(.secondary.opacity(row == 0 ? 0.16 : (row.isMultiple(of: 2) ? 0.08 : 0.04)))
            }
        }
        .clipShape(.rect(cornerRadius: 8))
    }

    private func cell(at row: Int, column: Int) -> some View {
        let alignment: Alignment = switch columns[column].alignment {
        case .center: .top
        case .right: .topTrailing
        default: .topLeading
        }
        let textAlignment: TextAlignment = switch columns[column].alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
        return Text(rows[row][column])
            .font(.system(size: 13, weight: row == 0 ? .semibold : .regular))
            .multilineTextAlignment(textAlignment)
            // A horizontal ScrollView proposes unlimited width. Fix the column width
            // before measuring its wrapped height, then let the tallest cell size its row.
            .frame(width: 260, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }
}
