#!/bin/bash
#
# Build and sign Monolingual.
#
# Usage: scripts/build.sh [Debug|Release]      (default: Release)
#
# Produces, in build/:
#   Monolingual.app             the app, signed with a Developer ID identity
#   Monolingual.app.dSYM.zip    debug symbols (Release only; see below)
#   Monolingual.xcarchive       the archive the app was exported from
#
# Release builds with DEBUG_INFORMATION_FORMAT = dwarf-with-dsym and Debug with
# plain dwarf, so a Debug archive holds no dSYM for the app itself -- only those
# of prebuilt components -- and there is nothing to collect. The dSYM
# handling below is conditional for that reason: make development has to work
# without one.
#
# The signing identity and the team are build settings in the project, so a
# Developer ID Application certificate for team ADVP2P7SJK has to be in the
# keychain. scripts/release.sh and the release workflow both build through
# here, so they package the same app.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"

# Xcode 26 is the floor: the project builds against the macOS 26 SDK.
DEVELOPER_DIR="$(scripts/select-xcode.sh)"
export DEVELOPER_DIR

BUILD_DIR="$PWD/build"
ARCHIVE="$BUILD_DIR/Monolingual.xcarchive"

echo "==> Building Monolingual ($CONFIGURATION) with $(xcodebuild -version | head -1)..."

rm -rf "$ARCHIVE"
xcodebuild archive \
    -project Monolingual.xcodeproj \
    -scheme Monolingual \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$ARCHIVE"

echo "==> Collecting the app and its symbols..."
rm -rf "$BUILD_DIR/Monolingual.app" "$BUILD_DIR/Monolingual.app.dSYM" "$BUILD_DIR/Monolingual.app.dSYM.zip"
if [ -d "$ARCHIVE/dSYMs/Monolingual.app.dSYM" ]; then
    cp -R "$ARCHIVE/dSYMs/Monolingual.app.dSYM" "$BUILD_DIR/"
fi

ARCHIVED="$ARCHIVE/Products/Applications/Monolingual.app"
APP="$BUILD_DIR/Monolingual.app"
EXPORT_DIR="$BUILD_DIR/export"
ARCHIVED_PLIST="$ARCHIVED/Contents/Info.plist"

IDENTITY=$(codesign -dv --verbose=4 "$ARCHIVED" 2>&1 | sed -n 's/^Authority=//p' | head -1)
TEAM=$(codesign -dv --verbose=4 "$ARCHIVED" 2>&1 | sed -n 's/^TeamIdentifier=//p')

if [ -n "$IDENTITY" ]; then
    # The export signs every nested item inside-out with the identity the app
    # was built with, keeping the entitlements each one was built with, which
    # is what notarization checks. (It mattered most for Sparkle's helpers,
    # which shipped ad-hoc signed; the app no longer embeds Sparkle, and the
    # export is kept because it signs whatever is nested correctly.)
    #
    # The export can't run on the archive as `xcodebuild archive` leaves it: it
    # reads an ApplicationProperties dictionary out of the archive's Info.plist
    # that the Xcode IDE writes and no command line component does. Without it
    # it refuses with "expected one {} but found developer-id" whichever method
    # the options plist names. Writing the dictionary is all it takes, and what
    # goes in it is read off the app that is being exported.
    echo "==> Exporting with $IDENTITY..."
    /usr/libexec/PlistBuddy \
        -c "Add :ApplicationProperties dict" \
        -c "Add :ApplicationProperties:ApplicationPath string Applications/Monolingual.app" \
        -c "Add :ApplicationProperties:CFBundleIdentifier string $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ARCHIVED_PLIST")" \
        -c "Add :ApplicationProperties:CFBundleShortVersionString string $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ARCHIVED_PLIST")" \
        -c "Add :ApplicationProperties:CFBundleVersion string $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ARCHIVED_PLIST")" \
        -c "Add :ApplicationProperties:SigningIdentity string $IDENTITY" \
        -c "Add :ApplicationProperties:Team string $TEAM" \
        "$ARCHIVE/Info.plist"

    EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM</string>
</dict>
</plist>
PLIST

    rm -rf "$EXPORT_DIR"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    cp -R "$EXPORT_DIR/Monolingual.app" "$BUILD_DIR/"
else
    echo "Warning: $ARCHIVED is not signed by an authority; leaving it as archived." >&2
    cp -R "$ARCHIVED" "$BUILD_DIR/"
fi
if [ -d "$BUILD_DIR/Monolingual.app.dSYM" ]; then
    /usr/bin/ditto -c -k --keepParent "$BUILD_DIR/Monolingual.app.dSYM" "$BUILD_DIR/Monolingual.app.dSYM.zip"
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
echo "==> Done: build/Monolingual.app $VERSION"
