// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// One row of a `CheckboxTable`.
struct CheckboxTableRow: Equatable {
	let id: UUID
	let title: String
	let isOn: Bool
	var isEnabled = true
}

/// A single-column list of checkboxes, drawn by an `NSTableView`.
///
/// SwiftUI's `Table` hosts a SwiftUI `Toggle` in every cell, and scrolling it re-renders those
/// cells as they come into view, which drops frames. Here each cell is a plain `NSButton`
/// checkbox that AppKit reuses, so the list scrolls like any other AppKit table. It looks like
/// `Table` with `.inset(alternatesRowBackgrounds: true)`, no header and no selection.
struct CheckboxTable: NSViewRepresentable {
	var rows: [CheckboxTableRow]
	var onToggle: (UUID, Bool) -> Void

	@MainActor
	final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
		var rows: [CheckboxTableRow] = []
		var onToggle: (UUID, Bool) -> Void = { _, _ in }
		private static let cellIdentifier = NSUserInterfaceItemIdentifier("CheckboxCell")

		func numberOfRows(in tableView: NSTableView) -> Int {
			rows.count
		}

		func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
			let button: NSButton
			if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? NSButton {
				button = reused
			} else {
				button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
				button.identifier = Self.cellIdentifier
				button.lineBreakMode = .byTruncatingTail
			}
			configure(button, with: rows[row], at: row)
			return button
		}

		// Rows are never selected: a click on a row's checkbox toggles it, and a click elsewhere
		// in the row does nothing, as in the `Table` this replaces.
		func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
			false
		}

		func configure(_ button: NSButton, with row: CheckboxTableRow, at index: Int) {
			button.title = row.title
			button.state = row.isOn ? .on : .off
			button.isEnabled = row.isEnabled
			button.tag = index
		}

		@objc func toggled(_ sender: NSButton) {
			guard rows.indices.contains(sender.tag) else { return }
			onToggle(rows[sender.tag].id, sender.state == .on)
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSScrollView {
		let tableView = NSTableView()
		tableView.style = .inset
		tableView.usesAlternatingRowBackgroundColors = true
		tableView.headerView = nil
		tableView.allowsEmptySelection = true
		tableView.focusRingType = .none
		tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Checkbox"))
		column.resizingMask = .autoresizingMask
		tableView.addTableColumn(column)
		tableView.dataSource = context.coordinator
		tableView.delegate = context.coordinator

		let scrollView = NSScrollView()
		scrollView.documentView = tableView
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.drawsBackground = false
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		let coordinator = context.coordinator
		coordinator.onToggle = onToggle
		guard coordinator.rows != rows, let tableView = scrollView.documentView as? NSTableView else { return }
		let sameRows = coordinator.rows.map(\.id) == rows.map(\.id)
		coordinator.rows = rows
		if sameRows {
			// Only checkbox states changed: update the visible cells in place, which keeps the
			// scroll position and does not rebuild anything.
			let visible = tableView.rows(in: tableView.visibleRect)
			for index in visible.lowerBound ..< visible.upperBound {
				if let button = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSButton {
					coordinator.configure(button, with: rows[index], at: index)
				}
			}
		} else {
			tableView.reloadData()
		}
	}
}
