#!/bin/bash
# Builds a signed and notarized build/release/Weft-<version>.dmg for direct download.
#
# One-time setup:
#   1. A "Developer ID Application" certificate for your team in the login keychain. Only
#      the team's Account Holder can issue one (developer.apple.com → Certificates).
#   2. The asc CLI (brew install asc), signed in with an App Store Connect API key of the
#      same team: asc auth login --name … --key-id … --issuer-id … --private-key AuthKey.p8
#
# Environment:
#   TEAM_ID      team to sign with (default: DEVELOPMENT_TEAM in Config/Local.xcconfig)
#   ASC_PROFILE  asc credentials to notarize with (default: asc's default profile)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$ROOT/build/release
TEAM_ID=${TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null)}

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ -n $TEAM_ID ]] || die "Set TEAM_ID or DEVELOPMENT_TEAM in Config/Local.xcconfig."
[[ -z $(git status --porcelain) ]] || die "Commit or stash your changes first, so the DMG matches a commit."

IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .* ($TEAM_ID)\)\"/\1/p" | head -1)
[[ -n $IDENTITY ]] || die "No Developer ID Application certificate for team $TEAM_ID in the keychain."
asc notarization list >/dev/null \
    || die "asc can't reach the Notary API. See the setup notes at the top of this script."

# Submits a file for notarization and waits; points to Apple's log if it's rejected. A team's
# first submissions can take hours, later ones usually take minutes.
notarize() {
    local result id
    if ! result=$(asc notarization submit --file "$1" --wait --timeout 3h); then
        id=$(plutil -extract data.id raw - <<<"$result" 2>/dev/null) && asc notarization log --id "$id" >&2
        die "Notarization of $(basename "$1") didn't succeed."
    fi
}

rm -rf "$OUT"
mkdir -p "$OUT"

step "Building with $IDENTITY"
xcodegen generate --quiet
xcodebuild archive -quiet \
    -project Weft.xcodeproj -scheme Weft -configuration Release -destination "generic/platform=macOS" \
    -archivePath "$OUT/Weft.xcarchive" -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp

APP=$OUT/Weft.app
ditto "$OUT/Weft.xcarchive/Products/Applications/Weft.app" "$APP"
codesign --verify --strict --deep "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# The app gets its own ticket so it still opens offline once it's copied out of the DMG.
step "Notarizing Weft.app $VERSION"
ditto -c -k --keepParent "$APP" "$OUT/Weft.zip"
notarize "$OUT/Weft.zip"
xcrun stapler staple -q "$APP"

step "Packaging"
DMG=$OUT/Weft-$VERSION.dmg
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Weft.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname Weft -srcfolder "$OUT/dmg" -format ULFO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing $(basename "$DMG")"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"
step "Done: $DMG"
echo "    Publish it with: gh release create v$VERSION \"$DMG\" --title \"Weft $VERSION\""
