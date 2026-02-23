#!/usr/bin/env bash
# ClawVault — Keypair Management
# Ed25519 keypair for authenticating with vault providers
# Private key in PEM format (openssl-compatible for signing)
# Public key in SSH format (for display and provider registration)
# Usage: keypair.sh {generate|show-public|fingerprint|rotate|verify|sign|push-public}

set -euo pipefail

VAULT_DIR="$HOME/.clawvault"
KEY_DIR="$VAULT_DIR/keys"
PRIVATE_KEY="$KEY_DIR/clawvault_ed25519"
PUBLIC_KEY="$KEY_DIR/clawvault_ed25519.pub"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[clawvault:keys $(timestamp)] $*"; }

# Derive SSH-format public key from PEM private key
derive_ssh_pubkey() {
  local privkey="$1" comment="${2:-clawvault}"
  local pub_der
  pub_der=$(openssl pkey -in "$privkey" -pubout -outform DER 2>/dev/null | base64)
  python3 -c "
import struct, base64, sys
der = base64.b64decode('$pub_der')
raw_pub = der[-32:]
key_type = b'ssh-ed25519'
blob = struct.pack('>I', len(key_type)) + key_type + struct.pack('>I', len(raw_pub)) + raw_pub
print(f'ssh-ed25519 {base64.b64encode(blob).decode()} $comment')
"
}

# Compute SSH-style fingerprint from the SSH public key file
ssh_fingerprint() {
  local pubfile="$1"
  local key_b64
  key_b64=$(awk '{print $2}' "$pubfile")
  python3 -c "
import base64, hashlib
data = base64.b64decode('$key_b64')
fp = base64.b64encode(hashlib.sha256(data).digest()).decode().rstrip('=')
print(f'SHA256:{fp}')
"
}

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

  local comment
  comment="clawvault@$(hostname -s 2>/dev/null || echo unknown)-$(date +%s)"

  # Generate PEM-format Ed25519 private key (openssl-compatible)
  openssl genpkey -algorithm Ed25519 -out "$PRIVATE_KEY" 2>/dev/null

  # Derive SSH-format public key
  derive_ssh_pubkey "$PRIVATE_KEY" "$comment" > "$PUBLIC_KEY"

  # Lock down permissions
  chmod 700 "$KEY_DIR"
  chmod 600 "$PRIVATE_KEY"
  chmod 644 "$PUBLIC_KEY"

  local fingerprint
  fingerprint=$(ssh_fingerprint "$PUBLIC_KEY")

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
  fingerprint=$(ssh_fingerprint "$PUBLIC_KEY")
  echo "Fingerprint: $fingerprint"
  echo ""
}

# ─── Fingerprint ──────────────────────────────────────────────

cmd_fingerprint() {
  if [[ ! -f "$PUBLIC_KEY" ]]; then
    log "No keypair found."
    return 1
  fi
  local fp
  fp=$(ssh_fingerprint "$PUBLIC_KEY")
  echo "$fp"
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

  # Verify key pair matches by deriving public from private and comparing
  local derived_pub stored_pub
  derived_pub=$(derive_ssh_pubkey "$PRIVATE_KEY" "verify-check" | awk '{print $2}')
  stored_pub=$(awk '{print $2}' "$PUBLIC_KEY")

  if [[ "$derived_pub" != "$stored_pub" ]]; then
    log "✗ Public key doesn't match private key!"
    issues=$((issues + 1))
  fi

  # Test sign/verify
  local test_file sig_file pub_pem
  test_file=$(mktemp)
  sig_file=$(mktemp)
  pub_pem=$(mktemp)
  echo "clawvault-verify-test" > "$test_file"
  openssl pkey -in "$PRIVATE_KEY" -pubout -out "$pub_pem" 2>/dev/null

  if openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$test_file" -out "$sig_file" 2>/dev/null && \
     openssl pkeyutl -verify -pubin -inkey "$pub_pem" -rawin -in "$test_file" -sigfile "$sig_file" 2>/dev/null; then
    log "✓ Signing works"
  else
    log "✗ Signing failed"
    issues=$((issues + 1))
  fi
  rm -f "$test_file" "$sig_file" "$pub_pem"

  if [[ $issues -eq 0 ]]; then
    log "✓ Keypair is healthy"
    local fingerprint
    fingerprint=$(ssh_fingerprint "$PUBLIC_KEY")
    log "  Fingerprint: $fingerprint"
  else
    log "✗ $issues issue(s) found"
  fi
}

# ─── Sign (used by cloud.sh and sync engine) ─────────────────

cmd_sign() {
  local payload="${2:-}"
  if [[ -z "$payload" ]]; then
    log "Usage: keypair.sh sign <payload_string>"
    return 1
  fi

  if [[ ! -f "$PRIVATE_KEY" ]]; then
    log "No keypair found."
    return 1
  fi

  local tmp_payload tmp_sig
  tmp_payload=$(mktemp)
  tmp_sig=$(mktemp)
  echo -n "$payload" > "$tmp_payload"
  openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$tmp_payload" -out "$tmp_sig" 2>/dev/null
  base64 -i "$tmp_sig"
  rm -f "$tmp_payload" "$tmp_sig"
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
  fingerprint=$(ssh_fingerprint "$PUBLIC_KEY")

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
