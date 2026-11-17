#!/bin/bash
# Builds and launches "Huddle Dev" against the local Synapse (dev/synapse/setup.sh).
# Its data lives in ~/Library/Application Support/Huddle Dev, separate from the release app.
#   Scripts/run-dev.sh                 # signs in the test users
#   Scripts/run-dev.sh alice/General   # ...and opens that account and room
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-app.sh debug
Scripts/build-app.sh   # Keep the release app in step with every Dev build.

set -a; source dev/synapse/dev.env; set +a
export HUDDLE_DEV_ACCOUNTS="${HUDDLE_DEV_ACCOUNTS:-${HUDDLE_DEV_USERS// /,}}"
export HUDDLE_DEV_SELECT="${1:-}"
pkill -f "Huddle Dev.app/Contents/MacOS/Huddle" 2>/dev/null || true
"build/Huddle Dev.app/Contents/MacOS/Huddle" > .build/dev.log 2>&1 &
