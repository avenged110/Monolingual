# How to create a Monolingual release

1. Bump the version number in
    * `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`)
    * `Helper/Sources/MonolingualHelper-Info.plist`
    * the screenshot in `Resources/README.rtfd`: rename `Monolingual-<version>-en.png` and update
      the `\NeXTGraphic` reference to it in `TXT.rtf` and the `<img src=…>` in `README.markdown`
2. Add the changelog to `README.markdown` and `Resources/README.rtfd`.
3. Check the release on a dry run: Actions › Release › Run workflow. It builds, signs, notarizes
   and packages without publishing, and uploads the artifacts to the run. Download them and open
   the disk image.
4. Commit the version bump and push it to `main`.
5. Tag the release (`git tag -s vX.Y.Z -m 'X.Y.Z'`) and push the tag
   (`git push origin vX.Y.Z`). The tag has to match `Info.plist`; the workflow refuses it
   otherwise. It builds the release and attaches the disk image, the app zip, and the debug symbols
   to a new GitHub release. The release notes are generated from the commits;
   edit them afterwards if they need a human touch.
There is no update feed: existing installations are updated by replacing the app.

Without the repository secrets (see AGENTS.md), or to build a release by hand, `make release`
does the same work locally and writes `release-<version>/`. Both need a Developer ID identity; for
a locally signed build, use Product › Archive › Distribute App › Custom › Copy App in Xcode.
