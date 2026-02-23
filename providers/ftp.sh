#!/usr/bin/env bash
# ClawVault Provider — FTP / SFTP
set -euo pipefail
VAULT_DIR="$HOME/.clawvault"; PROVIDER_CONFIG="$VAULT_DIR/.provider-ftp.json"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }; log() { echo "[clawvault:ftp $(timestamp)] $*"; }
EXCLUDE="--exclude local/ --exclude keys/ --exclude .provider-*.json --exclude .cloud-provider.json --exclude .sync-* --exclude .pull-* --exclude .heartbeat.pid --exclude .git-local/"

cmd_setup() {
  echo ""; echo "🔗 FTP/SFTP Setup"; echo "━━━━━━━━━━━━━━━━━"
  read -rp "Protocol [sftp]: " proto; proto="${proto:-sftp}"
  read -rp "Host: " host; read -rp "Port [22]: " port; port="${port:-22}"
  read -rp "Username: " user; read -rp "Remote path [/clawvault]: " rpath; rpath="${rpath:-/clawvault}"
  echo ""
  echo "Authentication: your ClawVault Ed25519 key will be used."
  echo "Add this public key to your server's authorized_keys:"
  echo "────────────────────────────────"
  cat "$VAULT_DIR/keys/clawvault_ed25519.pub" 2>/dev/null
  echo "────────────────────────────────"

  cat > "$PROVIDER_CONFIG" <<JSON
{"provider":"ftp","protocol":"$proto","host":"$host","port":$port,"user":"$user","path":"$rpath","configured":"$(timestamp)"}
JSON
  log "✓ ${proto^^} configured → $user@$host:$rpath"
}

_load() {
  proto=$(python3 -c "import json;d=json.load(open('$PROVIDER_CONFIG'));print(d['protocol'])" 2>/dev/null)
  host=$(python3 -c "import json;d=json.load(open('$PROVIDER_CONFIG'));print(d['host'])" 2>/dev/null)
  port=$(python3 -c "import json;d=json.load(open('$PROVIDER_CONFIG'));print(d['port'])" 2>/dev/null)
  user=$(python3 -c "import json;d=json.load(open('$PROVIDER_CONFIG'));print(d['user'])" 2>/dev/null)
  rpath=$(python3 -c "import json;d=json.load(open('$PROVIDER_CONFIG'));print(d['path'])" 2>/dev/null)
}

cmd_push() {
  _load; local key="$VAULT_DIR/keys/clawvault_ed25519"
  log "Pushing via $proto to $host..."
  rsync -avz -e "ssh -i $key -p $port -o StrictHostKeyChecking=no" \
    $EXCLUDE "$VAULT_DIR/" "$user@$host:$rpath/" 2>&1 | tail -3
  log "✓ Push complete"
}

cmd_pull() {
  _load; local key="$VAULT_DIR/keys/clawvault_ed25519"
  local d="$VAULT_DIR/.pull-ftp"; mkdir -p "$d"
  log "Pulling via $proto from $host..."
  rsync -avz -e "ssh -i $key -p $port -o StrictHostKeyChecking=no" \
    --exclude local/ "$user@$host:$rpath/" "$d/" 2>&1 | tail -3
  for f in identity/USER.md knowledge/MEMORY.md requirements.yaml manifest.json; do
    [[ -f "$d/$f" ]] && mkdir -p "$(dirname "$VAULT_DIR/$f")" && cp "$d/$f" "$VAULT_DIR/$f"
  done
  [[ -d "$d/knowledge/projects" ]] && cp -r "$d/knowledge/projects/"* "$VAULT_DIR/knowledge/projects/" 2>/dev/null || true
  rm -rf "$d"; log "✓ Pull complete"
}

cmd_test() {
  _load; local key="$VAULT_DIR/keys/clawvault_ed25519"
  ssh -i "$key" -p "$port" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$user@$host" "ls $rpath" &>/dev/null \
    && log "✓ Connected to $host" || log "✗ Connection failed"
}

cmd_info() { [[ -f "$PROVIDER_CONFIG" ]] && _load && echo "  Remote: $proto://$user@$host:$port$rpath" || echo "  Not configured"; }

case "${1:-info}" in setup) cmd_setup;; push) cmd_push;; pull) cmd_pull;; test) cmd_test;; info) cmd_info;; esac
