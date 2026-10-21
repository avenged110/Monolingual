// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The shared NSOpenPanel helper, taken from Film Tracker's GlobalUtilities.swift. One addition:
// `treatsFilePackagesAsDirectories`, defaulting to Film Tracker's behavior (off).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SharedOpenPanel
// Generic, reusable NSOpenPanel() helper.
@MainActor
struct OpenPanelConfiguration {
	var canChooseFiles: Bool = true
	var canChooseDirectories: Bool = false
	var allowsMultipleSelection: Bool = false
	var allowedContentTypes: [UTType] = []
	/// Lets the user open packages such as app bundles and pick something inside them.
	var treatsFilePackagesAsDirectories: Bool = false

	var title: String?
	var message: String?
	var prompt: String?

	// Optional initial directory. If 'nil', defaults to ~/Desktop.
	var directoryURL: URL?

	init(
		canChooseFiles: Bool = true,
		canChooseDirectories: Bool = false,
		allowsMultipleSelection: Bool = false,
		allowedContentTypes: [UTType] = [],
		treatsFilePackagesAsDirectories: Bool = false,
		title: String? = nil,
		message: String? = nil,
		prompt: String? = nil,
		directoryURL: URL? = nil) {
		self.canChooseFiles = canChooseFiles
		self.canChooseDirectories = canChooseDirectories
		self.allowsMultipleSelection = allowsMultipleSelection
		self.allowedContentTypes = allowedContentTypes
		self.treatsFilePackagesAsDirectories = treatsFilePackagesAsDirectories
		self.title = title
		self.message = message
		self.prompt = prompt
		self.directoryURL = directoryURL }
}

@MainActor
enum OpenPanelSelection { case canceled; case urls([URL]) }

// Centralized helper for presenting NSOpenPanel as a sheet with consistent sizing.
@MainActor
enum OpenPanelPresenter {
	// Presents an NSOpenPanel configured with the provided options.
	// - Parameters:
	//   - configuration: Configuration options for the panel.
	//   - window: The window to attach the sheet to. If nil, uses keyWindow or mainWindow.
	// - Returns: '.urls([URL])' if the user confirmed, '.canceled' otherwise.
	static func present(
		configuration: OpenPanelConfiguration,
		attachedTo window: NSWindow? = nil
	) async -> OpenPanelSelection {
		let panel = NSOpenPanel()

		// Core configuration.
		panel.canChooseFiles = configuration.canChooseFiles
		panel.canChooseDirectories = configuration.canChooseDirectories
		panel.allowsMultipleSelection = configuration.allowsMultipleSelection
		panel.treatsFilePackagesAsDirectories = configuration.treatsFilePackagesAsDirectories

		if !configuration.allowedContentTypes.isEmpty {
			panel.allowedContentTypes = configuration.allowedContentTypes }

		// Default to ~/Desktop if not specified.
		if let directoryURL = configuration.directoryURL {
			panel.directoryURL = directoryURL
		} else if let desktop = FileManager.default.urls(
			for: .desktopDirectory, in: .userDomainMask).first {
			panel.directoryURL = desktop }

		if let title = configuration.title { panel.title = title }
		if let message = configuration.message { panel.message = message }
		if let prompt = configuration.prompt { panel.prompt = prompt }

		// Enforce fixed size and non-resizable behavior.
		panel.styleMask.remove(.resizable)
		panel.setContentSize(NSSize(width: 600, height: 400))
		panel.isMovable = false

		let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

		return await withCheckedContinuation { continuation in
			if let targetWindow {
				// Present as sheet attached to the specified window
				panel.beginSheetModal(for: targetWindow) { response in
					if response == .OK { continuation.resume(returning: .urls(panel.urls))
					} else { continuation.resume(returning: .canceled) } }
			} else {
				// Fallback: a standalone modeless panel, for when no window is available
				// to attach a sheet to (should rarely happen). `begin` does not block the
				// rest of the app.
				panel.begin { response in
					if response == .OK { continuation.resume(returning: .urls(panel.urls))
					} else { continuation.resume(returning: .canceled) } }
			}
		}
	}
}

/// Reports the window a view is in, for presenting sheets on it.
struct HostingWindowReader: NSViewRepresentable {
	let onWindow: (NSWindow) -> Void

	func makeNSView(context _: Context) -> WindowProbeView {
		let probe = WindowProbeView(frame: .zero)
		probe.onAttach = onWindow
		return probe
	}

	func updateNSView(_: WindowProbeView, context _: Context) {}
}
