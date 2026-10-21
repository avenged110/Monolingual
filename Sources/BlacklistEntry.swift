// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  BlacklistEntry.swift
//  Monolingual
//
//  Created by Ingmar Stein on 16.07.14.
//
//

import Foundation

struct BlacklistEntry: Decodable {
	let bundle: String
	let languages: Bool
	let architectures: Bool
}
