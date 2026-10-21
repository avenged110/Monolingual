# Monolingual Project Context

## Project Overview
Monolingual is a macOS utility for removing unnecessary language localization files to reclaim disk space. It is written in Swift and utilizes a modular architecture involving a main application and a privileged helper tool.

### Key Technologies
- **Language:** Swift 6 (Swift 6 language mode), deployment target macOS 15.6 — set at the project
  level and on every target (the app, the helper, `lipo` and the tests). `Package.swift` matches it.
- **Strict settings:** Strict Memory Safety, Require Existential Any and Member Import Visibility
  are on at the project level, and every target inherits them. Unsafe constructs are marked
  `unsafe`, and the build is warning-free; keep it that way.
- **Localization:** English only. The project's known regions are `en` and `Base`, the String
  Catalog holds English alone, and the only help bundle shipped is `README.rtfd`.
- **UI Framework:** SwiftUI & AppKit
- **Build System:** Xcode (`.xcodeproj`), shell scripts (`scripts/`), GitHub Actions
- **Dependencies:** none. The project uses no Swift packages and makes no network requests: there
  is no update mechanism (Sparkle was removed), and the bundle blacklist is the one in the asset
  catalog rather than a download. `Package.swift` exists only so that `swift test` can build the
  helper and `lipo` sources.

## Architecture
The application is composed of two main components:
1.  **Monolingual App:** The user-facing application (Sources: `Sources/`). It registers the helper as a launch daemon with `SMAppService` and talks to it directly over XPC. It shows one fixed-size main window (550 × 450 points, a round 2 points over the narrowest width at which the toolbar holds both the tab picker and the search field) and a fixed 450 × 300 settings window; `FixedWindowConfigurator` keeps both from being resized, zoomed, put in full screen or tabbed. It is **not** sandboxed: macOS refuses to register an unsandboxed launch daemon from a sandboxed app (`SMAppService target executable must be sandboxed because the app is sandboxed`), and sandboxing the helper is not an option for a tool that deletes files anywhere on disk. The app *was* sandboxed, from 2015 through 2.0.0, via `Monolingual.entitlements`; removing the sandbox is what makes 2.0.1 work. `SMJobBless`, which `SMAppService` replaced, had no such requirement — it trusted the client on code signature alone — so the entitlement and the helper install coexisted for a decade without anyone noticing the coupling.
2.  **Privileged Helper:** Performs operations requiring elevated privileges, such as file deletion (Sources: `Helper/`). It is an executable inside the app bundle (`Contents/MacOS`), together with its launchd property list in `Contents/Library/LaunchDaemons`. Started without arguments (as launchd does) it serves the app; started with `--include` it runs one removal from the command line — see *Command-line use* below.

## Build & Development

### Prerequisites
- Xcode 26+ (the project builds against the macOS 26 SDK and deploys to macOS 15.6).
  `scripts/select-xcode.sh` picks a suitable Xcode from `/Applications` and is what the build uses;
  `MIN_XCODE_MAJOR` overrides the floor.
- Some APIs the code uses are macOS 26 only (`XPCPeerRequirement` and the XPC initializers that take
  one) and are behind `#available` checks with a macOS 15 path; see *Notes*. `CPU_SUBTYPE_ARM64E_X1`
  only exists in the macOS 27 SDK, so its value (12) is defined locally as `cpuSubtypeARM64EX1`.

### Commands
- **Build (Debug):** `make development` (executes `scripts/build.sh Debug`)
- **Build (Release):** `make deployment` (executes `scripts/build.sh Release`)
- **Release Packaging:** `make release` (executes `scripts/release.sh`: build, sign, notarize,
  staple, disk image; see *Releases* below). It needs a Developer ID identity; for a local build,
  use Product › Archive › Distribute App › Custom › Copy App in Xcode instead.
- **Tests:** `swift test`, or `xcodebuild -scheme Helper -destination 'platform=macOS' test`
  (the `Helper` scheme's test action runs the `Helper Tests` target).
- **Linting/Formatting:** The project includes `.swiftlint.yml` and `.swiftformat` configurations. Ensure these tools are run to maintain code style. CI runs `shellcheck` over `make-diskimage.sh`, `scripts/` and `util/`, and SwiftLint (not `--strict`: `HelperContext.swift` carries a TODO that is a real caveat) over the Swift sources.
- `LipoCore` and `HelperShared` are static libraries with Skip Install = Yes. Leave it on: a static
  library that installs turns the archive into a Generic Xcode Archive, and Xcode then hides the
  Copy App distribution method.

### Releases
`Info.plist` is the single source of truth for the version; nothing rewrites it. To release, bump
`CFBundleShortVersionString`/`CFBundleVersion` there and in `Helper/Sources/MonolingualHelper-Info.plist`,
commit, then either tag the commit `v<version>` and let `.github/workflows/release.yml` build and
publish it, or run `make release` locally (same `scripts/release.sh`, writes `release-<version>/`).

The release workflow takes these secrets and variables:

| Name | Kind | Holds |
| --- | --- | --- |
| `DEVELOPER_ID_CERT` | secret | base64 of the Developer ID Application certificate and key (`.p12`) |
| `DEVELOPER_ID_PASSWORD` | secret | the password that `.p12` was exported with |
| `NOTARY_KEY` | secret | the App Store Connect API key (`.p8`), as text |
| `NOTARY_KEY_ID` | variable | that key's id |
| `NOTARY_ISSUER` | variable | the issuer id of the team the key belongs to |
| `DEVELOPER_ID` | variable | optional; the codesigning identity, if not the project's default |

No provisioning profile is needed: the app and its helper carry no restricted entitlements.
`DEVELOPER_ID_CERT` has to hold that one identity and its chain, nothing else:
`security export -t identities` exports every identity and certificate in the keychain, which is
both past GitHub's 48 KB secret limit and a pile of private keys CI has no use for. Import the
export into a scratch keychain, delete the other identities and certificates, keep `Developer ID
Certification Authority` and `Apple Root CA`, and export that — about 3 KB, 4.3 KB in base64.
A `workflow_dispatch` run builds, signs, notarizes and packages without publishing, and uploads
the artifacts — use it to check a release before tagging.

Two things a release has to be written into by hand, beyond the version numbers themselves.

**The changelog.** `README.markdown` carries a "What's new in `<version>`" section, and so does the
help file `Resources/README.rtfd/TXT.rtf`, which is what the Help menu shows and what `release.sh`
copies into the disk image. It is RTF, not text: the document is `ansicpg1252`, a paragraph break
is a lone backslash followed by a newline, and anything outside ASCII is written as a `\'xx`
escape. Check a change with `textutil -convert txt -stdout` rather than by reading the markup.
(`LEESMIJ.rtfd`, `Leggimi.rtfd`, `Lies-mich.rtfd` and `LisezMoi.rtfd` are still in `Resources/`
but are no longer part of the project or the app.)

**The screenshot.** The help file embeds one and `README.markdown` points at the same image, so a
release renames it and deletes the old one — the name is in the `\NeXTGraphic` line of `TXT.rtf`
and in the README's `<img src=…>`. The help draws an image at half its pixel size — `\width` and
`\height` are twips and equal the pixel size times ten, and the README's `width` attribute is half
the pixel width — so both have to be recomputed from what the new capture measures. The window is
fixed at 550 × 450 points of content, so a Retina capture comes out the same size every time.
`screencapture -l<window number>` takes the picture, with `-o` left off because the shadow is part
of it; the number comes from `CGWindowListCopyWindowInfo`, or `screencapture -w` picks a window by
clicking on it. The capturing process needs Screen Recording permission, or the picture holds only
the desktop.

The window only draws its shadow, and its colored traffic lights, while it is the key window, and
anything can take the focus back between activating the app and taking the picture. So measure
what came out instead of trusting the activation: the opaque part of the capture begins 112 pixels
in from the left edge when the window is active and 46 when it is not. And the image should be
light while the Mac is not necessarily: neither the `-AppleInterfaceStyle Light` launch argument
nor an `AppleInterfaceStyle` default in the app's own domain does anything, so it takes a temporary
`NSApp.appearance = NSAppearance(named: .aqua)` in `applicationDidFinishLaunching`, which has to
come back out again.

## Command-line use

The helper is also a command-line tool: run with `--include`, it performs one removal and exits,
without the app or XPC. `README.markdown` documents the options. The parsing is hand-written in
`Helper/Sources/main.swift` (there is no argument-parsing package); keep that file's usage text and
the README's table in step when an option changes. A removal from the command line acts on the
file system with the privileges of whoever runs it, so `sudo` makes it as powerful as the daemon.

`lipo/main.swift` is a separate, minimal tool: `lipo <executables> --arch <architecture>`, with
`--arch` repeatable, thins the given files in place and reports the bytes saved per file.

## Key Directories & Files
- `Sources/`: Main application source code.
- `Helper/`: Source code for the privileged helper tool.
- `lipo/`: Source code for the custom `lipo` tool used for architecture stripping (`LipoCore`, which
  the helper links, and a small standalone `lipo` command in `main.swift`).
- `scripts/`: Build and release shell scripts — `select-xcode.sh`, `build.sh`, `notarize.sh`,
  `release.sh`. The workflows and `make release` run the same scripts.
- `.github/workflows/`: `ci.yml` (lint, build, test), `release.yml` (tagged releases and dry runs),
  `codeql.yml`.
- `make-diskimage.sh` and `dmg.js`: build the disk image and lay out its Finder window.
- `Makefile`: Entry points for build and release automation.
- `Package.swift`: Swift Package Manager definition of the helper, `lipo` and test targets, for
  `swift test`. It has no dependencies.

## Notes
- Licensing follows `../_Shared/Licensing` (GPL-3.0-only, avenged110): see Customizations C14 for
  how the upstream headers and credits are kept. Any file newly changed from upstream gets the
  "Adapted from Monolingual" header block above its original one.
- `FixedWindowConfigurator` must not touch the window synchronously: its probe is attached in the
  middle of a layout pass, and a style-mask change there triggers AppKit's layout-recursion warning.
- The privileged helper is registered with `SMAppService` (macOS 13+). An administrator has to allow it in System Settings › General › Login Items & Extensions before it can run.
- Helpers installed by Monolingual 1.9.0 and earlier (SMJobBless based) are no longer removed automatically; `util/uninstall.sh` removes them. They serve a Mach service named after themselves, so they do not collide with the daemon registered with `SMAppService`.
- The helper validates its XPC peers itself, since launchd no longer restricts access to the daemon's Mach service. On macOS 26 and later it uses a declarative `XPCPeerRequirement` that XPC enforces for every session. Before macOS 26 the Swift XPC API takes no requirement, so the helper serves its Mach service with the C API (`xpc_connection_create_mach_service`) and sets `xpc_connection_set_peer_code_signing_requirement` on every peer, and on the connection to the app's progress endpoint. The requirement is the app's identifier signed by the helper's own team or, for a build signed to run locally (no team), the app bundle's designated requirement, which pins its cdhash. If neither can be worked out, the helper refuses to serve.
- With a local (ad-hoc) signature, the helper only accepts the exact app build it was installed with. A Debug build run from Xcode while another copy is registered cannot reach the helper; sign with a development team to avoid that.
- The app re-registers the daemon only when `CFBundleVersion` changes (`HelperInstaller`), so bump it for every build that is installed over another.
- The app and the helper talk over the Swift XPC API (`XPCListener`/`XPCSession`), not `NSXPCConnection`: messages are `Codable` types carried as JSON in an `XPCDictionary`, and the app sends an endpoint of its own for the helper to report progress and the result on.
- The helper handles messages on a serial queue but runs a removal on a separate `OperationQueue`, so an `exit` message is received while a removal is in progress; cancellation is the helper process exiting, which is also how the app ends the session.
