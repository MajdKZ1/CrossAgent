#!/bin/sh
# Dev helper, debug builds only (swift build): release builds have no automation
# channel. Sends a JSON command to a running debug CrossAgent started with
# CROSSAGENT_AUTOMATION=1. Example: scripts/automation.sh '{"cmd":"new","host":"pc","mode":"shell"}'
# Set CROSSAGENT_AUTOMATION_ID to reach only the instance started with the same value.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 '<json>'" >&2; exit 2; }
NAME="dev.crossagent.automation${CROSSAGENT_AUTOMATION_ID:+.$CROSSAGENT_AUTOMATION_ID}"
osascript -l JavaScript - "$1" "$NAME" <<'JS' >/dev/null
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(argv[1], argv[0], $(), true);
}
JS
