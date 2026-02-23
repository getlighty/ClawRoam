#!/usr/bin/env bash
# ClawVault Provider — S3-compatible storage (via rclone)
set -euo pipefail
VAULT_DIR="$HOME/.clawvault"; PROVIDER_CONFIG="$VAULT_DIR/.provider-s3.json"
RCLONE_REMOTE="clawvault-s3"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }; log() { echo "[clawvault:s3 $(timestamp)] $*"; }

ensure_rclone() {
  if ! command -v rclone &>/dev/null; then
    log "rclone not found. Installing..."
    case "$(uname -s)" in Darwin) brew install rclone 2>/dev/null || curl https://rclone.org/install.sh | bash ;; Linux) curl https://rclone.org/install.sh | sudo bash ;; esac
  fi
}

EXCLUDE="--exclude local/** --exclude keys/** --exclude .provider-*.json --exclude .cloud-provider.json --exclude .sync-* --exclude .pull-* --exclude .heartbeat.pid --exclude .git-local/** --exclude .git/**"

cmd_setup() {
  echo ""; echo "S3 Storage Setup"; echo "================"
  read -rp "S3 endpoint URL (leave blank for AWS): " endpoint
  read -rp "Bucket name: " bucket
  read -rp "Access Key ID: " access_key
  read -rsp "Secret Access Key: " secret_key; echo ""
  read -rp "Region [us-east-1]: " region; region="${region:-us-east-1}"
  read -rp "Path prefix [clawvault]: " prefix; prefix="${prefix:-clawvault}"

  if [[ -z "$bucket" || -z "$access_key" || -z "$secret_key" ]]; then
    log "Bucket, access key, and secret key are required."; return 1
  fi

  ensure_rclone
  local extra_args=""
  [[ -n "$endpoint" ]] && extra_args="endpoint=$endpoint provider=Other"
  rclone config create "$RCLONE_REMOTE" s3 \
    access_key_id="$access_key" secret_access_key="$secret_key" \
    region="$region" $extra_args 2>/dev/null || { log "Running interactive rclone config..."; rclone config; }

  cat > "$PROVIDER_CONFIG" <<JSON
{"provider":"s3","bucket":"$bucket","prefix":"$prefix","region":"$region","endpoint":"$endpoint","configured":"$(timestamp)"}
JSON
  log "S3 configured → $bucket/$prefix"
}

_remote_path() {
  local bucket prefix
  bucket=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['bucket'])" 2>/dev/null)
  prefix=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['prefix'])" 2>/dev/null)
  echo "${RCLONE_REMOTE}:${bucket}/${prefix}"
}

cmd_push() {
  ensure_rclone; log "Pushing to S3..."
  rclone sync "$VAULT_DIR" "$(_remote_path)" $EXCLUDE -v 2>&1 | grep -E "Transferred|Elapsed" || true
  log "Push to S3 complete"
}

cmd_pull() {
  ensure_rclone; local d="$VAULT_DIR/.pull-s3"; mkdir -p "$d"
  log "Pulling from S3..."
  rclone sync "$(_remote_path)" "$d" -v 2>&1 | grep -E "Transferred|Elapsed" || true
  for f in identity/USER.md knowledge/MEMORY.md requirements.yaml manifest.json identity/instances.yaml; do
    [[ -f "$d/$f" ]] && mkdir -p "$(dirname "$VAULT_DIR/$f")" && cp "$d/$f" "$VAULT_DIR/$f"
  done
  [[ -d "$d/knowledge/projects" ]] && mkdir -p "$VAULT_DIR/knowledge/projects" && cp -r "$d/knowledge/projects/"* "$VAULT_DIR/knowledge/projects/" 2>/dev/null || true
  rm -rf "$d"; log "Pull from S3 complete"
}

cmd_test() {
  ensure_rclone; log "Testing S3..."
  rclone lsd "$(_remote_path)" &>/dev/null && log "Connected to S3" || log "Cannot reach S3. Check credentials."
}

cmd_info() {
  if [[ -f "$PROVIDER_CONFIG" ]]; then
    local bucket prefix
    bucket=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['bucket'])" 2>/dev/null || echo "?")
    prefix=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['prefix'])" 2>/dev/null || echo "?")
    echo "  Remote: s3://$bucket/$prefix (via rclone)"
  else echo "  Not configured"; fi
}

case "${1:-info}" in setup) cmd_setup;; push) cmd_push;; pull) cmd_pull;; test) cmd_test;; info) cmd_info;; esac
