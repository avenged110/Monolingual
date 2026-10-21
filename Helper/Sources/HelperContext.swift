// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  HelperContext.swift
//  Monolingual
//
//  Created by Ingmar Stein on 10.04.15.
//
//

import Foundation
import OSLog

final class HelperContext: NSObject, FileManagerDelegate, @unchecked Sendable {
	var request: HelperRequest
	/// Reports progress to the app, which is on the other side of the XPC connection.
	var reportToClient: ((HelperReply) -> Void)?
	var progress: Progress?
	private var fileBlacklist = Set<URL>()
	let fileManager = FileManager()
	let isRootless: Bool
	let logger = Logger()

	init(_ request: HelperRequest, rootless: Bool) {
		self.request = request
		isRootless = rootless

		super.init()

		// exclude the user's trash directory
		setEffectiveUser(request.uid)
		for trashURL in fileManager.urls(for: .trashDirectory, in: [.userDomainMask]) {
			excludeDirectory(trashURL)
		}

		// exclude root's trash directory
		setEffectiveUser(0)
		for trashURL in fileManager.urls(for: .trashDirectory, in: [.userDomainMask]) {
			excludeDirectory(trashURL)
		}

		unsafe fileManager.delegate = self
	}

	/// Switches the process to `uid`, which is what a file has to be owned by to be moved to that
	/// user's trash.
	///
	/// `seteuid` is process-wide — every thread changes with it — so a failure here is not local to
	/// the caller: the daemon would go on running as the wrong user, and moving files to the trash
	/// would fail at the end of a removal that reported nothing wrong.
	private func setEffectiveUser(_ uid: uid_t) {
		if seteuid(uid) != 0 {
			logger.error("Failed to change to uid \(uid, privacy: .public): \(unsafe String(cString: strerror(errno)), privacy: .public)")
		}
	}

	func isExcluded(_ url: URL) -> Bool {
		guard let excludes = request.excludes else {
			return false
		}

		let path = url.path
		return excludes.contains { exclude in
			// Excluding a directory excludes what is below it, and nothing else: comparing
			// plain prefixes would let "/bin" exclude "/binary" as well.
			path == exclude || path.hasPrefix(exclude.hasSuffix("/") ? exclude : exclude + "/")
		}
	}

	func excludeDirectory(_ url: URL) {
		if request.excludes != nil {
			request.excludes?.append(url.path)
		} else {
			request.excludes = [url.path]
		}
	}

	func isDirectoryBlacklisted(_ path: URL) -> Bool {
		if let bundle = Bundle(url: path), let bundleIdentifier = bundle.bundleIdentifier, let bundleBlacklist = request.bundleBlacklist {
			return bundleBlacklist.contains(bundleIdentifier)
		}
		return false
	}

	func isFileBlacklisted(_ url: URL) -> Bool {
		fileBlacklist.contains(url)
	}

	private func addFileDictionaryToBlacklist(_ files: [String: AnyObject], baseURL: URL) {
		for (key, value) in files {
			if let valueDict = value as? [String: AnyObject], let optional = valueDict["optional"] as? Bool, optional {
				continue
			}
			fileBlacklist.insert(baseURL.appendingPathComponent(key))
		}
	}

	func addCodeResourcesToBlacklist(_ url: URL) {
		var codeRef: SecStaticCode?
		// This call might print "MacOS error: -67028" to the console (harmless, but annoying)
		// See rdar://33203786
		let result = unsafe SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef)
		if result == errSecSuccess, let code = codeRef {
			var codeInfoRef: CFDictionary?
			// warning: this relies on kSecCSInternalInformation
			let secCSInternalInformation = SecCSFlags(rawValue: 1)
			let result2 = unsafe SecCodeCopySigningInformation(code, secCSInternalInformation, &codeInfoRef)
			if result2 == errSecSuccess, let codeInfo = codeInfoRef as? [String: AnyObject] {
				if let resDir = codeInfo["ResourceDirectory"] as? [String: AnyObject] {
					let baseURL: URL

					let contentsDirectory = url.appendingPathComponent("Contents", isDirectory: true)
					if fileManager.fileExists(atPath: contentsDirectory.path) {
						baseURL = contentsDirectory
					} else {
						baseURL = url
					}
					if let files = resDir["files"] as? [String: AnyObject] {
						addFileDictionaryToBlacklist(files, baseURL: baseURL)
					}

					// Version 2 Code Signature (introduced in Mavericks)
					// https://developer.apple.com/library/mac/technotes/tn2206
					if let files = resDir["files2"] as? [String: AnyObject] {
						addFileDictionaryToBlacklist(files, baseURL: baseURL)
					}
				}
			}
		}
	}

	private func appNameForURL(_ url: URL) -> String? {
		let pathComponents = url.pathComponents
		for (i, pathComponent) in pathComponents.enumerated() where (pathComponent as NSString).pathExtension == "app" {
			if let bundleURL = NSURL.fileURL(withPathComponents: Array(pathComponents[0 ... i])) {
				if let bundle = Bundle(url: bundleURL) {
					var displayName: String?
					if let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first,
					   let infoPlistStringsURL = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: localization),
					   let strings = NSDictionary(contentsOf: infoPlistStringsURL) as? [String: String] {
						displayName = strings["CFBundleDisplayName"]
					}
					if displayName == nil {
						// seems not to be localized?!?
						displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
					}
					if let displayName = displayName {
						return displayName
					}
				}
			}
			return String(pathComponent[..<pathComponent.index(pathComponent.endIndex, offsetBy: -4)])
		}
		return nil
	}

	func reportProgress(url: URL, size: Int) {
		let appName = appNameForURL(url)

		if let progress = progress {
			progress.fileCompletedCount = (progress.fileCompletedCount ?? 0) + 1
			progress.fileURL = url
			progress.setUserInfoObject(size, forKey: ProgressUserInfoKey.sizeDifference)
			if let appName = appName {
				progress.setUserInfoObject(appName, forKey: ProgressUserInfoKey.appName)
			}
			progress.totalUnitCount += Int64(size)
			progress.completedUnitCount += Int64(size)

			// show the file progress even if it has zero bytes
			if size == 0 {
				progress.willChangeValue(for: \.completedUnitCount)
				progress.didChangeValue(for: \.completedUnitCount)
			}
		}

		reportToClient?(.progress(file: url.path, size: size, appName: appName))
	}

	/// Reports what removing `url` would free, without changing anything: the files below it that
	/// a removal would take, which leaves out files sealed by a code signature — and, when moving
	/// to the Trash, the whole of `url` if any of them is, since it is then left alone entirely.
	private func reportDryRun(_ url: URL) {
		var total = 0
		let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
		if let dirEnumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) {
			for entry in dirEnumerator {
				guard let theURL = entry as? URL else { continue }
				if isFileBlacklisted(theURL) {
					if request.trash {
						return
					}
					continue
				}
				if isRootless && theURL.isProtected {
					continue
				}
				if let values = try? theURL.resourceValues(forKeys: Set(keys)) {
					total += values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
				}
			}
		}
		reportProgress(url: url, size: total)
	}

	func remove(_ url: URL) {
		if request.dryRun {
			reportDryRun(url)
			return
		}

		var error: (any Error)?
		if request.trash {
			var dstURL: NSURL?

			// trashItemAtURL does not call any delegate methods (radar 20481813)

			var fileSize: [URL: Int] = [:]

			// Nothing is changed while the tree is being walked: the walk can end in the early
			// return below, and attributes already set would stay set on a directory that is never
			// trashed — leaving a system directory owned by the user.
			var reown: [(url: URL, attributes: [FileAttributeKey: Any])] = []
			// What each of those had before, so that a move to the trash that fails leaves the files
			// owned as they were rather than handed to the user.
			var original: [(url: URL, attributes: [FileAttributeKey: Any])] = []
			let ownershipKeys: Set<FileAttributeKey> = [.ownerAccountID, .posixPermissions]

			// check if any file below `url` has been blocked and record sizes
			if let dirEnumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey], options: [], errorHandler: nil) {
				for entry in dirEnumerator {
					guard let theURL = entry as? URL else { continue }
					if isFileBlacklisted(theURL) {
						return
					}

					do {
						let resourceValues = try theURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey])
						if let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
							fileSize[theURL] = size
						}

						// change owner so that it can be moved to the user's trash
						// see https://github.com/IngmarStein/Monolingual/issues/110
						let attributes: [FileAttributeKey: Any]
						if let isDirectory = resourceValues.isDirectory, isDirectory {
							attributes = [.ownerAccountID: request.uid, .posixPermissions: S_IRWXU]
						} else {
							attributes = [.ownerAccountID: request.uid]
						}
						reown.append((theURL, attributes))
						if let current = try? fileManager.attributesOfItem(atPath: theURL.path) {
							original.append((theURL, current.filter { ownershipKeys.contains($0.key) }))
						}
					} catch {}
				}
			}

			for (theURL, attributes) in reown {
				try? fileManager.setAttributes(attributes, ofItemAtPath: theURL.path)
			}

			// The parent has to be writable for the entry to be moved out of it, which means
			// changing the ownership of a directory the user did not ask to change. That is only
			// done when the parent is a real directory: `setAttributes` follows a terminal symbolic
			// link, so a root that is itself a link would otherwise hand the link's target — a
			// system directory, say — to the user. The restore below is skipped with it, since
			// there is nothing to restore.
			let parent = url.deletingLastPathComponent()
			let parentValues = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			let parentIsRealDirectory = parentValues?.isDirectory == true && parentValues?.isSymbolicLink != true
			let parentAttributes = parentIsRealDirectory ? try? fileManager.attributesOfItem(atPath: parent.path) : nil
			if let current = try? fileManager.attributesOfItem(atPath: url.path) {
				original.append((url, current.filter { ownershipKeys.contains($0.key) }))
			}

			do {
				try fileManager.setAttributes([.ownerAccountID: request.uid, .posixPermissions: S_IRWXU], ofItemAtPath: url.path)
				if parentIsRealDirectory {
					try fileManager.setAttributes([.ownerAccountID: request.uid, .posixPermissions: S_IRWXU], ofItemAtPath: parent.path)
				}
			} catch {
				logger.error("failed to set owner: \(error.localizedDescription, privacy: .public)")
			}

			// try to move the file to the user's trash
			var success = false
			setEffectiveUser(request.uid)
			do {
				unsafe try fileManager.trashItem(at: url, resultingItemURL: &dstURL)
				success = true
			} catch let error1 {
				error = error1
				logger.error("Could not move \(url.absoluteString, privacy: .public) to trash: \(error1.localizedDescription, privacy: .public)")
				success = false
			}
			setEffectiveUser(0)
			if !success {
				do {
					// move the file to root's trash
					unsafe try fileManager.trashItem(at: url, resultingItemURL: &dstURL)
					success = true
				} catch let error1 {
					error = error1
					success = false
				}
			}

			if let parentAttributes = parentAttributes {
				try? fileManager.setAttributes(parentAttributes, ofItemAtPath: parent.path)
			}

			if success {
				for (url, size) in fileSize {
					reportProgress(url: url, size: size)
				}
			} else {
				// Nothing was moved, so everything goes back to its owner (the effective user is root
				// again by now, so the order does not matter).
				for (theURL, attributes) in original {
					try? fileManager.setAttributes(attributes, ofItemAtPath: theURL.path)
				}
				if let error = error {
					logger.error("Error trashing '\(url.path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
				}
			}
		} else {
			do {
				try fileManager.removeItem(at: url)
			} catch let error1 {
				error = error1
				let nsError = error1 as NSError
				if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlyingError.domain == NSPOSIXErrorDomain, underlyingError.code == Int(ENOTEMPTY) {
					// ignore non-empty directories (they might contain blacklisted files and cannot be removed)
				} else {
					logger.error("Error removing '\(url.path, privacy: .public)': \(nsError, privacy: .public)")
				}
			}
		}
	}

	private func fileManager(_: FileManager, shouldProcessItemAtURL url: URL) -> Bool {
		if request.dryRun || isFileBlacklisted(url) || (isRootless && url.isProtected) {
			return false
		}

		// TODO: it is wrong to report process here, deletion might fail
		do {
			let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
			if let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
				reportProgress(url: url, size: size)
			}
		} catch {}
		return true
	}

	// MARK: - NSFileManagerDelegate

	func fileManager(_ fileManager: FileManager, shouldRemoveItemAt url: URL) -> Bool {
		self.fileManager(fileManager, shouldProcessItemAtURL: url)
	}

	func fileManager(_: FileManager, shouldProceedAfterError _: any Error, removingItemAt _: URL) -> Bool {
		// https://github.com/IngmarStein/Monolingual/issues/102
		// logger.error("Error removing '\(url.path, privacy: .public)': \(error as NSError, privacy: .public)")

		true
	}
}
