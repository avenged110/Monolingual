// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  HelperProtocol.swift
//  Monolingual
//
//  Created by Ingmar Stein on 10.04.15.
//
//

import Foundation
import Security
import XPC

public extension ProgressUserInfoKey {
	static let appName = ProgressUserInfoKey("MonolingualAppName")
	static let sizeDifference = ProgressUserInfoKey("MonolingualSizeDifference")
}

/// Names and identities of the privileged helper, shared by the app and the helper itself.
public enum HelperService {
	/// The Mach service the helper serves and the app connects to.
	public static let machServiceName = "com.github.IngmarStein.Monolingual.PrivilegedHelper"

	/// Name of the launchd property list inside the app bundle.
	public static let daemonPlistName = "com.github.IngmarStein.Monolingual.PrivilegedHelper.plist"

	/// The team this build is signed by, or nil for a build signed to run locally (ad hoc).
	///
	/// `appPeerRequirement` and `helperPeerRequirement` can only be met by code signed by a team,
	/// so a build without one uses the C XPC API and `legacyAppPeerRequirement` on every macOS
	/// version — otherwise an ad hoc build would refuse every session on macOS 26 and later.
	public static let signingTeam: String? = ownTeamIdentifier()

	/// The signing identifier of the app. XPC only accepts sessions from code that is signed by
	/// the same team and carries this identifier.
	public static let appSigningIdentifier = "app.Monolingual"

	/// The signing identifier of the helper.
	public static let helperSigningIdentifier = "app.Monolingual.Helper"

	/// What the helper requires of its clients: the Monolingual app, signed by the same team.
	///
	/// This replaces the pid-based check the `NSXPCConnection` version needed, and unlike that one
	/// it is enforced by XPC itself, for every session, without a race.
	@available(macOS 26.0, *)
	public static var appPeerRequirement: XPCPeerRequirement {
		.isFromSameTeam(andMatchesSigningIdentifier: appSigningIdentifier)
	}

	/// What the app requires of the helper it talks to.
	@available(macOS 26.0, *)
	public static var helperPeerRequirement: XPCPeerRequirement {
		.isFromSameTeam(andMatchesSigningIdentifier: helperSigningIdentifier)
	}

	/// What the helper requires of its clients before macOS 26, as a code signing requirement
	/// string for the C XPC API — `XPCPeerRequirement` and the Swift initializers that take one
	/// are macOS 26 only.
	///
	/// With a team, this is what `appPeerRequirement` says: the app's identifier, signed by the
	/// helper's own team. A build signed to run locally has no team, and then the app's own
	/// designated requirement (its cdhash, for an ad-hoc signature) is the closest equivalent.
	/// Nil if neither can be worked out, in which case the helper must not serve anyone.
	public static func legacyAppPeerRequirement(appBundle: URL) -> String? {
		if let team = signingTeam {
			return "anchor apple generic and identifier \"\(appSigningIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
		}
		var staticCode: SecStaticCode?
		guard unsafe SecStaticCodeCreateWithPath(appBundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
			return nil
		}
		var requirement: SecRequirement?
		guard unsafe SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
			return nil
		}
		var text: CFString?
		guard unsafe SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
			return nil
		}
		return text as String
	}

	/// The team the running process is signed by, if any.
	private static func ownTeamIdentifier() -> String? {
		var code: SecCode?
		guard unsafe SecCodeCopySelf([], &code) == errSecSuccess, let code else {
			return nil
		}
		var staticCode: SecStaticCode?
		guard unsafe SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
			return nil
		}
		var info: CFDictionary?
		guard unsafe SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
		      let info = info as? [String: Any] else {
			return nil
		}
		return info[kSecCodeInfoTeamIdentifier as String] as? String
	}
}

/// What the app asks the helper to do. Sent as JSON in an XPC dictionary.
public enum HelperMessage: Codable, Sendable, Equatable {
	/// Report the version of the app bundle the helper belongs to.
	case version
	/// Carry out a request; progress and the result arrive on the endpoint sent with it.
	case process(HelperRequest)
	/// Stop the current request and exit with this status.
	case exit(Int)
}

/// What the helper sends back.
public enum HelperReply: Codable, Sendable, Equatable {
	case version(String)
	case progress(file: String, size: Int, appName: String?)
	case finished(exitCode: Int)
	/// The request has been accepted; the result follows as a `finished` reply.
	case accepted
}

/// Keys of the XPC dictionaries the two sides exchange.
public enum HelperMessageKey {
	/// The message, as JSON.
	public static let payload = "payload"
	/// The endpoint the helper reports progress and the result on.
	public static let progress = "progress"
}

/// A message that could not be read out of the dictionary it arrived in.
public enum HelperWireError: LocalizedError {
	/// The dictionary carried no message.
	case missingPayload

	public var errorDescription: String? {
		switch self {
		case .missingPayload:
			"The XPC dictionary carried no payload."
		}
	}
}

/// Turns messages into the XPC dictionaries they travel in, and back.
///
/// The payload is JSON in `payload`, because XPC values and `Codable` values are different
/// worlds: `XPCDictionary` has no accessor for `Data`, so the bytes go in and come out through
/// the underlying C dictionary. The endpoint for progress and results is an XPC value, and
/// `XPCSession.send` requires all values of a dictionary to have the same type — which is why
/// `["payload": data, "progress": endpoint]` does not compile and the two travel as two
/// messages.
public enum HelperWire {
	/// The dictionary a message travels in.
	public static func dictionary(for message: some Encodable) throws -> XPCDictionary {
		let dictionary = XPCDictionary()
		dictionary.setData(try JSONEncoder().encode(message), forKey: HelperMessageKey.payload)
		return dictionary
	}

	/// The dictionary an endpoint travels in.
	public static func dictionary(carrying endpoint: XPCEndpoint) -> XPCDictionary {
		var dictionary = XPCDictionary()
		dictionary[HelperMessageKey.progress] = endpoint
		return dictionary
	}

	/// The message carried in `dictionary`.
	public static func message<T: Decodable>(_ type: T.Type = T.self, in dictionary: XPCDictionary) throws -> T {
		guard let data = dictionary.data(forKey: HelperMessageKey.payload) else {
			throw HelperWireError.missingPayload
		}
		return try JSONDecoder().decode(type, from: data)
	}

	/// The endpoint carried in `dictionary`, if this dictionary carries one.
	public static func endpoint(in dictionary: XPCDictionary) -> XPCEndpoint? {
		dictionary[HelperMessageKey.progress]
	}
}

public extension XPCDictionary {
	/// Stores `data` under `key`.
	///
	/// `XPCDictionary`'s subscript is typed for scalars, strings, dictionaries, arrays and
	/// endpoints, but not for `Data`, so this reaches for the C call the subscript is built on.
	func setData(_ data: Data, forKey key: String) {
		withUnsafeUnderlyingDictionary { underlying in
			unsafe data.withUnsafeBytes { bytes in
				// An empty buffer may have no base address; XPC needs a pointer all the same.
				guard let base = bytes.baseAddress else {
					unsafe xpc_dictionary_set_data(underlying, key, [UInt8](), 0)
					return
				}
				unsafe xpc_dictionary_set_data(underlying, key, base, bytes.count)
			}
		}
	}

	/// The data stored under `key`.
	func data(forKey key: String) -> Data? {
		withUnsafeUnderlyingDictionary { underlying in
			var length = 0
			guard let bytes = unsafe xpc_dictionary_get_data(underlying, key, &length) else {
				return nil
			}
			return unsafe Data(bytes: bytes, count: length)
		}
	}
}
