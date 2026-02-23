#!/usr/bin/env bash
# ClawVault — Keypair Management
# Ed25519 keypair for authenticating with vault providers
# Usage: keypair.sh {generate|show-public|fingerprint|rotate|verify}

set -euo pipefail

VAULT_DIR="$HOME/.clawvault"
KEY_DIR="$VAULT_DIR/keys"
PRIVATE_KEY="$KEY_DIR/clawvault_ed25519"
PUBLIC_KEY="$KEY_DIR/clawvault_ed25519.pub"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[clawvault:keys $(timestamp)] $*"; }

# ─── Generate ─────────────────────────────────────────────────

cmd_generate() {
  mkdir -p "$KEY_DIR"

  if [[ -f "$PRIVATE_KEY" ]]; then
    log "Keypair already exists."
    log "  Public key: $PUBLIC_KEY"
    log "  Use 'keypair.sh rotate' to regenerate."
    return 0
  fi

  log "Generating Ed25519 keypair..."

  # Generate keypair — no passphrase (agent needs unattended access)
  # Security comes from file permissions + the fact that only this
  # machine's agent can use it
  ssh-keygen -t ed25519 \
    -f "$PRIVATE_KEY" \
    -N "" \
    -C "clawvault@$(hostname -s 2>/dev/null || echo unknown)-$(date +%s)" \
    -q

  # Lock down permissions
  chmod 700 "$KEY_DIR"
  chmod 600 "$PRIVATE_KEY"
  chmod 644 "$PUBLIC_KEY"

  local fingerprint
  fingerprint=$(ssh-keygen -lf "$PUBLIC_KEY" 2>/dev/null | awk '{print $2}')

  log "✓ Keypair generated"
  log "  Private key: $PRIVATE_KEY (600 — never share this)"
  log "  Public key:  $PUBLIC_KEY"
  log "  Fingerprint: $fingerprint"
  echo ""
  echo "Public key (add this to your vault provider):"
  echo "────────────────────────────────────────────────"
  cat "$PUBLIC_KEY"
  echo "────────────────────────────────────────────────"
}

# ─── Show Public ──────────────────────────────────────────────

cmd_show_public() {
  if [[ ! -f "$PUBLIC_KEY" ]]; then
    log "No keypair found. Run 'keypair.sh generate' first."
    return 1
  fi

  echo ""
  echo "ClawVault Public Key"
  echo "━━━━━━━━━━━━━━━━━━━━"
  cat "$PUBLIC_KEY"
  echo ""

  local fingerprint
  fingerprint=$(ssh-keygen -lf "$PUBLIC_KEY" 2>/dev/null | awk '{print $2}')
  echo "Fingerprint: $fingerprint"
  echo ""
}

# ─── Fingerprint ──────────────────────────────────────────────

cmd_fingerprint() {
  if [[ ! -f "$PUBLIC_KEY" ]]; then
    log "No keypair found."
    return 1
  fi
  ssh-keygen -lf "$PUBLIC_KEY" 2>/dev/null
}

# ─── Rotate ───────────────────────────────────────────────────

cmd_rotate() {
  if [[ ! -f "$PRIVATE_KEY" ]]; then
    log "No existing keypair. Generating new one..."
    cmd_generate
    return $?
  fi

  echo ""
  echo "⚠  Key rotation will:"
  echo "   1. Archive your current keypair"
  echo "   2. Generate a new Ed25519 keypair"
  echo "   3. You'll need to re-register with your vault provider"
  echo ""
  read -rp "Continue? [y/N]: " yn
  if [[ ! "$yn" =~ ^[Yy] ]]; then
    log "Rotation cancelled."
    return 0
  fi

  # Archive old key
  local archive_dir="$KEY_DIR/archived"
  mkdir -p "$archive_dir"
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  mv "$PRIVATE_KEY" "$archive_dir/clawvault_ed25519.$ts"
  mv "$PUBLIC_KEY" "$archive_dir/clawvault_ed25519.$ts.pub"
  log "Old keypair archived to $archive_dir/"

  # Generate new
  cmd_generate

  echo ""
  log "⚠ Remember to update your public key with your vault provider!"
  log "  For ClawVault Cloud: clawvault.sh cloud update-key"
  log "  For Git: add the new public key to your repo's deploy keys"
  log "  For others: re-run 'clawvault.sh provider <name>'"
}

# ─── Verify ───────────────────────────────────────────────────

cmd_verify() {
  if [[ ! -f "$PRIVATE_KEY" || ! -f "$PUBLIC_KEY" ]]; then
    log "✗ Keypair not found"
    return 1
  fi

  # Check permissions
  local priv_perms
  priv_perms=$(stat -f "%OLp" "$PRIVATE_KEY" 2>/dev/null || stat -c "%a" "$PRIVATE_KEY" 2>/dev/null)

  local issues=0

  if [[ "$priv_perms" != "600" ]]; then
    log "⚠ Private key permissions are $priv_perms (should be 600)"
    log "  Fix: chmod 600 $PRIVATE_KEY"
    issues=$((issues + 1))
  fi

  # Verify key pair matches
  local priv_pub pub_pub
  priv_pub=$(ssh-keygen -yf "$PRIVATE_KEY" 2>/dev/null)
  pub_pub=$(cat "$PUBLIC_KEY" 2>/dev/null)

  if [[ "$priv_pub" != "$pub_pub" ]]; then
    log "✗ Public key doesn't match private key!"
    issues=$((issues + 1))
  fi

  # Test sign/verify
  local test_file
  test_file=$(mktemp)
  echo "clawvault-verify-test" > "$test_file"

  if ssh-keygen -Y sign -f "$PRIVATE_KEY" -n clawvault "$test_file" &>/dev/null; then
    log "✓ Signing works"
  else
    log "✗ Signing failed"
    issues=$((issues + 1))
  fi
  rm -f "$test_file" "$test_file.sig"

  if [[ $issues -eq 0 ]]; then
    log "✓ Keypair is healthy"
    local fingerprint
    fingerprint=$(ssh-keygen -lf "$PUBLIC_KEY" 2>/dev/null | awk '{print $2}')
    log "  Fingerprint: $fingerprint"
  else
    log "✗ $issues issue(s) found"
  fi
}

# ─── Sign a file (used by sync engine) ───────────────────────

cmd_sign() {
  local file="${2:-}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    log "Usage: keypair.sh sign <file>"
    return 1
  fi

  if [[ ! -f "$PRIVATE_KEY" ]]; then
    log "No keypair found."
    return 1
  fi

  # Create signature
  openssl pkeyutl -sign \
    -inkey "$PRIVATE_KEY" \
    -rawin \
    -in <(shasum -a 256 "$file" | awk '{print $1}') \
    2>/dev/null | base64 || {
    # Fallback: use ssh-keygen signing
    ssh-keygen -Y sign -f "$PRIVATE_KEY" -n clawvault "$file" 2>/dev/null
    cat "$file.sig" 2>/dev/null
    rm -f "$file.sig"
  }
}

# ─── Push Public Key ──────────────────────────────────────────

cmd_push_public() {
  if [[ ! -f "$PUBLIC_KEY" ]]; then
    log "No keypair found. Run 'keypair.sh generate' first."
    return 1
  fi

  local instance_id hostname_str fingerprint
  instance_id=$(grep 'instance_id:' "$VAULT_DIR/config.yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
  hostname_str=$(hostname -s 2>/dev/null || echo "unknown")
  fingerprint=$(ssh-keygen -lf "$PUBLIC_KEY" 2>/dev/null | awk '{print $2}')

  mkdir -p "$VAULT_DIR/identity/public-keys"

  local dest="$VAULT_DIR/identity/public-keys/${hostname_str}.pub"
  cp "$PUBLIC_KEY" "$dest"

  log "Public key pushed to vault"
  log "  Stored as: identity/public-keys/${hostname_str}.pub"
  log "  Fingerprint: $fingerprint"
  log "  Instance: $instance_id"
}

# ─── Main ─────────────────────────────────────────────────────

case "${1:-show-public}" in
  generate)     cmd_generate ;;
  show-public)  cmd_show_public ;;
  fingerprint)  cmd_fingerprint ;;
  rotate)       cmd_rotate ;;
  verify)       cmd_verify ;;
  sign)         cmd_sign "$@" ;;
  push-public)  cmd_push_public ;;
  *)            echo "Usage: keypair.sh {generate|show-public|fingerprint|rotate|verify|push-public|sign}"; exit 1 ;;
esac
