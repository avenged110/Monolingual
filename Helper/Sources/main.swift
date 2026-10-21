// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  main.swift
//  Monolingual
//
//  Created by Ingmar Stein on 10.04.15.
//
//

import Foundation
#if canImport(HelperShared)
import HelperShared
#endif

private let usageText = """
usage: com.github.IngmarStein.Monolingual.Helper [options]

Without --include, runs as the launchd daemon and waits for requests from the app.

  -v, --version          Print version and exit.
  -n, --dry-run          Dry run: don't make any changes to the filesystem.
  -s, --strip            Strip debug info from executables.
  -t, --trash            Don't delete files but move them to the trash.
  -i, --include <dir>    Include directory.
  -x, --exclude <dir>    Exclude directory.
  -b, --bundle <id>      Exclude a bundle from processing (e.g. "com.apple.iPhoto").
  -d, --delete <name>    Name of a file or directory to delete (e.g. "fr.lproj").
  -a, --thin <arch>      Remove architecture from universal binary (e.g. "ppc").
  -h, --help             Show this help.

Options that take a value can be repeated, and accept --name=value as well.
"""

/// Prints `message` and the usage to standard error and exits: the invocation was wrong, so it
/// is not a success.
private func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("error: \(message)\n\n\(usageText)".utf8))
	exit(EXIT_FAILURE)
}

struct Options {
	var version = false
	var dryRun = false
	var strip = false
	var trash = false
	// Empty by default: launchd starts the helper without any arguments, and that has to mean
	// "serve requests" rather than an error.
	var include: [String] = []
	var exclude: [String] = []
	var bundle: [String] = []
	var delete: [String] = []
	var thin: [String] = []

	/// Reads the options from `arguments`, which excludes the path of the executable.
	init(_ arguments: ArraySlice<String>) {
		let flags: [String: WritableKeyPath<Options, Bool>] = [
			"-v": \.version, "--version": \.version,
			"-n": \.dryRun, "--dry-run": \.dryRun,
			"-s": \.strip, "--strip": \.strip,
			"-t": \.trash, "--trash": \.trash
		]
		let lists: [String: WritableKeyPath<Options, [String]>] = [
			"-i": \.include, "--include": \.include,
			"-x": \.exclude, "--exclude": \.exclude,
			"-b": \.bundle, "--bundle": \.bundle,
			"-d": \.delete, "--delete": \.delete,
			"-a": \.thin, "--thin": \.thin
		]

		var args = arguments.makeIterator()
		while let arg = args.next() {
			if arg == "-h" || arg == "--help" {
				print(usageText)
				exit(EXIT_SUCCESS)
			}
			if let flag = flags[arg] {
				self[keyPath: flag] = true
				continue
			}
			// "--name=value" carries its value in the same argument.
			if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
				let name = String(arg[..<equals])
				guard let list = lists[name] else { fail("unknown option '\(name)'") }
				self[keyPath: list].append(String(arg[arg.index(after: equals)...]))
				continue
			}
			if let list = lists[arg] {
				// A value that looks like another option is a missing value, not a path.
				guard let value = args.next(), !value.hasPrefix("-") else { fail("missing value for '\(arg)'") }
				self[keyPath: list].append(value)
				continue
			}
			fail(arg.hasPrefix("-") ? "unknown option '\(arg)'" : "unexpected argument '\(arg)'")
		}
	}
}

let options = Options(CommandLine.arguments.dropFirst())

let helper = Helper()

if options.version {
	print("MonolingualHelper version \(helper.version)")
	exit(EXIT_SUCCESS)
}

if options.include.isEmpty {
	helper.run()
} else {
	var request = HelperRequest()
	request.dryRun = options.dryRun
	request.doStrip = options.strip
	request.trash = options.trash
	request.includes = options.include
	request.excludes = options.exclude
	request.bundleBlacklist = Set<String>(options.bundle)
	request.directories = Set<String>(options.delete)
	request.thin = options.thin
	// Each removed (or, in a dry run, removable) item on a line of its own, with the bytes it frees.
	helper.process(request: request, report: { reply in
		if case let .progress(file, size, _) = reply {
			print("\(file): \(size)")
		}
	}) { result in
		exit(Int32(result))
	}
	RunLoop.current.run()
}
