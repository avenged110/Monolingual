// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  Preferences.swift
//  Monolingual
//
//  Created by Ingmar Stein on 19.09.21.
//  Copyright © 2021 Ingmar Stein. All rights reserved.
//

import SwiftUI

struct PreferencesView: View {
	@State private var roots: [Root] = []
	@State private var sortOrder = [KeyPathComparator(\Root.path)]
	@State private var selection: Root.ID?
	@AppStorage("Trash") var trash: Bool = false
	@AppStorage("Strip") var strip: Bool = false
	/// The settings window, which the folder panel is attached to as a sheet.
	@State private var hostWindow: NSWindow?
	@State private var showingResetConfirmation = false

	var body: some View {
		VStack(alignment: .leading) {
			// No box around the table and its buttons: they take the window's width less its
			// padding, like everything else in it.
			Text("Directories:")
			VStack(alignment: .leading, spacing: 8) {
				Table(roots, selection: $selection, sortOrder: $sortOrder) {
					TableColumn("Languages") { root in
						if let i = roots.firstIndex(where: { $0.id == root.id }) {
							Toggle(isOn: $roots[i].languages) {}.toggleStyle(.checkbox)
						}
					}
					.width(70)
					TableColumn("Architectures") { root in
						if let i = roots.firstIndex(where: { $0.id == root.id }) {
							Toggle(isOn: $roots[i].architectures) {}.toggleStyle(.checkbox)
						}
					}
					.width(85)
					TableColumn("Path", value: \.path)
				}
				.outlinedTable()
				HStack {
					Button {
						addDirectories()
					} label: {
						addRemoveLabel("plus")
					}
					.help("Add a directory")
					Button {
						if let selection = selection, let i = roots.firstIndex(where: { $0.id == selection }) {
							roots.remove(at: i)
						}
					} label: {
						addRemoveLabel("minus")
					}
					.help("Remove the selected directory")
					.disabled(selection == nil)
					Spacer()
					Button("Reset to Defaults") {
						showingResetConfirmation = true
					}
					.disabled(roots == Root.defaultRoots)
					.alert("Reset the directories to their defaults?", isPresented: $showingResetConfirmation) {
						Button("Cancel", role: .cancel) {}
						Button("Reset", role: .destructive) {
							roots = Root.defaultRoots
						}
					} message: {
						Text("The list will contain only /Applications and /Library again. Any directories you added are removed from it.")
					}
				}
			}
			Divider()
				.padding(.vertical, 4)
			Toggle("Move language files to Trash", isOn: $trash)
			Toggle("Strip debug info when removing architectures", isOn: $strip)
		}
		.padding(16)
		.frame(width: 450, height: 300)
		.background(HostingWindowReader { hostWindow = $0 })
		.onAppear {
			if let pref = UserDefaults.standard.array(forKey: "Roots") as? [[String: Any]] {
				roots = pref.map { Root(dictionary: $0) }
			} else {
				roots = Root.defaultRoots
			}
		}
		.onChange(of: roots) { _, newRoots in
			let dicts = newRoots.map { root in
				["Path": root.path, "Languages": root.languages, "Architectures": root.architectures]
			}
			UserDefaults.standard.set(dicts, forKey: "Roots")
		}
	}

	/// Asks for directories to add, in the shared folder panel, as a sheet on the settings window.
	private func addDirectories() {
		// Deferred to the next run-loop turn, as Film Tracker does, so that the panel's focus
		// changes do not land in the middle of a view update.
		Task { @MainActor in
			let configuration = OpenPanelConfiguration(canChooseFiles: false,
			                                           canChooseDirectories: true,
			                                           allowsMultipleSelection: true,
			                                           treatsFilePackagesAsDirectories: true,
			                                           message: "Select directories to process",
			                                           prompt: "Add")
			guard case let .urls(urls) = await OpenPanelPresenter.present(configuration: configuration, attachedTo: hostWindow) else {
				return
			}
			// A directory is identified by its path, so one that is already listed is not added
			// again: two rows with the same identity confuse the table.
			for url in urls where !roots.contains(where: { $0.path == url.path }) {
				roots.append(Root(path: url.path, languages: true, architectures: true))
			}
		}
	}

	/// The symbol of the + or − button, in a frame both share so the two come out the same
	/// width: the glyphs alone differ.
	private func addRemoveLabel(_ systemName: String) -> some View {
		Image(systemName: systemName)
			.frame(width: 14, height: 14)
	}
}

struct PreferencesView_Previews: PreviewProvider {
	static var previews: some View {
		PreferencesView()
	}
}
