#!/bin/sh
# Starts the scripted demo sessions and a debug CrossAgent on them, for recording.
# Drive it with CROSSAGENT_AUTOMATION_ID=demo scripts/automation.sh '<json>'.
# Stop with scripts/demo/sessions.sh stop and {"cmd":"quit"}.
set -eu
cd "$(dirname "$0")/../.."
swift build
scripts/demo/sessions.sh
CROSSAGENT_DEMO=1 CROSSAGENT_AUTOMATION=1 CROSSAGENT_AUTOMATION_ID="${CROSSAGENT_AUTOMATION_ID:-demo}" \
  CROSSAGENT_NO_SETUP=1 exec .build/debug/CrossAgent
