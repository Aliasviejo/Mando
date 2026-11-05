#!/bin/bash
# Removes Mando completely.
set -euo pipefail
pkill -x Mando 2>/dev/null || true
rm -rf /Applications/Mando.app
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Mando.driver
sudo killall -9 coreaudiod 2>/dev/null || true
echo "Mando removed."
