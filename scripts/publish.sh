#!/bin/bash
# Creates the GitHub release for the version in project.yml and attaches the
# two disk images that scripts/release.sh left in dist.noindex/:
#
#   Carpe-<version>.dmg   the release under its own name
#   Carpe.dmg             the same file, for the link that never changes:
#                         https://github.com/<owner>/Carpe/releases/latest/download/Carpe.dmg
#
#   scripts/publish.sh             release notes with the install steps only
#   scripts/publish.sh notes.md    the same, with notes.md above them
#
# Stops without creating anything if the tag v<version> is missing here or on
# GitHub, if either disk image is missing, or if they are not the same
# notarized file. Tag and push first:
#
#   git tag -a v<version> -m "Carpe <version>" && git push origin main v<version>
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

case "${1:-}" in
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
NOTES_FILE="${1:-}"
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || fail "no release notes at $NOTES_FILE"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || fail "no MARKETING_VERSION in project.yml"
TAG="v$VERSION"
DMG="dist.noindex/Carpe-$VERSION.dmg"
LATEST="dist.noindex/Carpe.dmg"

command -v gh >/dev/null || fail "gh is missing: brew install gh"

# ------------------------------------------------------------------ the tag

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || fail "there is no tag $TAG. Tag the release commit first:
    git tag -a $TAG -m \"Carpe $VERSION\""
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
    || fail "the tag $TAG is not on GitHub. Push it first:
    git push origin $TAG"

# ---------------------------------------------------------- the disk images

[ -f "$DMG" ] || fail "$DMG is missing. Build it with: make release"
[ -f "$LATEST" ] || fail "$LATEST is missing. Build both with: make release"
cmp -s "$DMG" "$LATEST" \
    || fail "$LATEST is not a copy of $DMG, so it is from another build. Run make release again."
for image in "$DMG" "$LATEST"; do
    xcrun stapler validate "$image" >/dev/null 2>&1 \
        || fail "$image has no notarization ticket stapled to it"
    spctl -a -t open --context context:primary-signature "$image" 2>/dev/null \
        || fail "Gatekeeper does not accept $image"
done
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

# -------------------------------------------------------------- the release

if gh release view "$TAG" >/dev/null 2>&1; then
    fail "the release $TAG already exists. To add a file to it: gh release upload $TAG <file>"
fi
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
{
    if [ -n "$NOTES_FILE" ]; then
        cat "$NOTES_FILE"
        echo
    fi
    cat <<EOF
## Installing

Download \`Carpe.dmg\`, open it, double-click Carpe and click **Move**. The same
steps update an earlier version. Carpe needs macOS 14 or later and runs on
Apple silicon and Intel. The [README](https://github.com/$REPO/blob/$TAG/README.md)
has the steps for the first launch.

\`Carpe.dmg\` and \`Carpe-$VERSION.dmg\` are the same file, signed with a
Developer ID and notarized by Apple.

SHA-256: \`$SHA\`
EOF
} > "$BODY"

gh release create "$TAG" "$DMG" "$LATEST" --verify-tag --title "Carpe $VERSION" --notes-file "$BODY"
echo "SHA-256: $SHA"
