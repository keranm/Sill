#!/usr/bin/env bash
# Build, sign, notarize, and publish a Sill release.
# Usage: scripts/release.sh <version, e.g. 0.2.0>
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh <version>}"
BUILD="$(date -u +%Y%m%d%H%M)"
REPO="keranm/Sill"
NOTARY_PROFILE="sill-notary"
SPARKLE_BIN="scripts/sparkle-tools/bin"
APP="build/Sill.app"
DIST_ZIP="build/Sill-${VERSION}.zip"
SUBMIT_ZIP="build/Sill-notarize-submission.zip"
TAG="v${VERSION}"

echo "==> Bumping version to ${VERSION} (${BUILD})"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Support/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" Support/Info.plist

echo "==> Building and signing app"
make app

echo "==> Submitting for notarization (profile: ${NOTARY_PROFILE})"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$SUBMIT_ZIP"

echo "==> Building distributable zip"
rm -f "$DIST_ZIP"
ditto -c -k --keepParent "$APP" "$DIST_ZIP"

echo "==> Signing update for Sparkle"
SIG_LINE="$("$SPARKLE_BIN/sign_update" "$DIST_ZIP")"
echo "    $SIG_LINE"

echo "==> Updating appcast.xml"
python3 scripts/update_appcast.py \
  --appcast appcast.xml \
  --feed-url "https://raw.githubusercontent.com/${REPO}/main/appcast.xml" \
  --version "$VERSION" \
  --build "$BUILD" \
  --url "https://github.com/${REPO}/releases/download/${TAG}/Sill-${VERSION}.zip" \
  --sig-line "$SIG_LINE"

echo "==> Committing, tagging, and pushing"
git add Support/Info.plist appcast.xml
git commit -m "Release ${TAG}"
git tag "$TAG"
git push origin main
git push origin "$TAG"

echo "==> Creating GitHub release"
gh release create "$TAG" "$DIST_ZIP" \
  --repo "$REPO" \
  --title "Sill ${TAG}" \
  --generate-notes

echo "==> Done: ${TAG} released"
