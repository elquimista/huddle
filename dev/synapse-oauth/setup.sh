#!/bin/bash
# Starts the OAuth homeserver and creates its test user. Safe to re-run.
# Wipe everything with: docker compose down && rm -rf data
set -euo pipefail
cd "$(dirname "$0")"
source ./dev.env
MAS_IMAGE=ghcr.io/element-hq/matrix-authentication-service:latest

if [ ! -f data/mas/config.yaml ]; then
  mkdir -p data/mas
  docker run --rm "$MAS_IMAGE" config generate > data/mas/config.yaml
  SECRET="$(openssl rand -hex 32)"
  cat > data/mas/override.yaml <<YAML
http:
  public_base: http://localhost:8081/
  issuer: http://localhost:8081/
database:
  uri: postgresql://mas:mas@postgres/mas
matrix:
  kind: synapse
  homeserver: oauth.localhost
  endpoint: http://synapse:8008
  secret: "$SECRET"
YAML
  docker compose run --rm -T synapse generate
  cat >> data/synapse/homeserver.yaml <<YAML

# --- Huddle dev overrides ---
suppress_key_server_warning: true
public_baseurl: http://localhost:8009/
matrix_authentication_service:
  enabled: true
  endpoint: http://mas:8080/
  secret: "$SECRET"
YAML
fi

docker compose up -d
printf 'Waiting for Synapse and MAS'
until curl -fs http://localhost:8009/health >/dev/null && curl -fs http://localhost:8081/.well-known/openid-configuration >/dev/null; do printf '.'; sleep 1; done
echo ' up'

for user in $HUDDLE_OAUTH_USERS; do
  docker compose exec -T mas mas-cli manage register-user --yes --no-admin \
    --ignore-password-complexity --password "$HUDDLE_OAUTH_PASSWORD" "$user" 2>&1 \
    | grep -iE 'created|exists|taken|error' || true
done
echo "Users ready: $HUDDLE_OAUTH_USERS"
