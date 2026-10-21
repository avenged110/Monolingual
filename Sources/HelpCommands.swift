// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  HelpCommands.swift
//  HelpCommands
//
//  Created by Ingmar Stein on 02.10.21.
//  Copyright © 2021 Ingmar Stein. All rights reserved.
//

import SwiftUI

struct HelpCommands: Commands {
	var body: some Commands {
		CommandGroup(before: .help) {
			Button("README.rtfd") {
				open(bundleResource: NSLocalizedString("README.rtfd", comment: ""))
			}
			Button("License (COPYING)") {
				openLicense()
			}
			Button("Donate") {
				open(url: "https://ingmarstein.github.io/Monolingual/donate.html")
			}
			Button("Monolingual Website") {
				open(url: "https://github.com/avenged110/Monolingual")
			}
		}
	}

	/// Opens a document from the app bundle.
	///
	/// The help document is named per language by the strings file, so a translation that names
	/// one the bundle does not carry — or a copy stripped of its resources — would be a trap if
	/// the lookup were unwrapped.
	private func open(bundleResource name: String) {
		let resource = (name as NSString).deletingPathExtension
		let ext = (name as NSString).pathExtension
		guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { return }
		NSWorkspace.shared.open(url)
	}

	/// Opens the license in TextEdit. `COPYING` has no extension, so the system types it as plain
	/// data and has no application of its own to open it with.
	private func openLicense() {
		guard let url = Bundle.main.url(forResource: "COPYING", withExtension: nil) else { return }
		guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
			NSWorkspace.shared.open(url)
			return
		}
		NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
	}

	private func open(url: String) {
		guard let url = URL(string: url) else { return }
		NSWorkspace.shared.open(url)
	}
}
