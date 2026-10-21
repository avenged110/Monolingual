// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Fixes a window at its content's size, after ATVQ Deployer's and CalShare's configurators.
///
/// `.windowResizability(.contentSize)` fixes the size but leaves the zoom button live, so this
/// clears the `.resizable` mask (AppKit then disables zoom itself), and keeps clearing it, since
/// SwiftUI puts it back whenever the content's size range changes. Full screen and tabbing are
/// turned off too. A `title`, if given, replaces the one SwiftUI picked, and is put back the same
/// way, since SwiftUI rewrites it as well.
///
/// Every change to the window waits for the next turn of the run loop. The probe is attached, and
/// SwiftUI sets the style mask, in the middle of the hosting view's layout pass, and changing the
/// style mask relayouts the window, which AppKit reports as layout recursion
/// ("It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out").
struct FixedWindowConfigurator: NSViewRepresentable {
	var title: String?

	final class Coordinator {
		var styleMaskObservation: NSKeyValueObservation?
		var titleObservation: NSKeyValueObservation?
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> WindowProbeView {
		let probe = WindowProbeView(frame: .zero)
		let coordinator = context.coordinator
		let title = title
		probe.onAttach = { window in
			DispatchQueue.main.async { Self.configure(window, coordinator, title: title) }
		}
		return probe
	}

	func updateNSView(_ nsView: WindowProbeView, context: Context) {
		guard let window = nsView.hostWindow else { return }
		let coordinator = context.coordinator
		let title = title
		DispatchQueue.main.async { Self.configure(window, coordinator, title: title) }
	}

	@MainActor
	private static func configure(_ window: NSWindow, _ coordinator: Coordinator, title: String?) {
		if coordinator.styleMaskObservation == nil {
			coordinator.styleMaskObservation = window.observe(\.styleMask) { [weak window] _, _ in
				DispatchQueue.main.async {
					guard let window, window.styleMask.contains(.resizable) else { return }
					window.styleMask.remove(.resizable)
				}
			}
		}
		if let title, coordinator.titleObservation == nil {
			coordinator.titleObservation = window.observe(\.title) { [weak window] _, _ in
				DispatchQueue.main.async {
					guard let window, window.title != title else { return }
					window.title = title
				}
			}
		}
		// Setting the mask relayouts the window even when nothing changes, so only when needed.
		if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
		window.collectionBehavior.remove(.fullScreenPrimary)
		window.collectionBehavior.insert(.fullScreenNone)
		window.tabbingMode = .disallowed
		if let title, window.title != title { window.title = title }
	}
}

/// Zero-size view whose only job is to report the moment it is attached to a window.
final class WindowProbeView: NSView {
	var onAttach: ((NSWindow) -> Void)?
	private(set) weak var hostWindow: NSWindow?

	override func viewWillMove(toWindow newWindow: NSWindow?) {
		super.viewWillMove(toWindow: newWindow)
		hostWindow = newWindow
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let hostWindow { onAttach?(hostWindow) }
	}
}
