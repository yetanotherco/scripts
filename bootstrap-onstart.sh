#!/bin/bash
# Vast.ai provisioning script for lambda_vm work.
# Idempotent — safe to re-run.
#
# Designed to be loaded via Vast's PROVISIONING_SCRIPT mechanism. In your Vast
# template's Environment Variables section, set:
#
#   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/yetanotherco/scripts/main/bootstrap-onstart.sh
#   GITHUB_SSH_KEY_B64=<single-line base64 of your GitHub-authorized private key>
#
# Generate the key value on your laptop with:
#   base64 -i ~/.ssh/vast_lambda_vm | tr -d '\n' | pbcopy   # macOS
#   base64 -w0 ~/.ssh/vast_lambda_vm                        # Linux (no wrap)
#
# Security note: env vars are stored in Vast instance metadata in plaintext and
# are visible to any process on the instance via /proc/<pid>/environ. Don't put
# long-lived high-privilege keys in here — prefer a fine-grained, expiring
# deploy key.
cd /workspace/
set -euo pipefail

log() { printf '\n=== %s ===\n' "$*"; }

# --- 1. authorized_keys --------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
AUTHORIZED_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFzvQKhE/xqRxHbit/dZNej7T5eVLmF8CAGL7to6o3QY joaquin@mail.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA2GAeixuqP4XwujuSK9KDgdmyglGzlQQsXztnve+bra gabriel@mail.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKQnPPUb4gzmsmjDP98mNKXbpHrp9bIIL7QiRjyWEG6f julian@mail.com"
)
AUTH_FILE="$HOME/.ssh/authorized_keys"
touch "$AUTH_FILE"
chmod 600 "$AUTH_FILE"
if [ -s "$AUTH_FILE" ] && [ -n "$(tail -c 1 "$AUTH_FILE")" ]; then
  printf '\n' >> "$AUTH_FILE"
fi
for key in "${AUTHORIZED_KEYS[@]}"; do
  if ! grep -qxF "$key" "$AUTH_FILE"; then
    printf '%s\n' "$key" >> "$AUTH_FILE"
    log "added authorized key: ${key##* }"
  fi
done

# --- 2. apt deps -------------------------------------------------------------
log "apt deps (clang, lld, build tools, curl, git)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential pkg-config libssl-dev \
  clang lld llvm \
  curl git ca-certificates xz-utils

# --- 3. Rust 1.94.0 + nightly-2026-02-01 -------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
  log "installing rustup + 1.94.0"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain 1.94.0 --profile default
fi
export PATH="$HOME/.cargo/bin:$PATH"
grep -q 'cargo/env' "$HOME/.bashrc" 2>/dev/null \
  || echo '. "$HOME/.cargo/env"' >> "$HOME/.bashrc"

log "ensuring nightly-2026-02-01 with rust-src (for build-std)"
rustup toolchain install nightly-2026-02-01 --profile minimal --component rust-src

log "ensuring rust-analyzer component on default toolchain"
rustup component add rust-analyzer

# --- 4. GitHub CLI -----------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  log "installing gh (GitHub CLI)"
  (type -p wget >/dev/null || (apt-get update && apt-get install wget -y)) \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && cat "$out" | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install gh -y
fi

# --- 5. Claude Code ----------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"
if ! command -v claude >/dev/null 2>&1; then
  log "installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
fi
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null \
  || printf '%s\n' "$PATH_LINE" >> "$HOME/.bashrc"

# --- 6. lambda-vm sysroot (rv64im) -------------------------------------------
SYSROOT_DIR=/opt/lambda-vm-sysroot
SYSROOT_URL=https://lambda.alignedlayer.com/lambda-vm-sysroot-rv64im.tar.gz
if [ ! -d "$SYSROOT_DIR" ]; then
  log "downloading sysroot to $SYSROOT_DIR"
  curl -L "$SYSROOT_URL" -o /tmp/sysroot.tar.gz
  mkdir -p /opt
  tar -xzf /tmp/sysroot.tar.gz -C /opt
  rm /tmp/sysroot.tar.gz
fi

# --- 7. ethrex test fixture --------------------------------------------------
ETHREX_FILE=/workspace/lambda_vm/executor/tests/ethrex_hoodi.bin
ETHREX_URL=https://lambda.alignedlayer.com/ethrex_hoodi.bin
if [ -d /workspace/lambda_vm/executor/tests ] && [ ! -f "$ETHREX_FILE" ]; then
  log "downloading ethrex_hoodi.bin"
  curl -L "$ETHREX_URL" -o "$ETHREX_FILE"
fi

# --- 8. SSH / repo setup -----------------------------------------------------
GH_SSH_KEY_STORE=/workspace/vast_lambda_vm
GH_SSH_KEY_LIVE="$HOME/.ssh/vast_lambda_vm"
mkdir -p /workspace

# 8a. Materialize the GitHub SSH private key from $GITHUB_SSH_KEY_B64 if the
# file isn't already on disk (e.g. on first boot).
if [ ! -f "$GH_SSH_KEY_STORE" ] && [ -n "${GITHUB_SSH_KEY_B64:-}" ]; then
  log "decoding GITHUB_SSH_KEY_B64 -> $GH_SSH_KEY_STORE"
  printf '%s' "$GITHUB_SSH_KEY_B64" | base64 -d > "$GH_SSH_KEY_STORE"
  chmod 600 "$GH_SSH_KEY_STORE"
fi

# 8b. Symlink + ssh config + known_hosts for git@github.com.
if [ -f "$GH_SSH_KEY_STORE" ]; then
  chmod 600 "$GH_SSH_KEY_STORE"
  if [ ! -L "$GH_SSH_KEY_LIVE" ] || [ "$(readlink -f "$GH_SSH_KEY_LIVE")" != "$GH_SSH_KEY_STORE" ]; then
    rm -f "$GH_SSH_KEY_LIVE"
    ln -s "$GH_SSH_KEY_STORE" "$GH_SSH_KEY_LIVE"
    log "GitHub SSH key symlinked: $GH_SSH_KEY_LIVE -> $GH_SSH_KEY_STORE"
  fi

  SSH_CONFIG="$HOME/.ssh/config"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  if ! grep -q '^Host github.com' "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile $GH_SSH_KEY_LIVE
  IdentitiesOnly yes
EOF
    log "added github.com block to $SSH_CONFIG"
  fi

  KNOWN_HOSTS="$HOME/.ssh/known_hosts"
  touch "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
  if ! ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> "$KNOWN_HOSTS" 2>/dev/null || true
    log "added github.com to known_hosts"
  fi
else
  log "no GitHub SSH key at $GH_SSH_KEY_STORE and \$GITHUB_SSH_KEY_B64 unset — skipping git@github.com setup"
fi

# 8c. Clone lambda_vm if it isn't already on disk.
REPO_DIR=/workspace/lambda_vm
REPO_URL=git@github.com:yetanotherco/lambda_vm.git
if [ ! -d "$REPO_DIR/.git" ] && [ -f "$GH_SSH_KEY_STORE" ]; then
  log "cloning lambda_vm to $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi

# --- 9. cudarc feature pin for driver < 13.0 ---------------------------------
CARGO_TOML=/workspace/lambda_vm/crypto/math-cuda/Cargo.toml
if [ -f "$CARGO_TOML" ] && command -v nvidia-smi >/dev/null 2>&1; then
  DRV_MAJOR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)
  if [ -n "${DRV_MAJOR:-}" ] && [ "$DRV_MAJOR" -lt 580 ]; then
    if grep -q '"cuda-13010"' "$CARGO_TOML"; then
      log "pinning cudarc to cuda-12080 (driver $DRV_MAJOR < 580)"
      sed -i 's/"cuda-13010"/"cuda-12080"/' "$CARGO_TOML"
    fi
  fi
fi

log "done"
