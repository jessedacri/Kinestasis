#!/bin/bash
#
# build-dmg.sh — package Kinestasis as a signed (and optionally
# notarized) drag-to-Applications .dmg. Adapted from PolyMerge's
# proven flow (~/polymerge/scripts/build-dmg.sh).
#
# Usage:
#   ./scripts/build-dmg.sh                # build + sign + dmg
#   NOTARIZE=1 ./scripts/build-dmg.sh    # also notarize + staple
#
# Notarization reads the keychain profile "polymerge-notary" (same
# Apple ID / Team as PolyMerge — the profile is account-level).
#
# Output:
#   build/Kinestasis.app
#   build/<DMG_LABEL>.dmg

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Kinestasis"
BUNDLE_ID="com.jessedacri.kinestasis"
TEAM_ID="4ND7U9JZ8C"
SIGNING_IDENTITY="Developer ID Application: Jesse Dacri (${TEAM_ID})"
NOTARY_PROFILE="polymerge-notary"

SHORT_VERSION="0.1.6"
BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DMG_LABEL="${DMG_LABEL:-Kinestasis ${SHORT_VERSION}}"

BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${DMG_LABEL}.dmg"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
INFO_PLIST_TEMPLATE="Resources/Info.plist"
ENTITLEMENTS="Resources/${APP_NAME}.entitlements"

BOLD="$(tput bold 2>/dev/null || true)"; DIM="$(tput dim 2>/dev/null || true)"
GREEN="$(tput setaf 2 2>/dev/null || true)"; YELLOW="$(tput setaf 3 2>/dev/null || true)"
RED="$(tput setaf 1 2>/dev/null || true)"; RESET="$(tput sgr0 2>/dev/null || true)"
step() { echo "${BOLD}==>${RESET} ${BOLD}$1${RESET}"; }
note() { echo "    ${DIM}$1${RESET}"; }
ok()   { echo "    ${GREEN}✓${RESET} $1"; }
warn() { echo "    ${YELLOW}⚠${RESET}  $1"; }
fail() { echo "    ${RED}✗${RESET} $1" >&2; exit 1; }

step "Checking prerequisites"
command -v swift >/dev/null || fail "Swift not found in PATH."
ok "Swift $(swift --version | head -1 | awk '{print $4}')"
security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGNING_IDENTITY}" \
    || fail "Signing identity not found in keychain: ${SIGNING_IDENTITY}"
ok "Signing identity: ${SIGNING_IDENTITY}"
[[ -f "${INFO_PLIST_TEMPLATE}" ]] || fail "Info.plist template missing"
[[ -f "${ENTITLEMENTS}" ]] || fail "Entitlements missing"
[[ -f "Resources/AppIcon.icns" ]] || fail "Resources/AppIcon.icns missing"
ok "Templates + icon present"

step "Building release binary"
swift build -c release > /tmp/kinestasis-build.log 2>&1 || {
    cat /tmp/kinestasis-build.log; fail "Release build failed"; }
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY_PATH="${BIN_DIR}/${APP_NAME}"
[[ -f "${BINARY_PATH}" ]] || fail "Release binary not found at ${BINARY_PATH}"
ok "Built ${BINARY_PATH} ($(du -h "${BINARY_PATH}" | awk '{print $1}'))"

step "Wrapping in .app bundle"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
ok "Copied binary"

# SPM resource bundles (Bundle.module) must ride along in
# Contents/Resources for the executable to find them.
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
    cp -R "${bundle}" "${APP_BUNDLE}/Contents/Resources/"
    ok "Copied $(basename "${bundle}")"
done
shopt -u nullglob

cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
sed -e "s/__SHORT_VERSION__/${SHORT_VERSION}/g" \
    -e "s/__BUILD_VERSION__/${BUILD_VERSION}/g" \
    "${INFO_PLIST_TEMPLATE}" > "${APP_BUNDLE}/Contents/Info.plist"
plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null || fail "Info.plist lint failed"
ok "Info.plist (v${SHORT_VERSION} build ${BUILD_VERSION}) + icon staged"

step "Launch smoke test (dev .build masked)"
# Bundle.module's generated accessor falls back to this machine's absolute
# .build path, which hides missing-resource packaging bugs until the app
# runs on another Mac (the 0.1.0 launch crash). Mask .build so the packaged
# app must stand alone; a window will flash for a few seconds.
SMOKE_LOG="/tmp/kinestasis-smoke.log"
SMOKE_MASK=""
if [[ -d ".build" ]]; then
    SMOKE_MASK=".build.smoke-masked"
    mv ".build" "${SMOKE_MASK}"
fi
"${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" > "${SMOKE_LOG}" 2>&1 &
SMOKE_PID=$!
sleep 4
SMOKE_ALIVE=0
if kill -0 "${SMOKE_PID}" 2>/dev/null; then
    SMOKE_ALIVE=1
    kill "${SMOKE_PID}" 2>/dev/null || true
fi
wait "${SMOKE_PID}" 2>/dev/null || true
if [[ -n "${SMOKE_MASK}" ]]; then
    mv "${SMOKE_MASK}" ".build"
fi
if [[ "${SMOKE_ALIVE}" == "1" ]]; then
    ok "Packaged app survived launch without dev fallbacks"
else
    sed 's/^/    /' "${SMOKE_LOG}"
    fail "Packaged app died at launch — see ${SMOKE_LOG}"
fi

step "Code signing"
# SPM resource bundles are data-only — the .app seal covers them; only
# the binary and the bundle itself get signatures.
codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" \
    "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>&1 | sed 's/^/    /'
codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" \
    "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>&1 | grep -q "satisfies its Designated Requirement" \
    || { codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'; fail "codesign verification failed"; }
ok "codesign verified"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
    step "Notarizing .app"
    NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARIZE_ZIP}"
    NOTARY_LOG="/tmp/kinestasis-notary.log"
    if xcrun notarytool submit "${NOTARIZE_ZIP}" \
            --keychain-profile "${NOTARY_PROFILE}" --wait > "${NOTARY_LOG}" 2>&1 \
       && grep -q "status: Accepted" "${NOTARY_LOG}"; then
        ok "Notarization accepted"
        xcrun stapler staple "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'
        ok "Stapled ticket to .app"
    else
        warn "Notarization did not return Accepted — see ${NOTARY_LOG}"
    fi
    rm -f "${NOTARIZE_ZIP}"
else
    note "Skipping notarization (NOTARIZE=1 to enable)."
fi

step "Building DMG"
rm -rf "${DMG_STAGING}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
cp "Resources/AppIcon.icns" "${DMG_STAGING}/.VolumeIcon.icns"
SetFile -a C "${DMG_STAGING}"
hdiutil create -volname "${DMG_LABEL}" -srcfolder "${DMG_STAGING}" -ov -format UDZO \
    "${DMG_PATH}" > /tmp/kinestasis-dmg.log 2>&1 || { cat /tmp/kinestasis-dmg.log; fail "hdiutil failed"; }
rm -rf "${DMG_STAGING}"
ok "Created ${DMG_PATH} ($(du -h "${DMG_PATH}" | awk '{print $1}'))"

# DMG file icon (resource fork) — before signing the DMG.
DMG_ICON_TMP="${BUILD_DIR}/dmg-file-icon.icns"
cp "Resources/AppIcon.icns" "${DMG_ICON_TMP}"
if sips -i "${DMG_ICON_TMP}" > /dev/null 2>&1 \
   && DeRez -only icns "${DMG_ICON_TMP}" > /tmp/kinestasis-dmg-icon.rsrc 2>/dev/null \
   && Rez -append /tmp/kinestasis-dmg-icon.rsrc -o "${DMG_PATH}" 2>/dev/null \
   && SetFile -a C "${DMG_PATH}"; then
    ok "Baked DMG file icon"
else
    warn "DMG icon baking failed (DMG still valid)"
fi
rm -f "${DMG_ICON_TMP}" /tmp/kinestasis-dmg-icon.rsrc

codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}" 2>&1 | sed 's/^/    /'
ok "Signed DMG"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
    step "Notarizing DMG wrapper"
    DMG_NOTARY_LOG="/tmp/kinestasis-notary-dmg.log"
    if xcrun notarytool submit "${DMG_PATH}" \
            --keychain-profile "${NOTARY_PROFILE}" --wait > "${DMG_NOTARY_LOG}" 2>&1 \
       && grep -q "status: Accepted" "${DMG_NOTARY_LOG}"; then
        ok "DMG notarization accepted"
        xcrun stapler staple "${DMG_PATH}" 2>&1 | sed 's/^/    /' && ok "Stapled ticket to DMG"
    else
        warn "DMG notarization did not return Accepted — see ${DMG_NOTARY_LOG}"
    fi
fi

echo ""
echo "${BOLD}${GREEN}Build complete.${RESET}"
echo "  App: ${APP_BUNDLE}"
echo "  DMG: ${DMG_PATH}"
