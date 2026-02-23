#!/usr/bin/env bash
# ClawVault Provider — Local directory (USB drive, NAS mount, shared folder)
set -euo pipefail
VAULT_DIR="$HOME/.clawvault"; PROVIDER_CONFIG="$VAULT_DIR/.provider-local.json"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }; log() { echo "[clawvault:local $(timestamp)] $*"; }

EXCLUDE="--exclude local/ --exclude keys/ --exclude .provider-*.json --exclude .cloud-provider.json --exclude .sync-* --exclude .pull-* --exclude .heartbeat.pid --exclude .git-local/ --exclude .git/"

cmd_setup() {
  echo ""; echo "Local Storage Setup"; echo "==================="
  echo "Use a USB drive, NAS mount, or any local/network directory."
  echo ""
  read -rp "Directory path (e.g. /Volumes/USB/clawvault or /mnt/nas/clawvault): " target_dir
  if [[ -z "$target_dir" ]]; then log "Path required."; return 1; fi

  if [[ ! -d "$target_dir" ]]; then
    read -rp "Directory doesn't exist. Create it? [Y/n]: " yn
    if [[ "$yn" =~ ^[Nn] ]]; then return 1; fi
    mkdir -p "$target_dir" || { log "Cannot create directory."; return 1; }
  fi

  cat > "$PROVIDER_CONFIG" <<JSON
{"provider":"local","path":"$target_dir","configured":"$(timestamp)"}
JSON
  log "Local storage configured → $target_dir"
}

_get_path() {
  python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['path'])" 2>/dev/null
}

cmd_push() {
  if [[ ! -f "$PROVIDER_CONFIG" ]]; then log "Not configured."; return 1; fi
  local target; target=$(_get_path)
  if [[ ! -d "$target" ]]; then log "Target directory not found: $target (is it mounted?)"; return 1; fi
  log "Pushing to $target..."
  rsync -a --delete $EXCLUDE "$VAULT_DIR/" "$target/" 2>&1 | tail -3
  log "Push to local complete"
}

cmd_pull() {
  if [[ ! -f "$PROVIDER_CONFIG" ]]; then log "Not configured."; return 1; fi
  local target; target=$(_get_path)
  if [[ ! -d "$target" ]]; then log "Target directory not found: $target (is it mounted?)"; return 1; fi
  log "Pulling from $target..."
  for f in identity/USER.md knowledge/MEMORY.md requirements.yaml manifest.json identity/instances.yaml; do
    [[ -f "$target/$f" ]] && mkdir -p "$(dirname "$VAULT_DIR/$f")" && cp "$target/$f" "$VAULT_DIR/$f"
  done
  [[ -d "$target/knowledge/projects" ]] && mkdir -p "$VAULT_DIR/knowledge/projects" && cp -r "$target/knowledge/projects/"* "$VAULT_DIR/knowledge/projects/" 2>/dev/null || true
  log "Pull from local complete"
}

cmd_test() {
  if [[ ! -f "$PROVIDER_CONFIG" ]]; then log "Not configured."; return 1; fi
  local target; target=$(_get_path)
  [[ -d "$target" ]] && log "Directory accessible: $target" || log "Directory NOT accessible: $target"
}

cmd_info() {
  if [[ -f "$PROVIDER_CONFIG" ]]; then
    echo "  Path: $(_get_path)"
  else echo "  Not configured"; fi
}

case "${1:-info}" in setup) cmd_setup;; push) cmd_push;; pull) cmd_pull;; test) cmd_test;; info) cmd_info;; esac
