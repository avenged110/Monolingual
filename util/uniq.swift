// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
import Foundation

var result: [[NSObject: AnyObject]] = []
if let blacklist = NSArray(contentsOfFile: "blacklist.plist") as? [[NSObject: AnyObject]] {
	var seen = Set<String>()
	for entry in blacklist {
		if let bundle = entry["bundle"] as? String {
			if seen.contains(bundle) {
				print("Duplicate: \(bundle)")
			} else {
				seen.insert(bundle)
				result.append(entry)
			}
		}
	}
}

(result as NSArray).write(toFile: "uniq.plist", atomically: true)
