#!/usr/bin/env bash
# ClawVault Provider — Dropbox (via rclone)
set -euo pipefail
VAULT_DIR="$HOME/.clawvault"; PROVIDER_CONFIG="$VAULT_DIR/.provider-dropbox.json"
RCLONE_REMOTE="clawvault-dropbox"; REMOTE_DIR="ClawVault"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }; log() { echo "[clawvault:dropbox $(timestamp)] $*"; }

ensure_rclone() {
  if ! command -v rclone &>/dev/null; then
    log "rclone not found. Installing..."
    case "$(uname -s)" in
      Darwin) brew install rclone 2>/dev/null || curl https://rclone.org/install.sh | bash ;;
      Linux)  curl https://rclone.org/install.sh | sudo bash ;;
    esac
  fi
}

EXCLUDE="--exclude local/** --exclude keys/** --exclude .provider-*.json --exclude .cloud-provider.json --exclude .sync-* --exclude .pull-* --exclude .heartbeat.pid --exclude .git-local/** --exclude .git/**"

cmd_setup() {
  echo ""; echo "Dropbox Setup"; echo "==============="
  echo "This will open a browser window for Dropbox OAuth."
  echo "Your vault will sync to: Dropbox / Apps / $REMOTE_DIR"
  echo ""
  ensure_rclone
  log "Starting Dropbox OAuth..."
  rclone config create "$RCLONE_REMOTE" dropbox 2>/dev/null || { log "Running interactive rclone config..."; rclone config; }
  rclone mkdir "${RCLONE_REMOTE}:${REMOTE_DIR}" 2>/dev/null || true
  cat > "$PROVIDER_CONFIG" <<JSON
{"provider":"dropbox","rclone_remote":"$RCLONE_REMOTE","remote_dir":"$REMOTE_DIR","configured":"$(timestamp)"}
JSON
  log "Dropbox configured → Apps/$REMOTE_DIR"
}

cmd_push() {
  ensure_rclone; log "Pushing to Dropbox..."
  rclone sync "$VAULT_DIR" "${RCLONE_REMOTE}:${REMOTE_DIR}" $EXCLUDE -v 2>&1 | grep -E "Transferred|Elapsed" || true
  log "Push to Dropbox complete"
}

cmd_pull() {
  ensure_rclone; local d="$VAULT_DIR/.pull-dropbox"; mkdir -p "$d"
  log "Pulling from Dropbox..."
  rclone sync "${RCLONE_REMOTE}:${REMOTE_DIR}" "$d" -v 2>&1 | grep -E "Transferred|Elapsed" || true
  for f in identity/USER.md knowledge/MEMORY.md requirements.yaml manifest.json identity/instances.yaml; do
    [[ -f "$d/$f" ]] && mkdir -p "$(dirname "$VAULT_DIR/$f")" && cp "$d/$f" "$VAULT_DIR/$f"
  done
  [[ -d "$d/knowledge/projects" ]] && mkdir -p "$VAULT_DIR/knowledge/projects" && cp -r "$d/knowledge/projects/"* "$VAULT_DIR/knowledge/projects/" 2>/dev/null || true
  rm -rf "$d"; log "Pull from Dropbox complete"
}

cmd_test() {
  ensure_rclone; log "Testing Dropbox..."
  rclone lsd "${RCLONE_REMOTE}:" &>/dev/null && log "Connected to Dropbox" || log "Cannot reach Dropbox. Re-run setup."
}

cmd_info() { [[ -f "$PROVIDER_CONFIG" ]] && echo "  Remote: Dropbox / Apps / $REMOTE_DIR (via rclone)" || echo "  Not configured"; }

case "${1:-info}" in setup) cmd_setup;; push) cmd_push;; pull) cmd_pull;; test) cmd_test;; info) cmd_info;; esac
