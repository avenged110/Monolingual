# Monolingual customizations

Every way this project differs from upstream Monolingual, so that the same changes can be
re-applied to a newer upstream release.

- **Upstream baseline:** Monolingual 2.0.2 (`IngmarStein/Monolingual`, `main` as of 2026-10-19),
  reference copy at `~/Desktop/Monolingual-main`.
- **Exact textual diff:** [`upstream-2.0.2-to-custom.patch`](upstream-2.0.2-to-custom.patch)
  (`diff -ruN` baseline → this project; excludes `*.lproj`, images and the binary blacklist
  plist). It also carries the baseline's text, so it still works if the Desktop copy is gone.
- **Keep this file current.** Any change to the project that departs from upstream gets an entry
  here (and the patch is regenerated — see *Maintenance*) in the same session.

Re-apply changes **by intent, not by line**: each entry says what the change is for, so that it
can be carried over when upstream has rewritten the code it touches. When upstream's new code
makes an entry unnecessary, conflicting or ambiguous, stop and ask the user rather than guessing.

---

## C1. Runs on macOS 15.6 (upstream: macOS 27), builds with Xcode 26

Goal: deploy to macOS 15.6 on Apple silicon, with the macOS 26 SDK.

- `project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET = 15.6` at the **project** level and on **every**
  target (Monolingual, Helper, Helper Tests, LipoCore, HelperShared, lipo). Upstream had 27.0 on
  targets and 26.0 at project level.
- `Info.plist`: `LSMinimumSystemVersion` = `$(MACOSX_DEPLOYMENT_TARGET)` (was literal `27.0`).
- `Package.swift`: `platforms: [.macOS("15.6")]`.
- `scripts/select-xcode.sh`: `MIN_MAJOR` default 26 (and comment); `scripts/build.sh` comment.
- `CPU_SUBTYPE_ARM64E_X1` exists only in the macOS 27 SDK → defined locally as
  `cpuSubtypeARM64EX1: cpu_subtype_t = 12` in `lipo/lipo.swift` (internal `let`),
  `Sources/MainView.swift` (private), `Helper/Tests/Helper_Tests.swift` (local in
  `testRemoveArm64eX1`), and used in place of the constant. If upstream's SDK floor rises to 27,
  this can go — ask.
- **macOS 26-only XPC APIs behind `#available(macOS 26.0, *)`, with a macOS 15 path:**
  - `HelperProtocol.swift`: `appPeerRequirement` / `helperPeerRequirement` marked
    `@available(macOS 26.0, *)`; new `legacyAppPeerRequirement(appBundle:)` (team-based
    requirement string `anchor apple generic and identifier "<app id>" and certificate
    leaf[subject.OU] = "<team>"`, or for team-less/ad-hoc builds the app bundle's designated
    requirement) and private `ownTeamIdentifier()`; `import Security`.
  - `Helper.swift`: `listener`/`clientSession` become `AnyObject?`; `progressSession` becomes a
    new `ProgressChannel` enum (`.session(XPCSession)` / `.legacy(xpc_connection_t)`, with
    `send` and `cancel`). `run()` uses `XPCListener` on 26+, else `listenLegacy()`, which serves
    the Mach service via `xpc_connection_create_mach_service` and sets
    `xpc_connection_set_peer_code_signing_requirement` on every peer, replying via
    `xpc_dictionary_create_reply`. `openProgressConnection` on <26 extracts the raw endpoint
    and connects with the C API plus the same requirement. If no requirement can be computed,
    the helper refuses to serve (security-critical — never drop this check).
  - `Sources/HelperTask.swift`: `XPCSession(machService:…requirement:)` only on 26+; plain
    initializer otherwise; `setPeerRequirement` on the progress listener only on 26+.
- **Security note to preserve:** with an ad-hoc signature the helper accepts only the exact app
  build it was installed with (cdhash). Documented in AGENTS.md *Notes*.

## C2. No network access, no Sparkle

Goal: the app never touches the network and has no updater.

- Remove the Sparkle package reference, product dependency and framework link from
  `project.pbxproj`; delete `Package.resolved` (root and
  `project.xcworkspace/xcshareddata/swiftpm/`).
- `MonolingualApp.swift`: drop `import Sparkle`, `SPUStandardUpdaterController`, the `init`, and
  the "Check for Updates…" command.
- `Info.plist`: remove `SUEnableAutomaticChecks`, `SUFeedURL`, `SUPublicEDKey`,
  `SUEnableInstallerLauncherService`.
- `PreferencesView.swift`: remove the "Automatically check for updates" toggle and its
  `@AppStorage("SUEnableAutomaticChecks")`.
- `MainView.swift`: remove the remote blacklist download (`URLSession` fetch of
  `blocklist.plist`, `blocklistURL`, `blocklistHost`); leave a comment that the bundled list is
  the one used.
- Release tooling: delete `appcast.xml.tmpl`; `scripts/release.sh` loses the "Signing the update
  feed" section and Sparkle mentions; `.github/workflows/release.yml` drops `SPARKLE_ED_KEY` and
  the `appcast.xml` asset; `.gitignore` drops `appcast.xml`; `scripts/build.sh` comment reworded;
  `release.markdown` loses the appcast/website/macupdate steps ("There is no update feed").
- **On a new upstream:** check for *any* new network use (grep `URLSession`, `URL(string: "http`,
  `NSURLConnection`, new packages) and remove it too — report what was found.

## C3. No third-party dependencies (swift-argument-parser removed)

- `Package.swift` and `project.pbxproj`: remove swift-argument-parser.
- `Helper/Sources/main.swift`: `ParsableArguments` replaced by a hand-written `Options` struct
  with `init(_ arguments: ArraySlice<String>)`, a `usageText`, and `fail(_:) -> Never`. Same
  options as upstream (`-v -n -s -t` flags; `-i -x -b -d -a` repeatable values, also
  `--name=value`; `-h`). A value starting with `-` is a missing value. Exit 1 on bad usage.
- **On a new upstream:** if upstream adds/changes CLI options, add them to the `flags`/`lists`
  tables, `usageText`, and the README table (C9).

## C4. English only

- Delete `Resources/{de,el,es,fa,fr,hr,it,ja,ko,nl,pl,ro,ru,sk,sv,tr}.lproj` (and any new
  non-English `.lproj`, e.g. a future `zh-Hans`) and their `PBXFileReference`/variant-group
  entries; `knownRegions = (en, Base)`.
- Remove `LEESMIJ.rtfd`, `Leggimi.rtfd`, `Lies-mich.rtfd`, `LisezMoi.rtfd` from the project and
  the Resources build phase (the folders are still on disk in `Resources/`, unreferenced).
- `Localizable.xcstrings`: only `en` localizations. Keep the `locale_*` keys (they provide
  language display names). Add new English keys used by the custom UI (see C5–C7).

## C5. "Blacklist" terminology (upstream says "blocklist")

Upstream renamed blacklist → blocklist; this project reverts that everywhere:

- Files: `Sources/BlocklistEntry.swift` → `BlacklistEntry.swift` (type `BlacklistEntry`);
  asset `Media.xcassets/blocklist.dataset/blocklist.plist` → `blacklist.dataset/blacklist.plist`
  (content identical; `Contents.json` filename updated); `util/create_adobe_blocklist.sh` →
  `create_adobe_blacklist.sh`. pbxproj file refs renamed (same object IDs).
- Identifiers: `bundleBlocklist` → `bundleBlacklist` (`HelperRequest`), `isDirectoryBlocklisted`,
  `isFileBlocklisted`, `addCodeResourcesToBlocklist`, `addFileDictionaryToBlocklist`,
  `fileBlocklist` → `…Blacklist…`; `MainView` `blocklist` state; `NSDataAsset(name: "blacklist")`.
- Strings/comments/logs: "Blocklisting" → "Blacklisting"; tests (`blocklisted` →
  `blacklisted`, `com.test.blacklisted`); `util/uniq.swift`; README and `README.rtfd/TXT.rtf`
  changelog lines.
- **Caution:** `HelperRequest` is JSON over XPC — the key name changes the wire format. App and
  helper are always built together, so that is fine; just rename consistently in both.
- **On a new upstream:** case-insensitive grep for `blocklist` across all text files and rename
  every hit.

## C6. Fixed-size, single main window

- New `Sources/FixedWindowConfigurator.swift` (GPL header, avenged110): an
  `NSViewRepresentable` that clears `.resizable` (and keeps it cleared via KVO), disables full
  screen and tabbing, and optionally forces a window title. Also defines `WindowProbeView`.
- `MonolingualApp.swift`: `WindowGroup` → `Window("Monolingual", id: "main")` with
  `.background(FixedWindowConfigurator())`, `.windowResizability(.contentSize)`,
  `.windowToolbarStyle(.unified(showsTitle: true))`. Settings scene:
  `.background(FixedWindowConfigurator(title: "Monolingual Settings"))` and
  `.windowResizability(.contentSize)`; upstream's `SettingsWindowAdjuster` deleted.
- `FixedWindowConfigurator` makes every change to the window one run-loop turn later
  (`DispatchQueue.main.async`), and sets the style mask only when `.resizable` is actually set.
  The probe is attached during `NSHostingView.layout()`, and changing the mask there relayouts
  the window, which AppKit logs as layout recursion ("It's not legal to call
  -layoutSubtreeIfNeeded on a view which is already being laid out").
- `MainView`: `.frame(width: 550, height: 450)` (replaces `minWidth: 640`). 550 rather than the
  minimum 548 for a round number; `searchFieldWidth` stays 228 (233 would be the widest that fits). The Settings window
  is 450 × 300 (`PreferencesView`, see C9); the docs say the same.

## C7. Main window UI rework (`Sources/MainView.swift`)

- New `Sources/ToolbarSearchField.swift`: an always-expanded `NSSearchField` in a plain
  `ToolbarItem(placement: .primaryAction)`, width `searchFieldWidth = 228`. Replaces the two
  `.searchable(placement: .toolbar)` modifiers (which collapse on focus loss). One field serves
  both tabs via `activeFilter` bound to `selectedTab` (`enum Tab`). `⌘F` via an invisible
  zero-size button (`searchFocusRequest` counter replaces `@FocusState`); focus requested on
  appear.
- Tabs factored into `languagesTab` / `architecturesTab` built through `tabPane(table:footer:)`
  with fixed `footerHeight = 20`, padding 12, so both tables are the same size. Architecture
  footer text `.lineLimit(1)`.
- Buttons "Remove …" → "Remove…" (no space).
- New `View.outlinedTable()` extension (end of MainView.swift): inset table style with
  alternating rows, clipped to a 6-pt continuous rounded rectangle with a 1-pt quaternary
  stroke. Used by both main tables and the Settings table.
- Installation-failure alert binding pulled out into `isShowingInstallationFailure`.

## C8. Protected English localizations (`Sources/LanguageSetting.swift`)

- `static let protectedFolders = ["en.lproj", "en_US.lproj", "en_US_POSIX.lproj"]` and
  `var isProtected`. Upstream only disabled `en.lproj` and left "U.S. English" removable.
- `MainView`: protected settings start unchecked (`setting.enabled = false`), their checkbox is
  `.disabled(setting.isProtected)`, and `checkAndRemove` skips them
  (`where language.enabled && !language.isProtected`).

## C9. Settings window rework (`Sources/PreferencesView.swift`)

- No `GroupBox`; a "Directories:" label, the table with `.outlinedTable()`, fixed column widths
  70 (Languages) and 85 (Architectures), Path column flexible.
- +/− buttons use SF Symbols `plus`/`minus` in a shared 14×14 frame, with `.help` tooltips
  "Add a directory" / "Remove the selected directory".
- "Standard" → "Reset to Defaults", disabled when already default, with a destructive
  confirmation alert ("Reset the directories to their defaults?" / "Reset" / message listing
  /Applications and /Library).
- `Divider()` before the two toggles. `.padding(16)`, `.frame(width: 450, height: 300)`.
- Adding directories uses the shared open panel: new `Sources/SharedOpenPanel.swift`
  (`OpenPanelConfiguration`, `OpenPanelSelection`, `OpenPanelPresenter`, `HostingWindowReader`;
  adapted from the user's Film Tracker `GlobalUtilities.swift`, plus
  `treatsFilePackagesAsDirectories`). Presented as a sheet on the Settings window
  (`hostWindow` via `HostingWindowReader`), deferred a run-loop turn, message "Select
  directories to process", prompt "Add", 600×400 non-resizable, starts at ~/Desktop.

## C10. Strict Swift settings and warning-free build

- Project level: `SWIFT_STRICT_MEMORY_SAFETY = YES`,
  `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY = YES`,
  `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` (targets inherit).
- Consequences throughout the code: `unsafe` on every unsafe expression (getxattr,
  `withUnsafeBytes`, `Sec*` calls with inout, `String(format:)`, `String(cString:)`, `mkstemp`,
  `trashItem`/`replaceItem` with `resultingItemURL`, `fileManager.delegate`, `mach_task_self_`,
  host_info, sysctlbyname, `logFile?.write` → `_ = unsafe …`), and `Error` → `any Error`.
- `XPCDictionary.setData`: handles an empty buffer with no base address.
- **On a new upstream:** build, then fix every new strict-safety/existential warning the same
  way; the build must stay warning-free.

## C11. Build/signing settings (`project.pbxproj`)

- Monolingual target: `ARCHS = arm64`, `MARKETING_VERSION = 2.0.2`,
  `CURRENT_PROJECT_VERSION = 9` (bump for every build installed over another — the helper is
  re-registered only when `CFBundleVersion` changes).
- Monolingual and Helper: `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-"` (local signing; upstream
  "Developer ID Application").
- `LipoCore` and `HelperShared`: `SKIP_INSTALL = YES` (otherwise Archive produces a Generic Xcode
  Archive and hides Distribute App › Copy App).
- Xcode upgraded the file format (`objectVersion = 90`, `preferredProjectObjectVersion = 90`,
  `dstSubfolder` in copy phases, dropped default keys). Not a deliberate change; whatever Xcode
  writes is fine.

## C12. App icon (`Resources/AppIcon.icon/icon.json`)

- Both `"specular" : "inside"` → `"specular" : true` (Xcode 26's Icon Composer format; the
  macOS 27 value isn't understood). Re-check if upstream changes the icon.

## C13. Documentation

- `README.markdown`: License section rewritten (C14); new "About this version" section listing C1–C7 differences; Sparkle line
  annotated as removed; Architecture gains the macOS 15 XPC note; new "Command-line use" section
  (options table, examples, `lipo` note — keep in step with `main.swift`); Dependencies "None";
  Building adds the Xcode Copy App route; localization credits prefaced "This version is English
  only"; Developers says macOS 15.6 / Xcode 26.
- `AGENTS.md`: rewritten to match all of the above (deployment target, strict settings, English
  only, no dependencies, fixed windows, XPC legacy path, ad-hoc signing caveat, version-bump
  rule, command-line use, single help file/screenshot, no Sparkle feed).
- `release.markdown`: single help bundle, no appcast steps, Copy App route.
- `Resources/README.rtfd/TXT.rtf`: "email, or" (serial comma), "accidentally" (typo fix),
  blocklist → blacklist.

## C14. Licensing (`_Shared/Licensing` model)

Goal: GPL-3.0-only, copyright avenged110, with upstream's copyright kept and the changes marked
(GPL-3.0 §4, §5(a)). Upstream states no version in any file, so version 3 is elected (§14).

- `LICENSE.txt` → `COPYING` (byte-identical to `_Shared/Licensing/COPYING`); the pbxproj file
  reference and Resources build file keep their IDs, renamed. `scripts/release.sh` copies
  `COPYING` into the disk image. Help menu: "LICENSE.txt" → "License (COPYING)", opened in
  TextEdit (`HelpCommands.openLicense()`, since a file without an extension has no default app).
- Headers: every upstream header is kept verbatim. A file that differs from upstream gets, above
  it, `Copyright © 2026 avenged110.` / `Portions Copyright © 2014–2026 Ingmar Stein (Monolingual,
  …)` / `SPDX-License-Identifier: GPL-3.0-only` / `Adapted from Monolingual and modified by
  avenged110, 2026.`; an unchanged upstream file gets only the SPDX line (AppDelegate,
  ArchitectureSetting, ProgressView, Root, lipo/main.swift, util/hello.c). New files have the
  plain avenged110 header. `Package.swift` has none (its first line must be the tools version).
- `Resources/en.lproj/Credits.html` regenerated from the template: upstream statement, GPL
  block, and all upstream credits (developers, both icons, translators).
- `NSHumanReadableCopyright` (Info.plist and `InfoPlist.strings`) and `CFBundleGetInfoString`:
  avenged110 first, upstream "Copyleft …" kept.
- `NOTICES/Monolingual-GPL-3.0.txt` (copy of the `_Shared` notice); `THIRD_PARTY.md` entry;
  README "License" section rewritten.
- **On a new upstream:** re-run the header pass (diff each file against the new baseline to
  decide modified vs SPDX-only), and update the upstream years in Credits/Info.plist/notice.

## C15. Fixes from the 2026-10-21 audit

- `Helper.stripFile`: clears the URL's cached resource values before reading the size after
  `strip`; before, the cached "before" size came back and stripping never reported space saved.
- `HelperContext.remove` (trash mode): records each item's owner and mode before handing it to
  the user, and puts them back if the item could not be moved to either trash. Before, a failed
  move left system files owned by the user.

## Known loose ends (as of 2026-10-21)

- The help/README screenshot (`Monolingual-2.0.2-en.png`, `width="752"`) still shows upstream's
  640-pt-wide window, not the 550 × 450 one.
- The Mach service, the launchd label and the helper's executable name are still upstream's
  `com.github.IngmarStein.Monolingual…` (bundle identifiers are now `app.Monolingual…`, see C16).
- SwiftUI's `Table` logs "Application performed a reentrant operation in its NSTableView
  delegate" once at launch. The stack is entirely inside SwiftUI/AppKit (no app code), so there
  is nothing in the app to fix.

## C16. Own identity and no privacy strings (2026-10-21)

- Bundle identifiers: `app.Monolingual` and `app.Monolingual.Helper`; `HelperService.appSigningIdentifier`
  and `helperSigningIdentifier` (`Helper/Sources/HelperProtocol.swift`) match them, since XPC rejects
  every session whose peer's signing identifier differs.
- `Info.plist`: removed upstream's `NSCalendars/Contacts/PhotoLibrary/RemindersUsageDescription`.
  No code uses Contacts, EventKit or Photos; the strings were dead.
- Credits.html and README link to <https://github.com/avenged110/Monolingual>; README uses
  `README_hero_image.png` and drops upstream's CI badge.

## C17. Native checkbox lists (2026-10-21)

- New `Sources/CheckboxTable.swift`: an `NSTableView` (inset style, alternating rows, no header,
  no selection) whose cells are reused `NSButton` checkboxes. It replaces SwiftUI's `Table` with a
  `Toggle` per cell in both tabs of `MainView`, which dropped frames while scrolling.
- `outlinedTable()` now only clips and outlines; the table style lives in `CheckboxTable`.
- Toggling a checkbox updates visible cells in place; only a change of rows (filtering) reloads.

## C18. Distribution audit (2026-10-21)

- Ad hoc builds on macOS 26+: `HelperService.signingTeam`; without a team, the helper serves through
  the C XPC API with `legacyAppPeerRequirement` (the app's cdhash) and the app attaches no peer
  requirement, as on macOS 15. Before this, `isFromSameTeam` refused every session of an ad hoc build.
- Helper CLI: prints `path: bytes` per item; `-n` reports instead of returning silently
  (`HelperContext.reportDryRun`), and no longer thins or strips binaries (it lists them with 0 bytes).
- In-app README.rtfd: GPL-3.0-only wording, `COPYING`, this fork's links, a "This copy" section.
- Help › Monolingual Website opens this fork's repository; Donate still goes to upstream's page.
- Settings: a directory already listed is not added again (duplicate `Root.id`s).
- "canceled" in the cancel alert (and its xcstrings key) and the log line.
- `DEVELOPMENT_TEAM` and the target attribute `DevelopmentTeam` (upstream's ADVP2P7SJK) removed.
- Helper Info.plist: `CFBundleIdentifier` is the literal `app.Monolingual.Helper`. The plist is embedded
  in a tool and not preprocessed, so `$(PRODUCT_BUNDLE_IDENTIFIER)` became the helper's signing identifier.

---

## Procedure: applying these customizations to a new upstream release

1. Put the new upstream in its own folder; diff old baseline → new upstream
   (`diff -ruN ~/Desktop/Monolingual-main <new>`) to see what upstream changed.
2. Start from a copy of the **new upstream** (never edit this project in place until the result
   is verified; keep this project as the reference for "what we built").
3. Try `patch -p0 --dry-run` with `upstream-2.0.2-to-custom.patch` (paths are relative to the
   project root after stripping the baseline prefix) to see which hunks apply cleanly; apply the
   clean ones, then work through C1–C13 above by intent for the rest. Redo `project.pbxproj`
   edits through the settings and file lists described here rather than by patch.
4. Sweep checks: no `blocklist` left (C5); no network or Sparkle (C2); no packages (C3); only
   `en` (C4); deployment target 15.6 everywhere and every new macOS 26/27 API guarded (C1).
5. Build the Monolingual and Helper schemes (warning-free), run `swift test`, launch the app and
   compare the windows with this project's.
6. Report back: what applied cleanly, what had to be adapted and how, and every point where the
   new upstream needs a decision from the user (new features, new strings/languages, changed
   APIs, conflicts with an entry here).
7. Update the baseline: replace the reference copy with the new upstream, regenerate the patch,
   and update this file (baseline version, entries, loose ends).

## Maintenance

Regenerate the patch after any change (from the project root):

```bash
diff -ruN -x .DS_Store -x xcuserdata -x '*.lproj' -x '*.png' -x 'b*list.plist' -x '*.psd' -x '*.sketch' -x Customizations -x .build ~/Desktop/Monolingual-main . > Customizations/upstream-2.0.2-to-custom.patch
```
