#!/bin/bash
# Installs PaneAudio.driver into the system Core Audio plug-in folder and restarts Core Audio.
# Sound pauses for a second while Core Audio restarts. Needs an administrator password.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$ROOT/../dist/PaneAudio.driver"
[ -d "$DRIVER" ] || "$ROOT/build.sh"

osascript -e "do shell script \"rm -rf /Library/Audio/Plug-Ins/HAL/PaneAudio.driver && cp -R '$DRIVER' /Library/Audio/Plug-Ins/HAL/ && killall coreaudiod\" with administrator privileges with prompt \"Pane wants to install its audio output.\""
echo "Installed. \"Pane\" should now appear in System Settings > Sound > Output."
