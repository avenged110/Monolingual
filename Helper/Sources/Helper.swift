// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  Helper.swift
//  Monolingual
//
//  Created by Ingmar Stein on 10.04.15.
//
//

import Foundation
import MachO.fat
import MachO.loader
import OSLog
import XPC
#if canImport(LipoCore)
import LipoCore
#endif

extension URL {
	func hasExtendedAttribute(_ attribute: String) -> Bool {
		unsafe getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) != -1
	}

	var isProtected: Bool {
		hasExtendedAttribute("com.apple.rootless")
	}
}

public final class Helper: @unchecked Sendable {
	/// The queue messages are handled on. The work itself runs on `workerQueue` instead, so a
	/// second message — the app cancelling — is still handled while a removal is running.
	/// Sessions inherit this queue, which is what keeps everything below it serialized.
	private let messageQueue = DispatchQueue(label: "com.github.IngmarStein.Monolingual.Helper.messages")
	private let workerQueue = OperationQueue()
	/// The listener: an `XPCListener` on macOS 26 and later, an `xpc_connection_t` before.
	private var listener: AnyObject?
	/// The session the app opened. Held on to, because the session lives only as long as this
	/// reference does. Only used on macOS 26 and later.
	private var clientSession: AnyObject?
	/// The app's listener, which progress and the result are reported on.
	private var progressSession: ProgressChannel?
	/// The bookkeeping of the running request, so that the app can still cancel it.
	private var currentProgress: Progress?
	private var timer: Timer?
	private let timeoutInterval = TimeInterval(30.0)
	private var isRootless = true
	private let logger = Logger()

	/// The version of the Monolingual whose helper this is.
	///
	/// The helper is an executable in `Contents/MacOS` of the app bundle. For such an executable
	/// `Bundle.main` names the enclosing `.app` but answers `object(forInfoDictionaryKey:)` from
	/// the info dictionary compiled into the executable, which would make the app and its helper
	/// carry a version each — two hardcoded strings that a release has to bump together. The
	/// app's info dictionary is what the app compares against, so it is read here, and the
	/// version of the helper itself is only the fallback for running the binary on its own.
	public var version: String {
		let appPlist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
		if let data = try? Data(contentsOf: appPlist),
		   let plist = unsafe try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
		   let version = plist[kCFBundleVersionKey as String] as? String {
			return version
		}
		return Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "vUNKNOWN"
	}

	public init() {
		workerQueue.maxConcurrentOperationCount = 1
		isRootless = checkRootless()
		logger.debug("isRootless=\(self.isRootless ? "true" : "false", privacy: .public)")
	}

	public func run() {
		logger.info("MonolingualHelper \(self.version, privacy: .public) started")

		if #available(macOS 26.0, *), HelperService.signingTeam != nil {
			do {
				// XPC checks the peer against this requirement before a session is handed over,
				// for every session — no pid to look up, and no window to reuse one in.
				//
				// A listener listens as soon as it is created; there is no `activate()` to call
				// here, and calling one would be an API misuse crash.
				listener = try XPCListener(service: HelperService.machServiceName,
				                           targetQueue: messageQueue,
				                           requirement: HelperService.appPeerRequirement) { [self] request in
					accept(request)
				}
			} catch {
				logger.error("Failed to serve \(HelperService.machServiceName, privacy: .public): \(error.localizedDescription, privacy: .public)")
				Darwin.exit(EXIT_FAILURE)
			}
		} else {
			listenLegacy()
		}

		startIdleTimer()
		RunLoop.current.run()
	}

	/// Starts the timeout that exits the daemon when it has nothing to do.
	///
	/// The timer belongs on the main run loop, which is the one `run()` keeps running: on the
	/// message queue — where requests arrive — a timer would be added to a run loop nobody runs.
	private func startIdleTimer() {
		DispatchQueue.main.async { [self] in
			timer?.invalidate()
			let timer = Timer(timeInterval: timeoutInterval, repeats: false) { [self] _ in
				logger.info("timeout while waiting for request")
				exit(code: Int(EXIT_SUCCESS))
			}
			RunLoop.main.add(timer, forMode: .common)
			self.timer = timer
		}
	}

	/// Stops the timeout while a request is being served.
	private func stopIdleTimer() {
		DispatchQueue.main.async { [self] in
			timer?.invalidate()
			timer = nil
		}
	}

	/// Stops the running request and exits with `code`.
	public func exit(code: Int) {
		logger.info("exiting with exit status \(code, privacy: .public)")
		// Anything but success means the app cancelled. The removal then stops at the next place it
		// looks — before the next root, and before the next entry of a directory being walked —
		// rather than working through the whole tree first. A subtree already handed to
		// `removeItem` is not interrupted, so this can wait for a while yet.
		currentProgress?.cancel()
		workerQueue.waitUntilAllOperationsAreFinished()
		// `code` arrives over XPC: `Int32(_:)` would trap on a value out of range, and trapping
		// here would take the daemon down mid-removal instead of exiting cleanly.
		Darwin.exit(Int32(clamping: code))
	}

	@discardableResult public func process(request: HelperRequest, report: ((HelperReply) -> Void)?, reply: @escaping (Int) -> Void) -> Progress {
		stopIdleTimer()

		// check if /usr/bin/strip is present
		var request = request
		request.doStrip = request.doStrip && FileManager.default.fileExists(atPath: "/usr/bin/strip")

		let context = HelperContext(request, rootless: isRootless)

		logger.debug("Received request: \(String(describing: request), privacy: .public)")

		// Progress is no longer shared across processes: this object only tallies what was
		// removed, which is what the tests check and what the helper reports as messages.
		// `totalUnitCount` starts at one rather than being indeterminate so that its counts
		// always add up.
		let progress = Progress(totalUnitCount: 1)
		progress.completedUnitCount = 0
		progress.cancellationHandler = {
			self.logger.info("Stopping MonolingualHelper")
		}
		context.progress = progress
		context.reportToClient = report
		currentProgress = progress

		struct SendableReply: @unchecked Sendable {
			let reply: (Int) -> Void
		}
		let sendableReply = SendableReply(reply: reply)

		// The request is a value: settling `doStrip` before this point means the operation can
		// capture it as a constant instead of sharing a mutable one.
		let pending = request

		workerQueue.addOperation {
			let roots = pending.includes?.map { URL(fileURLWithPath: $0, isDirectory: true) }

			// recursively delete directories
			if let roots, let directories = pending.directories, !directories.isEmpty {
				for root in roots {
					if progress.isCancelled {
						break
					}
					self.processDirectory(root, context: context)
				}
			}

			// thin fat binaries (a dry run only lists them; see `thinDirectory`)
			if let archs = pending.thin, let roots, !archs.isEmpty {
				if let lipo = Lipo(archs: archs) {
					for root in roots {
						if progress.isCancelled {
							break
						}
						self.thinDirectory(root, context: context, lipo: lipo)
					}
				}
			}

			sendableReply.reply(progress.isCancelled ? Int(EXIT_FAILURE) : Int(EXIT_SUCCESS))

			// The daemon goes back to timing itself out, which is also what takes it down when
			// the app never asks it to exit.
			self.startIdleTimer()
		}

		return progress
	}

	// MARK: - Serving the app

	/// The code signing requirement the app has to meet before macOS 26.
	private lazy var legacyRequirement: String? = HelperService.legacyAppPeerRequirement(appBundle: Bundle.main.bundleURL)

	/// Serves the Mach service with the C XPC API, for macOS before 26 and for a build without a
	/// team (see `HelperService.signingTeam`).
	///
	/// The Swift `XPCListener` only takes a peer requirement from macOS 26 on, and without one any
	/// local process could ask this root daemon to delete files. The C API has enforced a code
	/// signing requirement per peer connection since macOS 12, and `XPCSession` clients talk to
	/// `xpc_connection` listeners just the same.
	private func listenLegacy() {
		guard let requirement = legacyRequirement else {
			logger.error("Could not work out the code signing requirement for the app; refusing to serve")
			Darwin.exit(EXIT_FAILURE)
		}
		let listener = unsafe xpc_connection_create_mach_service(HelperService.machServiceName, messageQueue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
		xpc_connection_set_event_handler(listener) { [self] peer in
			guard unsafe xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
				return
			}
			guard unsafe xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
				logger.error("Rejecting a peer: invalid code signing requirement")
				xpc_connection_cancel(peer)
				return
			}
			// XPC objects are thread-safe, but not marked Sendable; the handler runs on
			// `messageQueue` like everything else here.
			nonisolated(unsafe) let peer = peer
			unsafe xpc_connection_set_event_handler(peer) { [self] event in
				// Errors (including a peer that fails the requirement) cancel the connection.
				guard unsafe xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
					return
				}
				let reply = handle(XPCDictionary(event))
				guard let reply, let replyObject = xpc_dictionary_create_reply(event) else {
					return
				}
				_ = reply.withUnsafeUnderlyingDictionary { underlying in
					unsafe xpc_dictionary_apply(underlying) { key, value in
						unsafe xpc_dictionary_set_value(replyObject, key, value)
						return true
					}
				}
				unsafe xpc_connection_send_message(peer, replyObject)
			}
			unsafe xpc_connection_resume(peer)
		}
		xpc_connection_resume(listener)
		self.listener = listener
	}

	/// Serves a session the app opened.
	@available(macOS 26.0, *)
	private func accept(_ request: XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
		let (decision, session) = request.accept { [self] dictionary in
			handle(dictionary)
		}
		// XPC crashes if a session is released while it is active, so the previous one is
		// cancelled before it is let go — the app opens a new one for every removal.
		(clientSession as? XPCSession)?.cancel(reason: "another session arrived")
		clientSession = session
		return decision
	}

	/// Handles one message from the app and returns the reply to send, if the app waits for one.
	private func handle(_ dictionary: XPCDictionary) -> XPCDictionary? {
		// The app sends the endpoint for progress and the result on its own, before the request
		// those belong to. It does not wait for an answer.
		if let endpoint = HelperWire.endpoint(in: dictionary) {
			openProgressConnection(to: endpoint)
			return nil
		}

		guard let message = try? HelperWire.message(HelperMessage.self, in: dictionary) else {
			logger.error("Ignoring an XPC message without a payload")
			return nil
		}

		switch message {
		case .version:
			return reply(.version(version))
		case let .process(request):
			// The removal runs on the worker queue, so answer before starting it.
			start(request)
			return reply(.accepted)
		case let .exit(code):
			exit(code: code)
			return nil
		}
	}

	/// Opens the connection the app's endpoint stands for, to report progress and the result on.
	private func openProgressConnection(to endpoint: XPCEndpoint) {
		// XPC crashes if a session is released while it is active: the one from a previous
		// removal is cancelled before it is replaced.
		progressSession?.cancel()
		progressSession = nil

		guard #available(macOS 26.0, *), HelperService.signingTeam != nil else {
			guard let requirement = legacyRequirement else {
				logger.error("Failed to open the connection to the app: no code signing requirement")
				return
			}
			// The endpoint's C object is what the C API connects to.
			let dictionary = HelperWire.dictionary(carrying: endpoint)
			let rawEndpoint = dictionary.withUnsafeUnderlyingDictionary { underlying in
				unsafe xpc_dictionary_get_value(underlying, HelperMessageKey.progress)
			}
			guard let rawEndpoint, unsafe xpc_get_type(rawEndpoint) == XPC_TYPE_ENDPOINT else {
				logger.error("Failed to open the connection to the app: no endpoint")
				return
			}
			let connection = xpc_connection_create_from_endpoint(rawEndpoint)
			guard unsafe xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
				logger.error("Failed to open the connection to the app: invalid code signing requirement")
				xpc_connection_cancel(connection)
				return
			}
			xpc_connection_set_target_queue(connection, messageQueue)
			xpc_connection_set_event_handler(connection) { _ in }
			xpc_connection_resume(connection)
			progressSession = .legacy(connection)
			return
		}

		do {
			// A peer requirement can only be attached to a session that is not active yet, so
			// the session is created inactive and activated after. Sessions created from the
			// listener do not inherit its requirement, hence attaching one here as well.
			let session = try XPCSession(endpoint: endpoint, options: .inactive)
			session.setPeerRequirement(HelperService.appPeerRequirement)
			try session.activate()
			progressSession = .session(session)
		} catch {
			logger.error("Failed to open the connection to the app: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Carries out `request`, reporting progress and the result to the app.
	private func start(_ request: HelperRequest) {
		// Read here, on the message queue, so that the reports capture the session rather than
		// reaching for it from the worker queue later.
		let session = progressSession
		let reportProgress: (HelperReply) -> Void = { [self] reply in
			self.report(reply, on: session)
		}
		let reportResult: (Int) -> Void = { [self] exitCode in
			self.report(.finished(exitCode: exitCode), on: session)
		}

		process(request: request, report: reportProgress, reply: reportResult)
	}

	private func report(_ reply: HelperReply, on session: ProgressChannel?) {
		guard let session = session else { return }
		do {
			try session.send(HelperWire.dictionary(for: reply))
		} catch {
			logger.error("Failed to report to the app: \(error.localizedDescription, privacy: .public)")
		}
	}

	private func reply(_ reply: HelperReply) -> XPCDictionary? {
		do {
			return try HelperWire.dictionary(for: reply)
		} catch {
			logger.error("Failed to encode a reply: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	// MARK: -

	/// The connection progress and the result go out on.
	enum ProgressChannel {
		/// A Swift session with a peer requirement, on macOS 26 and later.
		case session(XPCSession)
		/// A C connection with a code signing requirement, before macOS 26.
		case legacy(xpc_connection_t)

		func send(_ dictionary: XPCDictionary) throws {
			switch self {
			case let .session(session):
				try session.send(message: dictionary)
			case let .legacy(connection):
				dictionary.withUnsafeUnderlyingDictionary { underlying in
					xpc_connection_send_message(connection, underlying)
				}
			}
		}

		func cancel() {
			switch self {
			case let .session(session):
				session.cancel(reason: "another request arrived")
			case let .legacy(connection):
				xpc_connection_cancel(connection)
			}
		}
	}

	private func iterateDirectory(_ url: URL, context: HelperContext, prefetchedProperties: [URLResourceKey], block: (URL, FileManager.DirectoryEnumerator) -> Void) {
		if let progress = context.progress, progress.isCancelled {
			return
		}

		if context.isExcluded(url) || context.isDirectoryBlacklisted(url) || (isRootless && url.isProtected) {
			return
		}

		context.addCodeResourcesToBlacklist(url)

		let dirEnumerator = context.fileManager.enumerator(at: url, includingPropertiesForKeys: prefetchedProperties, options: [], errorHandler: nil)
		if let dirEnumerator = dirEnumerator {
			for entry in dirEnumerator {
				if let progress = context.progress, progress.isCancelled {
					return
				}
				guard let theURL = entry as? URL else { continue }

				do {
					let resourceValues = try theURL.resourceValues(forKeys: [.isDirectoryKey])

					if let isDirectory = resourceValues.isDirectory, isDirectory {
						if context.isExcluded(theURL) || context.isDirectoryBlacklisted(theURL) || (isRootless && theURL.isProtected) {
							dirEnumerator.skipDescendents()
							continue
						}
						context.addCodeResourcesToBlacklist(theURL)
					}
				} catch {
					// ignore
				}

				block(theURL, dirEnumerator)
			}
		}
	}

	func processDirectory(_ url: URL, context: HelperContext) {
		iterateDirectory(url, context: context, prefetchedProperties: [.isDirectoryKey, .isSymbolicLinkKey]) { theURL, dirEnumerator in
			do {
				let resourceValues = try theURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

				// A symbolic link is never removed, whatever it resolves to. `remove` runs as root
				// and the ownership it sets follows a link, so an entry merely *named* like a
				// localization would otherwise hand its target to the user. Nothing here relies on
				// that today — Foundation reports a link as neither a directory nor a regular file,
				// which is what an entry has to be to get this far — but the check is what keeps it
				// true if that changes.
				if let isDirectory = resourceValues.isDirectory, isDirectory, resourceValues.isSymbolicLink != true {
					let lastComponent = theURL.lastPathComponent
					if let directories = context.request.directories {
						if directories.contains(lastComponent) {
							context.remove(theURL)
							dirEnumerator.skipDescendents()
						}
					}
				}
			} catch {}
		}
	}

	func thinFile(url: URL, context: HelperContext, lipo: Lipo) {
		var sizeDiff: Int = 0
		if lipo.run(path: url.path, sizeDiff: &sizeDiff) {
			if sizeDiff > 0 {
				context.reportProgress(url: url, size: sizeDiff)
			}
		}
	}

	func thinDirectory(_ url: URL, context: HelperContext, lipo: Lipo) {
		iterateDirectory(url, context: context, prefetchedProperties: [.isDirectoryKey, .isRegularFileKey, .isExecutableKey, .isApplicationKey, .isSymbolicLinkKey]) { theURL, _ in
			do {
				let resourceValues = try theURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey, .isApplicationKey, .isSymbolicLinkKey])
				// A link is not a file to rewrite, and both `strip` and the `lipo` write path follow
				// it: a symbolic link named like an executable would have its target rewritten.
				if let isExecutable = resourceValues.isExecutable, let isRegularFile = resourceValues.isRegularFile, isExecutable, isRegularFile, resourceValues.isSymbolicLink != true, !context.isFileBlacklisted(theURL) {
					if theURL.pathExtension == "class" {
						return
					}

					let data = try Data(contentsOf: theURL, options: [.alwaysMapped, .uncached])
					if data.count >= MemoryLayout<UInt32>.size {
						unsafe data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
							let magic = unsafe pointer.load(as: UInt32.self)
							let isFatMagic = magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
							// A dry run changes nothing: it names the universal binaries a run would
							// thin, without a size, since that is only known once `lipo` has run.
							if context.request.dryRun {
								if isFatMagic {
									context.reportProgress(url: theURL, size: 0)
								}
								return
							}
							if isFatMagic {
								self.thinFile(url: theURL, context: context, lipo: lipo)
							}
							if context.request.doStrip, isFatMagic || magic == MH_MAGIC || magic == MH_CIGAM || magic == MH_MAGIC_64 || magic == MH_CIGAM_64 {
								self.stripFile(theURL, context: context)
							}
						}
					}
				} else if let isApplication = resourceValues.isApplication, isApplication {
					// don't thin universal frameworks contained in a single-architecture application
					// see https://github.com/IngmarStein/Monolingual/issues/67
					let bundle = Bundle(url: theURL)
					if let bundle = bundle, let executableArchitectures = bundle.executableArchitectures, executableArchitectures.count == 1 {
						if let sharedFrameworksURL = bundle.sharedFrameworksURL {
							context.excludeDirectory(sharedFrameworksURL)
						}
						if let privateFrameworksURL = bundle.privateFrameworksURL {
							context.excludeDirectory(privateFrameworksURL)
						}
					}
				}
			} catch {}
		}
	}

	func hasCodeSignature(url: URL) -> Bool {
		var codeRef: SecStaticCode?
		let result = unsafe SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef)
		if result == errSecSuccess, let codeRef = codeRef {
			var requirement: SecRequirement?
			let result2 = unsafe SecCodeCopyDesignatedRequirement(codeRef, [], &requirement)
			return result2 == errSecSuccess
		}
		return false
	}

	func stripFile(_ url: URL, context: HelperContext) {
		// do not modify executables with code signatures
		if !hasCodeSignature(url: url) {
			do {
				let attributes = try context.fileManager.attributesOfItem(atPath: url.path)
				let path = url.path
				let oldSize: Int
				do {
					let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
					oldSize = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? 0
				} catch {
					return
				}

				let process = try Process.run(URL(fileURLWithPath: "/usr/bin/strip", isDirectory: false), arguments: ["-u", "-x", "-S", "-", path])
				process.waitUntilExit()

				if process.terminationStatus != EXIT_SUCCESS {
					logger.error("/usr/bin/strip failed with exit status \(process.terminationStatus, privacy: .public)")
				}

				// Whatever of these the file system reports: `strip` rewrote the file, so its
				// ownership and mode are restored from what it had before.
				let restoredKeys: Set<FileAttributeKey> = [.ownerAccountID, .groupOwnerAccountID, .posixPermissions]
				let newAttributes = attributes.filter { restoredKeys.contains($0.key) }

				do {
					try context.fileManager.setAttributes(newAttributes, ofItemAtPath: path)
				} catch {
					logger.error("Failed to set file attributes for '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
				}

				do {
					// A URL caches the resource values it has read, so without this the size from
					// before `strip` would come back, and the space it freed would never be reported.
					var url = url
					url.removeAllCachedResourceValues()
					let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
					let newSize = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? 0

					if oldSize > newSize {
						let sizeDiff = oldSize - newSize
						context.reportProgress(url: url, size: sizeDiff)
					}
				} catch {}
			} catch {
				logger.error("Failed to get file attributes for '\(url.absoluteString, privacy: .public)': \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	// check if SIP is enabled, see https://github.com/IngmarStein/Monolingual/issues/74
	func checkRootless() -> Bool {
		let protectedDirectory = URL(fileURLWithPath: "/System/Monolingual.sip", isDirectory: true)
		let fileManager = FileManager.default

		do {
			try fileManager.createDirectory(at: protectedDirectory, withIntermediateDirectories: false, attributes: nil)
		} catch {
			return true
		}

		do {
			try fileManager.removeItem(at: protectedDirectory)
		} catch {
			logger.error("Failed to remove temporary file '\(protectedDirectory.absoluteString, privacy: .public)': \(error.localizedDescription, privacy: .public)")
		}

		return false
	}
}
