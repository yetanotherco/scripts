#!/bin/bash
# Vast.ai provisioning script for lambda_vm work.
# Idempotent — safe to re-run.
#
# Designed to be loaded via Vast's PROVISIONING_SCRIPT mechanism. In your Vast
# template's Environment Variables section, set:
#
#   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/yetanotherco/scripts/main/bootstrap-onstart.sh
#
# No credentials are needed: lambda_vm is public and is cloned over HTTPS.
# Never put keys or tokens in template env vars — they are stored in Vast
# instance metadata in plaintext and visible to any process on the instance
# via /proc/<pid>/environ.
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

# --- 8. repo clone -----------------------------------------------------------
# lambda_vm is public: plain HTTPS, no credentials on the box.
REPO_DIR=/workspace/lambda_vm
REPO_URL=https://github.com/yetanotherco/lambda_vm.git
mkdir -p /workspace
if [ ! -d "$REPO_DIR/.git" ]; then
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
