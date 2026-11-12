#!/bin/bash
# Installs the app and its audio driver (needs your password), then restarts CoreAudio.
#
#   ./scripts/install.sh                  # builds if needed, installs build.noindex/Mando.app
#   bash install.sh ~/Downloads/Mando.app        # installs a downloaded release
#
set -euo pipefail

if [[ $# -gt 0 ]]; then
  SRC="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  cd "$(dirname "$0")/.."
  SRC=build.noindex/Mando.app
  [[ -d "$SRC" ]] || ./scripts/build.sh
fi
DRIVER="$SRC/Contents/PlugIns/Mando.driver"
[[ -d "$DRIVER" ]] || { echo "No driver in $SRC (expected $DRIVER)" >&2; exit 1; }

echo "==> Installing audio driver (macOS will ask for your password)"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Mando.driver
sudo cp -R "$DRIVER" /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/Mando.driver
sudo killall -9 coreaudiod 2>/dev/null || true

echo "==> Installing app"
pkill -x Mando 2>/dev/null || true
rm -rf /Applications/Mando.app
cp -R "$SRC" /Applications/
sleep 2
open /Applications/Mando.app
echo "==> Done. Look for the dial icon in the menu bar."
