#!/usr/bin/env bash
#
# install-fork.sh — swap the stock Ghostty.app for the pane-titlebars fork.
#
# IMPORTANT: this quits Ghostty (all windows/panes; window-save-state restores
# the layout on relaunch). Run it from Terminal.app/iTerm, or detached:
#   nohup bash ~/Work/ghostty-fork/install-fork.sh >/tmp/ghostty-fork-install.log 2>&1 &
#
# The stock app is kept at /Applications/Ghostty-stock.app — to roll back:
#   osascript -e 'tell app "Ghostty" to quit'; sleep 2
#   rm -rf /Applications/Ghostty.app
#   mv /Applications/Ghostty-stock.app /Applications/Ghostty.app

set -euo pipefail

APP_ZIP="$HOME/Work/ghostty-fork/dist/ghostty-fork-macos.zip"
DIST_DIR="$HOME/Work/ghostty-fork/dist"

[ -f "$APP_ZIP" ] || { echo "missing $APP_ZIP — download the CI artifact first"; exit 1; }

echo "Unpacking fork build…"
rm -rf "$DIST_DIR/Ghostty.app"
(cd "$DIST_DIR" && unzip -oq ghostty-fork-macos.zip)
[ -d "$DIST_DIR/Ghostty.app" ] || { echo "zip did not contain Ghostty.app"; exit 1; }
xattr -dr com.apple.quarantine "$DIST_DIR/Ghostty.app" 2>/dev/null || true

# Re-sign everything ad-hoc: the bundled Sparkle framework ships signed by the
# Sparkle team, and dyld refuses to load a framework whose Team ID differs
# from the (ad-hoc) app — the app crashes at launch without this.
echo "Re-signing ad-hoc…"
APP="$DIST_DIR/Ghostty.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -s - "$SPARKLE/XPCServices/Downloader.xpc" 2>/dev/null
codesign -f -s - "$SPARKLE/XPCServices/Installer.xpc" 2>/dev/null
codesign -f -s - "$SPARKLE/Autoupdate" 2>/dev/null
codesign -f -s - "$SPARKLE/Updater.app" 2>/dev/null
codesign -f -s - "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null
for p in "$APP/Contents/PlugIns/"*.plugin; do [ -e "$p" ] && codesign -f -s - "$p" 2>/dev/null; done
codesign -f -s - --entitlements "$HOME/Work/ghostty-fork/macos/Ghostty.entitlements" "$APP"
codesign --verify --deep --strict "$APP" || { echo "re-sign failed"; exit 1; }
"$APP/Contents/MacOS/ghostty" +version >/dev/null || { echo "app does not launch"; exit 1; }

echo "Quitting Ghostty…"
osascript -e 'tell application "Ghostty" to quit' 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x ghostty >/dev/null || break; sleep 1; done
pgrep -x ghostty >/dev/null && { echo "Ghostty still running; aborting (unsaved close prompt?)"; exit 1; }

echo "Swapping apps…"
if [ -d /Applications/Ghostty.app ]; then
  rm -rf /Applications/Ghostty-stock.app
  mv /Applications/Ghostty.app /Applications/Ghostty-stock.app
fi
mv "$DIST_DIR/Ghostty.app" /Applications/Ghostty.app

# Don't let Sparkle offer an official update that would replace the fork
defaults write com.mitchellh.ghostty SUEnableAutomaticChecks -bool false

echo "Relaunching…"
open -a /Applications/Ghostty.app
echo "Done. Stock app kept at /Applications/Ghostty-stock.app"
