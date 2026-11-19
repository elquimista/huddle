#!/bin/bash
# Starts the local Synapse (http://localhost:8008) and creates the test users, with the call
# server Element Call needs beside it (LiveKit, and lk-jwt-service at http://localhost:8091).
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

# --- Calls (Element Call, MatrixRTC) ---
public_baseurl: "http://localhost:8008/"
# Delayed events (MSC4140): a call membership that ends itself if the client goes away.
max_event_delay_duration: 24h
rc_delayed_event_mgmt: { per_second: 1000, burst_count: 1000 }
experimental_features:
  msc4143_enabled: true
  # The push rule that makes a ring (m.rtc.notification) notify the person rung.
  msc4075_enabled: true
matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: http://localhost:8091
extra_well_known_client_content:
  org.matrix.msc4143.rtc_foci:
    - type: livekit
      livekit_service_url: http://localhost:8091
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
