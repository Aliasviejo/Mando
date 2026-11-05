#!/bin/bash
# Installs the driver (needs your password) and the app, then restarts CoreAudio.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d build/Mando.driver && -d build/Mando.app ]] || ./scripts/build.sh

echo "==> Installing audio driver (macOS will ask for your password)"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Mando.driver
sudo cp -R build/Mando.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/Mando.driver
sudo killall -9 coreaudiod 2>/dev/null || true

echo "==> Installing app"
pkill -x Mando 2>/dev/null || true
rm -rf /Applications/Mando.app
cp -R build/Mando.app /Applications/
sleep 2
open /Applications/Mando.app
echo "==> Done. Look for the dial icon in the menu bar."
