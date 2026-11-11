#!/bin/bash
# Builds Carpe for other people's Macs: a universal Release build signed with
# the Developer ID Application certificate and the hardened runtime, notarized
# by Apple, stapled, and packed into dist/Carpe-<version>.dmg with an
# Applications shortcut.
#
#   scripts/release.sh                       the real thing
#   scripts/release.sh --skip-notarization   everything except Apple's part, to
#                                            try the build; the image is named
#                                            "-unnotarized" and is not for sharing
#
# Notarization signs in with the keychain profile "carpe-notary". The script
# never sees the Apple ID or its password; create the profile once yourself:
#
#   xcrun notarytool store-credentials "carpe-notary" \
#       --apple-id "YOUR_APPLE_ID_EMAIL" --team-id "375L8HDHKR"
#
# and paste an app-specific password (from account.apple.com) when it asks.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="carpe-notary"
NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --skip-notarization) NOTARIZE=0 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option $arg (try --help)"; exit 2 ;;
    esac
done

# xcodebuild needs the full Xcode, as in the Makefile.
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -1)
[ -n "$TEAM" ] || fail "no DEVELOPMENT_TEAM in project.yml"
STORE_COMMAND="xcrun notarytool store-credentials \"$PROFILE\" --apple-id \"YOUR_APPLE_ID_EMAIL\" --team-id \"$TEAM\""

# ---------------------------------------------------------------- preflight

step "Checking the tools and the signing certificate"
command -v xcodegen >/dev/null || fail "xcodegen is missing: brew install xcodegen"
xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild needs the full Xcode in /Applications"

# The certificate's SHA-1 names it exactly, even if two have the same name.
IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application: .*($TEAM)" | head -1 || true)
[ -n "$IDENTITY_LINE" ] || fail "no \"Developer ID Application\" certificate for team $TEAM in the keychain.
Create one in Xcode > Settings > Accounts > Manage Certificates."
IDENTITY_HASH=$(echo "$IDENTITY_LINE" | awk '{print $2}')
IDENTITY_NAME=$(echo "$IDENTITY_LINE" | sed -E 's/^[^"]*"(.*)"$/\1/')
echo "Signing as: $IDENTITY_NAME"

if [ "$NOTARIZE" -eq 1 ]; then
    # Asks Apple for the submission history, which proves the profile exists
    # and still signs in, before ten minutes are spent building.
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        fail "the notarization profile \"$PROFILE\" is missing or no longer signs in.
Create it yourself; the script must not see your Apple ID password:

    $STORE_COMMAND

It asks for an app-specific password: make one at https://account.apple.com
under Sign-In and Security > App-Specific Passwords."
    fi
    echo "Notarization profile: $PROFILE"
else
    echo "Notarization: skipped"
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "note: there are uncommitted changes, so this build matches no commit."
fi

step "Looking for credentials in the files and the git history"
scripts/check-secrets.sh || fail "the release stops here: see above."

# -------------------------------------------------------------------- build

step "Building the Release configuration (arm64 and x86_64)"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/Carpe.app"
rm -rf "$DERIVED"
xcodegen generate --quiet
# Overrides the development signing in project.yml for this build only.
# No get-task-allow (Apple rejects debuggable apps), and a secure timestamp,
# which notarization requires.
xcodebuild -project Carpe.xcodeproj -scheme Carpe -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
    -quiet build
[ -d "$APP" ] || fail "the build produced no $APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
echo "Built Carpe $VERSION ($BUILD)"

step "Checking the signature"
codesign --verify --deep --strict "$APP" || fail "the signature doesn't verify"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
echo "$SIGNATURE" | grep -q "^Authority=Developer ID Application: .*($TEAM)" \
    || fail "not signed with the Developer ID Application certificate of team $TEAM"
echo "$SIGNATURE" | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\(.*runtime.*\)" \
    || fail "the hardened runtime is off"
echo "$SIGNATURE" | grep -q "^Timestamp=" \
    || fail "the signature has no secure timestamp"
echo "$ENTITLEMENTS" | grep -q "com.apple.security.personal-information.calendars" \
    || fail "the calendar entitlement is missing, so Apple Calendar would not work"
if echo "$ENTITLEMENTS" | grep -q "get-task-allow"; then
    fail "the app is signed as debuggable (get-task-allow), which Apple rejects"
fi
ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/Carpe")
case "$ARCHS_BUILT" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) fail "expected a universal binary, got: $ARCHS_BUILT" ;;
esac
echo "$SIGNATURE" | grep -E "^(Identifier|Authority=Developer ID Application|TeamIdentifier|Timestamp)"
echo "Architectures: $ARCHS_BUILT"

step "Looking for credentials in the app bundle"
scripts/check-secrets.sh "$APP" || fail "the release stops here: see above."

# ---------------------------------------------------------------- notarize

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Uploads a file to Apple's notary service and waits for the verdict.
notarize() {
    local file=$1 result id status
    echo "Uploading $(basename "$file") to Apple and waiting. This usually takes a few minutes."
    result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json) \
        || fail "the upload to the notary service failed"
    id=$(echo "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
    status=$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
    if [ "$status" != "Accepted" ]; then
        echo "Apple's answer: ${status:-unreadable}"
        # The log says which file and why.
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        fail "notarization of $(basename "$file") was not accepted"
    fi
    echo "Accepted (submission $id)"
}

if [ "$NOTARIZE" -eq 1 ]; then
    # The app first, so that the copy inside the disk image carries its own
    # ticket and opens on a Mac that is offline.
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$WORK/Carpe.zip"
    notarize "$WORK/Carpe.zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

# ------------------------------------------------------------------ package

step "Making the disk image"
mkdir -p dist
if [ "$NOTARIZE" -eq 1 ]; then
    DMG="dist/Carpe-$VERSION.dmg"
else
    DMG="dist/Carpe-$VERSION-unnotarized.dmg"
fi
STAGE="$WORK/Carpe"
mkdir "$STAGE"
ditto "$APP" "$STAGE/Carpe.app"
# The shortcut to drag the app onto.
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Carpe" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"
codesign --sign "$IDENTITY_HASH" --timestamp "$DMG"
codesign --verify --strict "$DMG" || fail "the disk image's signature doesn't verify"

if [ "$NOTARIZE" -eq 1 ]; then
    step "Notarizing the disk image"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    step "Asking Gatekeeper"
    spctl --assess --type execute -vv "$APP" 2>&1
    spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1
fi

step "Done"
echo "$DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
if [ "$NOTARIZE" -eq 0 ]; then
    echo "Not notarized: other Macs will refuse to open it. Run without --skip-notarization for the release."
fi
