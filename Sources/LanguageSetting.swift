// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  LanguageSetting.swift
//  Monolingual
//
//  Created by Ingmar Stein on 16.07.14.
//
//

import Foundation

struct LanguageSetting: Identifiable, Equatable {
	let id: UUID
	var enabled: Bool
	let folders: [String]
	let displayName: String

	/// Localizations that can never be selected or removed: English, "English (United States)"
	/// (`en_US`) and "English (United States, computer)" (`en_US_POSIX`). The system needs
	/// English, and removing it is one of the ways an installation gets broken beyond repair (see
	/// the "never remove the English language files" entry in the help). Each setting's first
	/// folder is its locale identifier's, which is what this matches.
	static let protectedFolders: Set<String> = ["en.lproj", "en_US.lproj", "en_US_POSIX.lproj"]

	var isProtected: Bool {
		!Self.protectedFolders.isDisjoint(with: folders)
	}

	init(enabled: Bool, folders: [String], displayName: String) {
		self.id = UUID()
		self.enabled = enabled
		self.folders = folders
		self.displayName = displayName
	}
}
