import AppKit
import SwiftUI
import XCTest
@testable import InputTranslator

final class ReplyTableTests: XCTestCase {
    private func table(_ source: String) -> ReplyTableView {
        ReplyTableView(blocks: ReplyMarkdown(source, retainSourcePositions: false).blocks)
    }

    @MainActor func testTableKeepsAllRowsAndInlineFormattingWithoutNestedTableIntents() {
        let source = """
        | Requirement | State | Count |
        | :--- | :---: | ---: |
        | Use `task_result_query` | **Missing** | 1 |
        | Check details | Partial | 2 |
        | Separate quota | Missing | 3 |
        | User limit | Partial | 4 |
        | Cancellation | Ready | 5 |
        | Native acceptance | Pending | 6 |
        """
        let rendered = table(source)
        XCTAssertEqual(rendered.columns.count, 3)
        XCTAssertEqual(rendered.rows.count, 7)
        XCTAssertEqual(rendered.columns[1].alignment, .center)
        XCTAssertEqual(rendered.columns[2].alignment, .right)
        XCTAssertEqual(String(rendered.rows[6][0].characters), "Native acceptance")
        XCTAssertTrue(rendered.rows[1][0].runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(rendered.rows[1][1].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rendered.rows.flatMap { $0 }.allSatisfy { cell in
            cell.runs.allSatisfy { $0.presentationIntent == nil }
        })
    }

    private func longTable() -> ReplyTableView {
        let longChinese = String(repeating: "读取所有分页并核对详情；未确认的消息应保留在覆盖范围摘要中，不能当作完整结果。", count: 6)
        let longEnglish = String(repeating: "Read every page and verify message details before marking coverage complete. ", count: 7)
        return table("""
        | 要求 / Requirement | 状态 / State |
        | --- | --- |
        | 后续问题使用 `task_result_query` | 未实现，沿用结果消息。 |
        | 读取前过滤空会话 | \(longEnglish) |
        | **完整覆盖**需要核对详情 | **存在差距。** \(longChinese) `ObjectFiltered` |
        | 使用单独的模型配额 | \(longChinese) |
        | 每个用户的调用限制 | \(longEnglish) |
        | 原生验收和取消 | 最后一行必须完整可见。 |
        """)
    }

    @MainActor private func host<Content: View>(_ content: Content) -> NSHostingView<some View> {
        NSHostingView(rootView: content
            .font(.system(size: 15))
            .lineSpacing(4)
            .textSelection(.enabled)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor)))
    }

    @MainActor func testLongTableRowsExpandAndHorizontalScrollPreservesTheirHeight() throws {
        let rendered = longTable()
        let full = host(rendered.content)
        let expected = full.fittingSize
        XCTAssertEqual(expected.width, 584, accuracy: 1)
        XCTAssertGreaterThan(expected.height, 650, "Long paragraphs must increase row heights, rather than draw over the next row")
        for width in [340.0, 800.0] {
            let viewport = host(rendered.frame(width: width))
            let actual = viewport.fittingSize
            XCTAssertEqual(actual.width, width + 24, accuracy: 1)
            XCTAssertGreaterThanOrEqual(actual.height, expected.height - 1,
                                       "Horizontal scrolling must not collapse the wrapped row heights")
        }
        full.frame = NSRect(origin: .zero, size: expected)
        full.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(full.bitmapImageRepForCachingDisplay(in: full.bounds))
        full.cacheDisplay(in: full.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "long-reply-table"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("inputtranslator-long-reply-table.png")
        try png.write(to: path)
        print("Table render snapshot: \(path.path)")
    }

    @MainActor func testAdditionalRowsReserveSpaceBelowLongWrappedCells() {
        let longText = String(repeating: "长内容需要完整换行，后续行不能与前一行重叠。", count: 20)
        let source = "| A | B |\n| --- | --- |\n| 第一项 | \(longText) |"
        let firstHeight = host(table(source).content).fittingSize.height
        let extendedHeight = host(table(source + "\n| 最后一项 | Final row |\n").content).fittingSize.height
        XCTAssertGreaterThan(firstHeight, 200)
        XCTAssertGreaterThanOrEqual(extendedHeight - firstHeight, 25)
    }
}
