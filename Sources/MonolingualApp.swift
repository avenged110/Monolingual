// Copyright © 2026 avenged110.
// Portions Copyright © 2014–2026 Ingmar Stein (Monolingual, https://github.com/IngmarStein/Monolingual).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Monolingual and modified by avenged110, 2026.
//
//  App.swift
//  App
//
//  Created by Ingmar Stein on 02.10.21.
//  Copyright © 2021 Ingmar Stein. All rights reserved.
//

import SwiftUI

@main
struct MonolingualApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
	var body: some Scene {
		// One fixed-size window: MainView sets the frame, FixedWindowConfigurator makes zoom
		// inert and keeps the window out of full screen and tabs.
		Window("Monolingual", id: "main") {
			MainView()
				// A background, so the zero-size probe never takes a click.
				.background(FixedWindowConfigurator())
		}
		.windowResizability(.contentSize)
		// Spelled out so the toolbar keeps the regular unified height with the title shown.
		.windowToolbarStyle(.unified(showsTitle: true))
		.commands {
			HelpCommands()
		}
		Settings {
			PreferencesView()
				.background(FixedWindowConfigurator(title: "Monolingual Settings"))
		}
		.windowResizability(.contentSize)
	}
}
