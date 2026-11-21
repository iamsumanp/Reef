#!/bin/zsh
# Builds Reef.app without Xcode (Command Line Tools are enough) and installs it to ~/Applications.
#
#   ./build.sh               build, install, launch
#   ./build.sh --no-install  build only (build/Reef.app)
#
# This is a local, self-updating-free build with its own bundle id, so it sits next to the
# official Reef without disturbing it. Releases still come from the Xcode project.
set -euo pipefail
cd "$(dirname "$0")"

[[ -f build.local.sh ]] && source build.local.sh

BUNDLE_ID=${REEF_BUNDLE_ID:-io.github.iamsumanp.reef}
OFFICIAL_ID=xandergouws.Reef
OFFICIAL_APP=/Applications/Reef.app
APP=build/Reef.app
VERSION=$(grep -m1 'MARKETING_VERSION = 1\.[1-9]' Reef.xcodeproj/project.pbxproj | sed -E 's/.*= (.*);/\1/')

mkdir -p build

# `#Preview` needs a compiler plugin that only ships inside Xcode; this stand-in expands it to nothing.
if [[ ! -x build/PreviewsMacrosStub || Tools/PreviewsMacrosStub.swift -nt build/PreviewsMacrosStub ]]; then
  echo "› compiling preview-macro stand-in…"
  swiftc -O Tools/PreviewsMacrosStub.swift -o build/PreviewsMacrosStub
fi
FLAGS=(-c release -Xswiftc -load-plugin-executable -Xswiftc "$PWD/build/PreviewsMacrosStub#PreviewsMacros")
# Debug hooks (Tools/reefctl.swift) only with REEF_DEBUG=1, e.g. in build.local.sh.
[[ ${REEF_DEBUG:-0} == 1 ]] && FLAGS+=(-Xswiftc -DREEF_DEBUG) && echo "› debug build"

echo "› compiling Reef…"
if ! OUT=$(swift build $FLAGS 2>&1); then
  echo "$OUT" | grep -E "error" | sort -u
  echo "✗ build failed"
  exit 1
fi
BIN_DIR=$(swift build $FLAGS --show-bin-path)

# The asset catalog (menu bar icon, accent colour) and app icon can only be compiled by Xcode's
# actool, so they are borrowed from an installed copy of the official app and kept in build/assets.
if [[ ! -f build/assets/Assets.car ]]; then
  if [[ -f $OFFICIAL_APP/Contents/Resources/Assets.car ]]; then
    mkdir -p build/assets
    cp $OFFICIAL_APP/Contents/Resources/{Assets.car,reef_placeholder.icns} build/assets/
  else
    echo "✗ build/assets is empty and $OFFICIAL_APP is not installed."
    echo "  Install the official Reef once (getreef.app) so its compiled assets can be copied."
    exit 1
  fi
fi

echo "› assembling bundle…"
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources,Frameworks}
cp $BIN_DIR/Reef $APP/Contents/MacOS/Reef
cp build/assets/* $APP/Contents/Resources/
cp -R $BIN_DIR/Sparkle.framework $APP/Contents/Frameworks/
install_name_tool -add_rpath @executable_path/../Frameworks $APP/Contents/MacOS/Reef 2>/dev/null

# KeyboardShortcuts looks for its strings in "<bundle>/KeyboardShortcuts_KeyboardShortcuts.bundle"
# and, failing that, in the SwiftPM build folder it was compiled in. A signed app may hold nothing
# in its root, so the installed app reads them from .build/ here: deleting .build/ (or this
# checkout) breaks the installed app until build.sh is run again. The copy in Resources is spare.
cp -R $BIN_DIR/KeyboardShortcuts_KeyboardShortcuts.bundle $APP/Contents/Resources/

# No SUFeedURL on purpose: the official update feed would replace this build with upstream's.
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>Reef</string>
	<key>CFBundleExecutable</key><string>Reef</string>
	<key>CFBundleIconFile</key><string>reef_placeholder</string>
	<key>CFBundleIconName</key><string>reef_placeholder</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Reef</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key><string>14.6</string>
	<key>LSUIElement</key><true/>
	<key>NSAppSleepDisabled</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Signing. A stable (even self-signed) certificate lets macOS keep the Accessibility and Screen
# Recording permissions across rebuilds; ad-hoc signing loses them every time. Point
# REEF_SIGN_KEYCHAIN / REEF_SIGN_PASSWORD / REEF_SIGN_NAME at one in build.local.sh (gitignored).
SIGN=-
KCARG=()
if [[ -n ${REEF_SIGN_KEYCHAIN:-} && -f $REEF_SIGN_KEYCHAIN ]] \
   && security unlock-keychain -p "${REEF_SIGN_PASSWORD:-}" "$REEF_SIGN_KEYCHAIN" 2>/dev/null; then
  ID=$(security find-identity -p codesigning "$REEF_SIGN_KEYCHAIN" | awk -v cn="${REEF_SIGN_NAME:-}" 'index($0, cn) {print $2; exit}')
  [[ -n $ID ]] && SIGN=$ID && KCARG=(--keychain "$REEF_SIGN_KEYCHAIN")
fi
codesign --force --deep $KCARG --sign $SIGN $APP/Contents/Frameworks/Sparkle.framework 2>/dev/null
codesign --force $KCARG --sign $SIGN --identifier $BUNDLE_ID $APP
[[ $SIGN == - ]] && echo "› signed ad-hoc (permissions need re-granting after every rebuild)" || echo "› signed with ${REEF_SIGN_NAME}"
codesign --verify --deep --strict $APP

[[ ${1:-} == --no-install ]] && { echo "✓ $APP"; exit 0; }

# First install: carry profiles, bindings and settings over from the official app.
SUPPORT="$HOME/Library/Application Support"
if [[ ! -d $SUPPORT/$BUNDLE_ID && -d $SUPPORT/$OFFICIAL_ID ]]; then
  echo "› copying profiles and settings from the official Reef…"
  cp -R "$SUPPORT/$OFFICIAL_ID" "$SUPPORT/$BUNDLE_ID"
  defaults export $OFFICIAL_ID - 2>/dev/null | defaults import $BUNDLE_ID - 2>/dev/null || true
fi

echo "› installing to ~/Applications…"
pkill -x Reef 2>/dev/null && sleep 0.5 || true   # also quits the official Reef: both would grab the same shortcuts
mkdir -p ~/Applications
rm -rf ~/Applications/Reef.app
cp -R $APP ~/Applications/Reef.app
open ~/Applications/Reef.app
echo "✓ Reef is running from ~/Applications/Reef.app"
