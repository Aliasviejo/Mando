#!/bin/bash
# Installs the app and its audio driver (needs your password), then restarts CoreAudio.
#
#   ./scripts/install.sh                  # builds if needed, installs build/Mando.app
#   ./scripts/install.sh ~/Downloads/Mando.app   # installs a downloaded release
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  SRC="$1"
else
  SRC=build/Mando.app
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
