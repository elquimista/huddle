#!/bin/bash
# Starts the local Synapse (http://localhost:8008) and creates the test users.
# Safe to re-run. Wipe everything with: docker compose down && rm -rf data
set -euo pipefail
cd "$(dirname "$0")"
source ./dev.env

if [ ! -f data/homeserver.yaml ]; then
  docker compose run --rm -T synapse generate
  cat >> data/homeserver.yaml <<'YAML'

# --- Huddle dev overrides ---
enable_registration: false
suppress_key_server_warning: true
# No rate limits, so seeding and tests can go fast.
rc_message: { per_second: 1000, burst_count: 1000 }
rc_login:
  address: { per_second: 1000, burst_count: 1000 }
  account: { per_second: 1000, burst_count: 1000 }
  failed_attempts: { per_second: 1000, burst_count: 1000 }
rc_joins:
  local: { per_second: 1000, burst_count: 1000 }
rc_invites:
  per_room: { per_second: 1000, burst_count: 1000 }
  per_user: { per_second: 1000, burst_count: 1000 }
YAML
fi

docker compose up -d
printf 'Waiting for Synapse'
until curl -fs http://localhost:8008/health >/dev/null; do printf '.'; sleep 1; done
echo ' up'

for user in $HUDDLE_DEV_USERS $HUDDLE_DEV_EXTRA_USERS; do
  docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml \
    -u "$user" -p "$HUDDLE_DEV_PASSWORD" --no-admin http://localhost:8008 2>&1 \
    | grep -v 'already taken' || true
done
echo "Users ready: $HUDDLE_DEV_USERS $HUDDLE_DEV_EXTRA_USERS"
