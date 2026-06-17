#!/bin/bash
# ---------------------------------------------------------------------------
# setup.sh — one-shot environment setup for the Redis Cluster Lifecycle Tool.
#
# It makes the project run on a fresh machine by:
#   1. checking (and optionally installing) Docker/Podman + Ansible
#   2. creating an SSH key pair if you don't have one
#   3. copying your PUBLIC key into the image build context (infra/id_rsa.pub)
#   4. pointing hosts.ini at your PRIVATE key path
#
# Usage:
#   ./setup.sh           # interactive (asks before installing anything)
#   ./setup.sh --yes     # non-interactive (auto-confirm installs)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/ansible/inventory/hosts.ini"
BUILD_CTX="$SCRIPT_DIR/infra"
SSH_KEY="$HOME/.ssh/id_rsa"

ASSUME_YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=true

ok()   { echo "  [ok]   $*"; }
info() { echo "  [..]   $*"; }
warn() { echo "  [warn] $*"; }
fail() { echo "  [FAIL] $*"; exit 1; }
hr()   { echo "----------------------------------------------------------------"; }

confirm() {
  $ASSUME_YES && return 0
  local ans
  read -r -p "  >> $1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Detect the OS package manager (best-effort auto-install).
detect_pkg() {
  if   command -v apt-get &>/dev/null; then echo apt
  elif command -v dnf     &>/dev/null; then echo dnf
  elif command -v yum     &>/dev/null; then echo yum
  elif command -v brew    &>/dev/null; then echo brew
  else echo none; fi
}
PKG="$(detect_pkg)"

# version_ge A B  ->  true if A >= B  (dotted versions)
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

echo
hr; echo "  Redis Cluster Tool — environment setup"; hr
echo "  Project : $SCRIPT_DIR"
echo "  User    : $(whoami)    Home: $HOME"
echo "  Pkg mgr : $PKG"
echo

# ---------------------------------------------------------------------------
echo "[1/5] Container runtime (Docker or Podman)"
if command -v podman &>/dev/null || command -v docker &>/dev/null; then
  command -v podman &>/dev/null && ok "Podman found: $(podman --version)"
  command -v docker &>/dev/null && ok "Docker found: $(docker --version)"
else
  warn "No Docker or Podman found."
  if confirm "Install a container runtime now?"; then
    case "$PKG" in
      apt)  sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin ;;
      dnf)  sudo dnf install -y docker docker-compose-plugin ;;
      yum)  sudo yum install -y docker ;;
      brew) brew install --cask docker ;;
      *)    fail "Cannot auto-install. See https://docs.docker.com/engine/install/ or https://podman.io/docs/installation" ;;
    esac
    ok "container runtime installed"
  else
    fail "A container runtime is required. Install Docker or Podman and re-run."
  fi
fi
# Warn if the Docker daemon is not reachable (common on WSL / Docker Desktop).
if command -v docker &>/dev/null && ! docker info &>/dev/null; then
  warn "Docker is installed but the daemon isn't reachable — start Docker Desktop / dockerd."
fi

# ---------------------------------------------------------------------------
echo "[2/5] Ansible (2.14+)"
NEED_ANSIBLE=true
if command -v ansible-playbook &>/dev/null; then
  AV="$(ansible --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$AV" ]] && version_ge "$AV" "2.14.0"; then
    ok "Ansible found: $AV"; NEED_ANSIBLE=false
  else
    warn "Ansible $AV is older than 2.14."
  fi
fi
if $NEED_ANSIBLE; then
  if confirm "Install/upgrade Ansible now?"; then
    if command -v pip3 &>/dev/null; then
      pip3 install --user --upgrade 'ansible>=2.14'
    else
      case "$PKG" in
        apt)  sudo apt-get update && sudo apt-get install -y ansible ;;
        dnf)  sudo dnf install -y ansible ;;
        yum)  sudo yum install -y ansible ;;
        brew) brew install ansible ;;
        *)    fail "Cannot auto-install Ansible. Run: pip3 install 'ansible>=2.14'" ;;
      esac
    fi
    ok "Ansible installed"
  else
    fail "Ansible 2.14+ is required. Run: pip3 install 'ansible>=2.14'"
  fi
fi

# ---------------------------------------------------------------------------
echo "[3/5] SSH key pair"
if [[ -f "$SSH_KEY" ]]; then
  ok "private key exists: $SSH_KEY"
else
  info "no key at $SSH_KEY — creating one"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N ""
  ok "created $SSH_KEY"
fi
# Make sure the public key exists (derive it from the private key if needed).
if [[ ! -f "${SSH_KEY}.pub" ]]; then
  info "public key missing — regenerating from private key"
  ssh-keygen -y -f "$SSH_KEY" > "${SSH_KEY}.pub"
fi
ok "public key: ${SSH_KEY}.pub"

# ---------------------------------------------------------------------------
echo "[4/5] Copy public key into the image build context"
cp "${SSH_KEY}.pub" "$BUILD_CTX/id_rsa.pub"
ok "wrote $BUILD_CTX/id_rsa.pub  (the Containerfile COPYs this at build time)"

# ---------------------------------------------------------------------------
echo "[5/5] Point hosts.ini at your private key"
[[ -f "$HOSTS_FILE" ]] || fail "inventory not found: $HOSTS_FILE"
if grep -q '^ansible_ssh_private_key_file=' "$HOSTS_FILE"; then
  sed -i.bak "s|^ansible_ssh_private_key_file=.*|ansible_ssh_private_key_file=$SSH_KEY|" "$HOSTS_FILE"
  rm -f "${HOSTS_FILE}.bak"
  ok "set ansible_ssh_private_key_file=$SSH_KEY in hosts.ini"
else
  warn "no ansible_ssh_private_key_file line found in hosts.ini — check it manually"
fi

echo
hr; echo "  Setup complete."; hr
cat <<EOF

  Next steps:
    cd infra && docker compose up -d --build && cd ..
    ./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
    ./redis-tool data seed --keys 1000
    ./redis-tool status

EOF
