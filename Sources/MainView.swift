// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  MainView.swift
//  MainView
//
//  Created by Ingmar Stein on 27.09.21.
//  Copyright © 2021 Ingmar Stein. All rights reserved.
//

import SwiftUI
import AppKit
import OSLog
#if canImport(HelperShared)
import HelperShared
#endif

// CPU_SUBTYPE_ARM64E_X1 only exists in the macOS 27 SDK; its value, 12, is confirmed by
// the Helper Tests fixture hello4 (`otool -fv`).
private let cpuSubtypeARM64EX1: cpu_subtype_t = 12

func mach_task_self() -> mach_port_t {
	unsafe mach_task_self_
}

struct MainView: View {
	struct ArchitectureInfo {
		let name: String
		let displayName: String
		let cpuType: cpu_type_t
		let cpuSubtype: cpu_subtype_t
	}

	@State private var languages: [LanguageSetting] = []
	@State private var architectures: [ArchitectureSetting] = []
	@State private var languageFilter = ""
	@State private var architectureFilter = ""
	@State private var selectedTab = Tab.languages
	/// Incremented to put the keyboard focus in the search field.
	@State private var searchFocusRequest = 0
	@State private var currentArchitecture = "unknown"
	@State private var showingRemoveLanguagesAlert = false
	@State private var showingUnchangedAlert = false
	@State private var showingAllArchitecturesAlert = false

	@State private var blacklist: [BlacklistEntry] = []

	@State private var helperTask = HelperTask()

	private let sipProtectedLocations = ["/System", "/bin"]

	private let logger = Logger()

	private var roots: [Root] {
		// A bundle the user opened with Monolingual is the only root, so that a removal
		// started from it covers nothing else.
		if let application = (NSApp.delegate as? AppDelegate)?.openedApplication {
			return [application]
		} else {
			if let pref = UserDefaults.standard.array(forKey: "Roots") as? [[String: AnyObject]] {
				return pref.map { Root(dictionary: $0) }
			} else {
				return [Root]()
			}
		}
	}

	/// A removal keeps the progress sheet up for as long as it runs, and the alert that
	/// reports how it ended stays on it until the user acknowledges it. A removal that
	/// failed for a reason the app reports itself leaves both off, which takes the sheet
	/// down on its own.
	private var isShowingProgress: Binding<Bool> {
		Binding(get: { helperTask.isRunning || helperTask.outcome != nil },
		        set: { isPresented in
			if !isPresented {
				helperTask.outcome = nil
			}
		})
	}

	/// Whether the alert about an unavailable helper is up; dismissing it clears the failure.
	private var isShowingInstallationFailure: Binding<Bool> {
		Binding(get: { helperTask.installationFailure != nil },
		        set: { isPresented in
			if !isPresented {
				helperTask.installationFailure = nil
			}
		})
	}

	/// The rows the filter leaves visible. A filter only ever hides rows: what is checked
	/// stays checked, and a removal still covers the whole list.
	private func filtered<T>(_ items: [T], by query: String, named name: (T) -> String) -> [T] {
		// A stray space is easy to leave behind when pasting, and it matches nothing.
		let query = query.trimmingCharacters(in: .whitespaces)
		guard !query.isEmpty else { return items }
		// `localizedStandardContains` is the comparison the Finder uses: case- and
		// diacritic-insensitive, and aware of the user's locale.
		return items.filter { name($0).localizedStandardContains(query) }
	}

	private var filteredLanguages: [LanguageSetting] {
		filtered(languages, by: languageFilter) { $0.displayName }
	}

	private var filteredArchitectures: [ArchitectureSetting] {
		filtered(architectures, by: architectureFilter) { $0.displayName }
	}

	func removeArchitectures() {
		log.open()

		let version = (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "vUNKNOWN"
		log.message("Monolingual \(version) started\n")
		log.message("Removing architectures:")

		let archs = architectures.filter(\.enabled).map(\.name)
		for arch in archs {
			log.message(" \(arch)", timestamp: false)
		}

		log.message("\nModified files:\n")

		let numArchs = archs.count
		if numArchs == 0 {
			// Asking to remove nothing is answered the same way as a removal that turns out to
			// have nothing to do: say so instead of doing nothing at all.
			showingUnchangedAlert = true
			log.close()
		} else if numArchs == architectures.count {
			showingAllArchitecturesAlert = true
			log.close()
		} else {
			// start things off if we have something to remove!
			let roots = roots

			let includes = roots.filter(\.architectures).map(\.path)
			let excludes = roots.filter { !$0.architectures }.map(\.path) + sipProtectedLocations
			let bl = Set<String>(blacklist.filter(\.architectures).map(\.bundle))

			for item in bl {
				logger.info("Blocking \(item, privacy: .public)")
			}
			for include in includes {
				logger.info("Adding root \(include, privacy: .public)")
			}
			for exclude in excludes {
				logger.info("Excluding root \(exclude, privacy: .public)")
			}

			var request = HelperRequest()
			request.doStrip = UserDefaults.standard.bool(forKey: "Strip")
			request.bundleBlacklist = bl
			request.includes = includes
			request.excludes = excludes
			request.thin = archs

			helperTask.checkAndRunHelper(arguments: request, removal: .architectures)
		}
	}

	private func checkAndRemove() {
		if checkRoots() {
			removeLanguages()
		}
	}

	private func checkRoots() -> Bool {
		var languageEnabled = false
		let roots = roots
		for root in roots where root.languages {
			languageEnabled = true
			break
		}

		if !languageEnabled {
			showingUnchangedAlert = true
		}

		return languageEnabled
	}

	private func removeLanguages() {
		log.open()
		let version = (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "vUNKNOWN"
		log.message("Monolingual \(version) started\n")
		log.message("Removing languages:")

		let roots = roots

		let includes = roots.filter(\.languages).map(\.path)
		let excludes = roots.filter { !$0.languages }.map(\.path) + sipProtectedLocations
		let bl = blacklist.filter(\.languages).map(\.bundle)

		for item in bl {
			logger.info("Blacklisting \(item, privacy: .public)")
		}
		for include in includes {
			logger.info("Adding root \(include, privacy: .public)")
		}
		for exclude in excludes {
			logger.info("Excluding root \(exclude, privacy: .public)")
		}

		var rCount = 0
		var folders = Set<String>()
		// Protected localizations are left out even if one were somehow checked.
		for language in languages where language.enabled && !language.isProtected {
			for path in language.folders {
				folders.insert(path)
				log.message(" \(path)", timestamp: false)
				rCount += 1
			}
		}
		if UserDefaults.standard.bool(forKey: "NIB") {
			folders.insert("designable.nib")
		}

		log.message("\n", timestamp: false)
		if UserDefaults.standard.bool(forKey: "Trash") {
			log.message("Trashed files:\n")
		} else {
			log.message("Deleted files:\n")
		}

		if rCount > 0 {
			// start things off if we have something to remove!

			var request = HelperRequest()
			request.trash = UserDefaults.standard.bool(forKey: "Trash")
			request.uid = getuid()
			request.bundleBlacklist = Set<String>(bl)
			request.includes = includes
			request.excludes = excludes
			request.directories = folders

			helperTask.checkAndRunHelper(arguments: request, removal: .languages(languages))
		} else {
			// Same as on the architectures tab: nothing selected is reported rather than
			// passing for a run that did something.
			showingUnchangedAlert = true
			log.close()
		}
	}

	private func loadData() {
		let currentLocale = Locale.current

		// never check the user's preferred languages, English and the user's locale by default
		let userLanguages = Set<String>(Locale.preferredLanguages.flatMap { language -> [String] in
			let components = language.components(separatedBy: "-")
			if components.count == 1 {
				return [components[0]]
			} else {
				return [components[0], components.joined(separator: "_")]
			}
		} + ["en", currentLocale.identifier, currentLocale.language.languageCode?.identifier ?? ""])

		let knownLocales: [String] = ["ach", "an", "ast", "ay", "bi", "co", "fur", "gd", "gn", "ia", "jv", "ku", "la", "mi", "md", "no", "oc", "qu", "sa", "sd", "se", "su", "tet", "tk_Cyrl", "tl", "tlh", "tt", "wa", "yi", "zh_CN", "zh_TW"]
		// add some known locales not contained in availableLocaleIdentifiers
		let availableLocalizations = Set<String>(Locale.availableIdentifiers + knownLocales)

		let systemLocale = Locale(identifier: "en_US_POSIX")
		languages = [String](availableLocalizations).map { localeIdentifier -> LanguageSetting in
			var folders = ["\(localeIdentifier).lproj"]
			let locale = Locale(identifier: localeIdentifier)
			if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
				if let variantCode = locale.variant?.identifier {
					// e.g. en_US_POSIX
					folders.append("\(language)-\(region)_\(variantCode).lproj")
					folders.append("\(language)_\(region)_\(variantCode).lproj")
				} else if let script = locale.language.script?.identifier {
					// e.g. zh_Hans_SG
					folders.append("\(language)-\(script)-\(region).lproj")
					folders.append("\(language)_\(script)_\(region).lproj")
				} else {
					folders.append("\(language)-\(region).lproj")
					folders.append("\(language)_\(region).lproj")
				}
			} else if let language = locale.language.languageCode?.identifier, let script = locale.language.script?.identifier {
				// e.g. zh_Hans
				folders.append("\(language)-\(script).lproj")
				folders.append("\(language)_\(script).lproj")
			} else if let displayName = systemLocale.localizedString(forIdentifier: localeIdentifier) {
				folders.append("\(displayName).lproj")
			}
			// Deliberately not NSLocalizedString: the key is assembled at runtime, and the
			// string extractor warns about a key it cannot resolve. The handful of these
			// that are needed (locale_md, for one) are kept by hand in Localizable.xcstrings.
			let key = "locale_" + localeIdentifier
			let displayName = currentLocale.localizedString(forIdentifier: localeIdentifier) ?? Bundle.main.localizedString(forKey: key, value: nil, table: nil)
			var setting = LanguageSetting(enabled: !userLanguages.contains(localeIdentifier), folders: folders, displayName: displayName)
			// A protected localization starts out unchecked as well as locked, whatever the
			// user's languages are.
			if setting.isProtected {
				setting.enabled = false
			}
			return setting
		}.sorted { $0.displayName < $1.displayName }

		let archs = [
			ArchitectureInfo(name: "arm", displayName: "ARM", cpuType: CPU_TYPE_ARM, cpuSubtype: CPU_SUBTYPE_ARM_ALL),
			ArchitectureInfo(name: "arm64", displayName: "ARM64", cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64_ALL),
			ArchitectureInfo(name: "arm64v8", displayName: "ARM64v8", cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64_V8),
			ArchitectureInfo(name: "arm64e", displayName: "ARM64E", cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64E),
			// Reports its own subtype on the Macs that support it, so without a row of its own
			// the current architecture there would be "unknown".
			ArchitectureInfo(name: "arm64e.x1", displayName: "ARM64E.x1", cpuType: CPU_TYPE_ARM64, cpuSubtype: cpuSubtypeARM64EX1),
			ArchitectureInfo(name: "ppc", displayName: "PowerPC", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_ALL),
			ArchitectureInfo(name: "ppc750", displayName: "PowerPC G3", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_750),
			ArchitectureInfo(name: "ppc7400", displayName: "PowerPC G4", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_7400),
			ArchitectureInfo(name: "ppc7450", displayName: "PowerPC G4+", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_7450),
			ArchitectureInfo(name: "ppc970", displayName: "PowerPC G5", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_970),
			ArchitectureInfo(name: "ppc64", displayName: "PowerPC 64-bit", cpuType: CPU_TYPE_POWERPC64, cpuSubtype: CPU_SUBTYPE_POWERPC_ALL),
			ArchitectureInfo(name: "ppc970-64", displayName: "PowerPC G5 64-bit", cpuType: CPU_TYPE_POWERPC64, cpuSubtype: CPU_SUBTYPE_POWERPC_970),
			ArchitectureInfo(name: "x86", displayName: "Intel 32-bit", cpuType: CPU_TYPE_X86, cpuSubtype: CPU_SUBTYPE_X86_ALL),
			ArchitectureInfo(name: "x86_64", displayName: "Intel 64-bit", cpuType: CPU_TYPE_X86_64, cpuSubtype: CPU_SUBTYPE_X86_64_ALL),
			ArchitectureInfo(name: "x86_64h", displayName: "Intel 64-bit (Haswell)", cpuType: CPU_TYPE_X86_64, cpuSubtype: CPU_SUBTYPE_X86_64_H)
		]

		var infoCount = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size) // HOST_BASIC_INFO_COUNT
		let hostInfoPointer = host_basic_info_t.allocate(capacity: 1)
		// `allocate` hands back uninitialized memory, and it is `host_info` that fills it in, so a
		// call that fails would leave the read below reading whatever happened to be there.
		unsafe hostInfoPointer.initialize(to: host_basic_info_data_t())
		let myMachHostSelf = mach_host_self()
		let ret = unsafe hostInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { pointer in
				unsafe host_info(myMachHostSelf, HOST_BASIC_INFO, pointer, &infoCount)
		}
		mach_port_deallocate(mach_task_self(), myMachHostSelf)
		var hostInfo = unsafe hostInfoPointer.move()
		unsafe hostInfoPointer.deallocate()

		if hostInfo.cpu_type == CPU_TYPE_X86 {
			// fix host_info
			var x8664: Int = 0
			var x8664Size = Int(MemoryLayout<Int>.size)
			let sysctlResult = unsafe sysctlbyname("hw.optional.x86_64", &x8664, &x8664Size, nil, 0)
			if sysctlResult == 0 {
				if x8664 != 0 {
					hostInfo = host_basic_info_data_t(
						max_cpus: hostInfo.max_cpus,
						avail_cpus: hostInfo.avail_cpus,
						memory_size: hostInfo.memory_size,
						cpu_type: CPU_TYPE_X86_64,
						cpu_subtype: (hostInfo.cpu_subtype == CPU_SUBTYPE_X86_64_H) ? CPU_SUBTYPE_X86_64_H : CPU_SUBTYPE_X86_64_ALL,
						cpu_threadtype: hostInfo.cpu_threadtype,
						physical_cpu: hostInfo.physical_cpu,
						physical_cpu_max: hostInfo.physical_cpu_max,
						logical_cpu: hostInfo.logical_cpu,
						logical_cpu_max: hostInfo.logical_cpu_max,
						max_mem: hostInfo.max_mem
					)
				}
			}
		}

		var curArch = NSLocalizedString("unknown", comment: "")
		architectures = archs.map { arch in
			let enabled = ret == KERN_SUCCESS && hostInfo.cpu_type != arch.cpuType
			let architecture = ArchitectureSetting(enabled: enabled, name: arch.name, displayName: arch.displayName)
			if hostInfo.cpu_type == arch.cpuType, hostInfo.cpu_subtype == arch.cpuSubtype {
				curArch = arch.displayName
			}
			return architecture
		}
		currentArchitecture = curArch

		// load blacklist from asset catalog
		if let blacklist = NSDataAsset(name: "blacklist") {
			let decoder = PropertyListDecoder()
			self.blacklist = (try? decoder.decode([BlacklistEntry].self, from: blacklist.data)) ?? []
		}
	}

	private enum Tab: Hashable {
		case languages
		case architectures
	}

	/// The filter of whichever tab is showing. One search field serves both tabs, so that it
	/// is a single toolbar item of the window rather than one per tab.
	private var activeFilter: Binding<String> {
		Binding(get: { selectedTab == .languages ? languageFilter : architectureFilter },
		        set: { if selectedTab == .languages { languageFilter = $0 } else { architectureFilter = $0 } })
	}

	/// Height of the row under each tab's table. Fixed, so that the row cannot make one tab's
	/// table shorter than the other's: left to their contents, the two rows differ by 3 points.
	/// 20 is the height the languages tab's row has on its own.
	private static let footerHeight: CGFloat = 20

	/// Width of the toolbar search field. An ordinary toolbar item is dropped whole rather than
	/// shrunk when the toolbar runs out of room, so this has to fit beside the tab picker: at the
	/// window's 550 points, 233 is the widest that does, and this leaves 5 points of slack.
	private static let searchFieldWidth: CGFloat = 228

	/// One tab's contents. Both tabs go through here, so that their tables come out the same
	/// size: the heading, the table taking the rest of the space, and a single-line row below it.
	private func tabPane(@ViewBuilder table: () -> some View, @ViewBuilder footer: () -> some View) -> some View {
		VStack(alignment: .leading) {
			Text("Select the items you wish to remove:")
			table()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			HStack {
				footer()
			}
			.frame(height: Self.footerHeight)
		}
		.padding(12)
	}

	private var languagesTab: some View {
		tabPane {
			// See `LanguageSetting.protectedFolders` for the rows that cannot be checked.
			CheckboxTable(rows: filteredLanguages.map {
				CheckboxTableRow(id: $0.id, title: $0.displayName, isOn: $0.enabled, isEnabled: !$0.isProtected)
			}) { id, isOn in
				// Looked up in the unfiltered list: the filter hides rows, it does not
				// renumber them, and a toggle has to keep writing through to the setting
				// it belongs to.
				if let index = languages.firstIndex(where: { $0.id == id }) {
					languages[index].enabled = isOn
				}
			}
			.outlinedTable()
			.overlay {
				if filteredLanguages.isEmpty {
					Text("No matches").foregroundStyle(.secondary)
				}
			}
		} footer: {
			Spacer()
			Button("Remove…") {
				// Display a warning first
				showingRemoveLanguagesAlert = true
			}
			.alert("Are you sure you want to remove these languages?", isPresented: $showingRemoveLanguagesAlert) {
				Button("Cancel", role: .cancel) {}
				Button("Continue", role: .destructive) {
					checkAndRemove()
				}
			} message: {
				Text("You will not be able to restore them without reinstalling macOS.")
			}
		}
	}

	private var architecturesTab: some View {
		tabPane {
			CheckboxTable(rows: filteredArchitectures.map {
				CheckboxTableRow(id: $0.id, title: $0.displayName, isOn: $0.enabled)
			}) { id, isOn in
				if let index = architectures.firstIndex(where: { $0.id == id }) {
					architectures[index].enabled = isOn
				}
			}
			.outlinedTable()
			.overlay {
				if filteredArchitectures.isEmpty {
					Text("No matches").foregroundStyle(.secondary)
				}
			}
		} footer: {
			// One line, like the languages tab's row, so that both tables are the same height.
			Text("Current architecture: \(currentArchitecture)")
				.lineLimit(1)
			Spacer()
			Button("Remove…") {
				removeArchitectures()
			}
		}
	}

	var body: some View {
		TabView(selection: $selectedTab) {
			languagesTab
				.tabItem {
					Text("Languages")
				}
				.tag(Tab.languages)
			architecturesTab
				.tabItem {
					Text("Architectures")
				}
				.tag(Tab.architectures)
		}
		.padding(12)
		// A plain search field rather than `.searchable`, whose toolbar field collapses whenever
		// it loses focus. See ToolbarSearchField.
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				ToolbarSearchField(text: activeFilter, prompt: NSLocalizedString("Search", comment: ""), focusRequest: searchFocusRequest)
					.frame(width: Self.searchFieldWidth)
			}
		}
		// ⌘F puts the focus in the field, as it did with `.searchable`.
		.background {
			Button("") { searchFocusRequest += 1 }
				.keyboardShortcut("f", modifiers: .command)
				// Invisible but present: a `.hidden()` button does not take its shortcut.
				.opacity(0)
				.frame(width: 0, height: 0)
				.accessibilityHidden(true)
		}
		// 550 points holds the tab picker at its full size beside the search field; see
		// `searchFieldWidth`.
		.frame(width: 550, height: 450)
		// Attached here rather than to the button that starts a removal, so that the sheet
		// reports a removal from either tab. The architecture tab has no confirmation alert
		// of its own, but it does produce an outcome like any other run.
		.sheet(isPresented: isShowingProgress) {
			ProgressView(task: helperTask)
		}
		// Neither of these is about the languages tab alone: a removal that covers nothing and
		// a removal of every architecture are both decided across tabs, so they present on top
		// of whichever one the user is on.
		.alert("Monolingual is stopping without making any changes.", isPresented: $showingUnchangedAlert) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("Your OS has not been modified.")
		}
		.alert("Removing all architectures will make macOS inoperable.", isPresented: $showingAllArchitecturesAlert) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("Please keep at least one architecture and try again.")
		}
		.alert(helperTask.installationFailure?.title ?? "", isPresented: isShowingInstallationFailure) {
			if helperTask.installationFailure?.canOpenSystemSettings == true {
				Button("Open System Settings") {
					HelperInstaller.openSystemSettingsLoginItems()
				}
			}
			Button("OK", role: .cancel) {}
		} message: {
			Text(helperTask.installationFailure?.message ?? "")
		}
		.task {
			// The window opens with the search field ready for typing, which is the behavior
			// the list had before 2.0 and the reason the filter is here at all: open the app,
			// type a language, watch it narrow.
			searchFocusRequest += 1
			loadData()
			// The blacklist is the one bundled in the asset catalog: the app makes no network
			// requests.
		}
	}

}

struct MainView_Previews: PreviewProvider {
	static var previews: some View {
		MainView()
	}
}

extension View {
	/// The outline the app's tables share: a 1-point quaternary stroke around slightly rounded
	/// corners, in place of the square, darker bezel of `.bordered`.
	func outlinedTable() -> some View {
		let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
		return clipShape(shape)
			.overlay(shape.strokeBorder(.quaternary, lineWidth: 1))
	}
}
