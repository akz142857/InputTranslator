import AppKit
import SwiftUI

struct TranslationTabs<Selection: Equatable>: NSViewRepresentable {
    @Environment(\.layoutDirection) private var layoutDirection
    let selection: Selection
    let options: [(value: Selection, title: String)]
    let accessibilityID: String
    let accessibilityTitle: String
    let isEnabled: Bool
    let onSelect: (Selection) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let tabs = NSSegmentedControl(
            labels: options.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectTab(_:))
        )
        tabs.setAccessibilityIdentifier(accessibilityID)
        if #available(macOS 26, *) {
            tabs.controlSize = .large
            tabs.borderShape = .capsule
        }
        if #available(macOS 27, *) {
            tabs.role = .tabs
        }
        return tabs
    }

    func updateNSView(_ tabs: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = selectIndex
        for (index, option) in options.enumerated() where tabs.label(forSegment: index) != option.title {
            tabs.setLabel(option.title, forSegment: index)
        }
        tabs.userInterfaceLayoutDirection = layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        tabs.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        tabs.isEnabled = isEnabled
        tabs.setAccessibilityLabel(accessibilityTitle)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: selectIndex) }

    private func selectIndex(_ index: Int) {
        guard options.indices.contains(index) else { return }
        onSelect(options[index].value)
    }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }

        @objc func selectTab(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            Task { @MainActor in onSelect(index) }
        }
    }
}
