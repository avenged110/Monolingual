// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// A search field that stays expanded, for a toolbar.
///
/// `.searchable(placement: .toolbar)` puts an `NSSearchToolbarItem` in the toolbar, which collapses
/// to a button whenever the field loses focus, and SwiftUI has no option to stop it. A plain
/// `NSSearchField` in an ordinary toolbar item behaves like the search fields of other apps.
struct ToolbarSearchField: NSViewRepresentable {
	@Binding var text: String
	var prompt: String
	/// Incremented to move the keyboard focus into the field.
	var focusRequest: Int

	final class Coordinator: NSObject, NSSearchFieldDelegate {
		var text: Binding<String>
		var lastFocusRequest = 0

		init(text: Binding<String>) {
			self.text = text
		}

		func controlTextDidChange(_ notification: Notification) {
			guard let field = notification.object as? NSSearchField else { return }
			text.wrappedValue = field.stringValue
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

	func makeNSView(context: Context) -> NSSearchField {
		let field = NSSearchField()
		field.placeholderString = prompt
		field.delegate = context.coordinator
		// The list narrows as the user types, not only on Return.
		field.sendsSearchStringImmediately = true
		field.sendsWholeSearchString = false
		return field
	}

	func updateNSView(_ field: NSSearchField, context: Context) {
		context.coordinator.text = $text
		if field.stringValue != text {
			field.stringValue = text
		}
		if focusRequest != context.coordinator.lastFocusRequest {
			context.coordinator.lastFocusRequest = focusRequest
			// The field may not be in a window yet on the first pass.
			Task { @MainActor in
				_ = unsafe field.window?.makeFirstResponder(field)
			}
		}
	}
}
