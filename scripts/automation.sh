#!/bin/sh
# Dev helper: send a JSON command to a running CrossAgent started with
# CROSSAGENT_AUTOMATION=1. Example: scripts/automation.sh '{"cmd":"new","host":"pc","mode":"shell"}'
set -eu
[ $# -eq 1 ] || { echo "usage: $0 '<json>'" >&2; exit 2; }
osascript -l JavaScript - "$1" <<'JS' >/dev/null
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately('dev.crossagent.automation', argv[0], $(), true);
}
JS
