#!/bin/zsh
# A header with every key. These files are read by the parser tests and never run.
#
# @openray.schemaVersion 1
# @openray.title Toggle Wi-Fi
# @openray.mode silent
# @openray.icon 📶
# @openray.description Turns Wi-Fi on or off
# @openray.keywords wifi network   airport
# @openray.argument1 {"placeholder":"SSID","optional":true}
# @openray.argument2 {"placeholder":"Password"}
# @openray.timeout 30
# @openray.needsConfirmation true

echo "Wi-Fi: $1"
