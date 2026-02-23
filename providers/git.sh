#!/usr/bin/env bash
# ClawVault Provider — Git (auto-commit + push with Ed25519 key)
set -euo pipefail
VAULT_DIR="$HOME/.clawvault"; REPO_DIR="$VAULT_DIR/.git-local"
PROVIDER_CONFIG="$VAULT_DIR/.provider-git.json"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }; log() { echo "[clawvault:git $(timestamp)] $*"; }

_git() { GIT_SSH_COMMAND="ssh -i $VAULT_DIR/keys/clawvault_ed25519 -o StrictHostKeyChecking=no" git -C "$REPO_DIR" "$@"; }

cmd_setup() {
  echo ""; echo "🐙 Git Remote Setup"; echo "━━━━━━━━━━━━━━━━━━━"
  read -rp "Git remote URL (SSH or HTTPS): " remote_url
  read -rp "Branch [main]: " branch; branch="${branch:-main}"

  if [[ -z "$remote_url" ]]; then log "URL required."; return 1; fi

  echo ""; echo "Add this deploy key to your repo (read/write access):"
  echo "────────────────────────────────"
  cat "$VAULT_DIR/keys/clawvault_ed25519.pub" 2>/dev/null
  echo "────────────────────────────────"
  echo ""; read -rp "Press Enter once the key is added..."

  # Clone or init
  if [[ -d "$REPO_DIR/.git" ]]; then
    _git remote set-url origin "$remote_url" 2>/dev/null || _git remote add origin "$remote_url"
  else
    git clone "$remote_url" "$REPO_DIR" 2>/dev/null || {
      mkdir -p "$REPO_DIR"; git -C "$REPO_DIR" init; git -C "$REPO_DIR" checkout -b "$branch"
      git -C "$REPO_DIR" remote add origin "$remote_url"
    }
  fi

  cat > "$PROVIDER_CONFIG" <<JSON
{"provider":"git","remote_url":"$remote_url","branch":"$branch","configured":"$(timestamp)"}
JSON
  log "✓ Git configured → $remote_url ($branch)"
}

cmd_push() {
  if [[ ! -f "$PROVIDER_CONFIG" ]]; then log "Not configured."; return 1; fi
  local branch
  branch=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['branch'])" 2>/dev/null || echo "main")

  # Sync vault contents to git repo (exclude local-only)
  rsync -a --delete \
    --exclude '.git' \
    "$VAULT_DIR/identity/" "$REPO_DIR/identity/" 2>/dev/null; mkdir -p "$REPO_DIR/identity"
  rsync -a --delete "$VAULT_DIR/knowledge/" "$REPO_DIR/knowledge/" 2>/dev/null; mkdir -p "$REPO_DIR/knowledge"
  [[ -f "$VAULT_DIR/requirements.yaml" ]] && cp "$VAULT_DIR/requirements.yaml" "$REPO_DIR/"
  [[ -f "$VAULT_DIR/manifest.json" ]] && cp "$VAULT_DIR/manifest.json" "$REPO_DIR/"

  # Auto-commit
  _git add -A
  if _git diff --cached --quiet 2>/dev/null; then
    log "No changes to push"
    return 0
  fi

  local hostname_str
  hostname_str=$(hostname -s 2>/dev/null || echo "unknown")
  _git commit -m "vault sync $(timestamp) from $hostname_str" --quiet

  # Push
  _git push origin "$branch" --quiet 2>/dev/null && log "✓ Pushed to git" || {
    _git push origin "$branch" --force-with-lease --quiet 2>/dev/null && log "✓ Force-pushed to git" || log "⚠ Push failed"
  }
}

cmd_pull() {
  if [[ ! -f "$PROVIDER_CONFIG" ]]; then log "Not configured."; return 1; fi
  local branch
  branch=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['branch'])" 2>/dev/null || echo "main")

  _git fetch origin "$branch" --quiet 2>/dev/null
  _git reset --hard "origin/$branch" --quiet 2>/dev/null || _git pull origin "$branch" --quiet 2>/dev/null

  # Merge into vault
  for f in identity/USER.md knowledge/MEMORY.md requirements.yaml manifest.json identity/instances.yaml; do
    [[ -f "$REPO_DIR/$f" ]] && mkdir -p "$(dirname "$VAULT_DIR/$f")" && cp "$REPO_DIR/$f" "$VAULT_DIR/$f"
  done
  [[ -d "$REPO_DIR/knowledge/projects" ]] && mkdir -p "$VAULT_DIR/knowledge/projects" && \
    cp -r "$REPO_DIR/knowledge/projects/"* "$VAULT_DIR/knowledge/projects/" 2>/dev/null || true

  # Save vault requirements for diff
  [[ -f "$REPO_DIR/requirements.yaml" ]] && cp "$REPO_DIR/requirements.yaml" "$VAULT_DIR/.vault-requirements.yaml"
  log "✓ Pulled from git"
}

cmd_test() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then log "Not configured."; return 1; fi
  _git fetch --dry-run 2>/dev/null && log "✓ Git remote reachable" || log "✗ Cannot reach remote"
}

cmd_info() {
  if [[ -f "$PROVIDER_CONFIG" ]]; then
    local url branch
    url=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['remote_url'])" 2>/dev/null)
    branch=$(python3 -c "import json;print(json.load(open('$PROVIDER_CONFIG'))['branch'])" 2>/dev/null)
    echo "  Remote: $url ($branch)"
    if [[ -d "$REPO_DIR/.git" ]]; then
      local count; count=$(_git rev-list --count HEAD 2>/dev/null || echo "0")
      echo "  Commits: $count"
    fi
  else echo "  Not configured"; fi
}

case "${1:-info}" in setup) cmd_setup;; push) cmd_push;; pull) cmd_pull;; test) cmd_test;; info) cmd_info;; esac
