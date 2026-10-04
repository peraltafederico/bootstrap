#!/usr/bin/env bash
# bootstrap.sh: join this machine to the SSH mesh. Safe to re-run; finished steps are skipped.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/peraltafederico/bootstrap/main/bootstrap.sh)"
#
# Optional environment:
#   BOOTSTRAP_HOSTNAME     tailnet name to claim (default: the system hostname)
#   BOOTSTRAP_GITHUB_USER  GitHub account whose keys form the mesh (default: peraltafederico)
set -euo pipefail

GITHUB_USER="${BOOTSTRAP_GITHUB_USER:-peraltafederico}"
RAW_URL="https://raw.githubusercontent.com/$GITHUB_USER/bootstrap/main"
BIN_DIR="$HOME/.local/bin"
KEY="$HOME/.ssh/id_ed25519"
OS="$(uname -s)"
# $USER is not set in every context (containers, some service shells).
ME="$(id -un)"
WARNINGS=()

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() {
  printf '    WARNING: %s\n' "$*"
  WARNINGS+=("$*")
}
die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# Interactive commands read from the terminal, since stdin may be the script itself.
tty_in() { "$@" < /dev/tty; }

install_pkg() {
  if command -v apt-get > /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq "$@"
  elif command -v dnf > /dev/null; then
    sudo dnf install -y -q "$@"
  elif command -v pacman > /dev/null; then
    sudo pacman -S --needed --noconfirm "$@"
  else
    die "no supported package manager found to install: $*"
  fi
}

tailscale_cli() {
  if command -v tailscale > /dev/null 2>&1; then
    command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else
    return 1
  fi
}

ensure_tailscale() {
  step "Tailscale"
  local ts
  if ! ts="$(tailscale_cli)"; then
    [ "$OS" = Linux ] || die "install the Tailscale app (https://tailscale.com/download/mac), log in, then re-run"
    info "installing"
    curl -fsSL https://tailscale.com/install.sh | sh
    ts="$(tailscale_cli)"
  fi

  if "$ts" status > /dev/null 2>&1; then
    info "already connected"
    return
  fi
  [ "$OS" = Linux ] || die "open the Tailscale app and log in, then re-run"
  info "approve this machine in the browser link printed below"
  tty_in sudo "$ts" up ${BOOTSTRAP_HOSTNAME:+--hostname "$BOOTSTRAP_HOSTNAME"}
}

ensure_ssh_server() {
  step "SSH server"
  if [ "$OS" = Darwin ]; then
    if nc -z -G 2 127.0.0.1 22 > /dev/null 2>&1; then
      info "Remote Login is on"
    else
      warn "Remote Login is off: turn it on in System Settings > General > Sharing > Remote Login"
    fi
    return
  fi

  local sshd_installed=false
  if command -v sshd > /dev/null || [ -x /usr/sbin/sshd ]; then
    sshd_installed=true
  fi
  if ! $sshd_installed; then
    info "installing"
    if command -v pacman > /dev/null; then install_pkg openssh; else install_pkg openssh-server; fi
  fi

  if ! command -v systemctl > /dev/null || [ ! -d /run/systemd/system ]; then
    warn "no systemd here: start sshd yourself"
    return
  fi
  # Debian names the unit ssh, Fedora and Arch name it sshd.
  sudo systemctl enable --now ssh 2> /dev/null || sudo systemctl enable --now sshd
  info "running and enabled at boot"
}

install_keysync() {
  step "keysync"
  mkdir -p "$BIN_DIR"
  local here="" tmp
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [ -n "$here" ] && [ -f "$here/keysync" ]; then
    install -m 755 "$here/keysync" "$BIN_DIR/keysync"
  else
    tmp="$(mktemp)"
    curl -fsSL "$RAW_URL/keysync" -o "$tmp"
    install -m 755 "$tmp" "$BIN_DIR/keysync"
    rm -f "$tmp"
  fi
  info "installed $BIN_DIR/keysync"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on PATH: add it to your shell profile to run keysync by name" ;;
  esac

  if [ "$OS" = Darwin ]; then
    schedule_launchd
  else
    schedule_systemd
  fi

  KEYSYNC_GITHUB_USER="$GITHUB_USER" "$BIN_DIR/keysync" || warn "first sync failed, the schedule will retry"
}

schedule_launchd() {
  local label="com.$GITHUB_USER.keysync"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$(dirname "$plist")" "$HOME/Library/Logs"
  cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/keysync</string></array>
  <key>EnvironmentVariables</key><dict><key>KEYSYNC_GITHUB_USER</key><string>$GITHUB_USER</string></dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/keysync.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$plist" 2> /dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  info "scheduled every 15 minutes (launchd, log: ~/Library/Logs/keysync.log)"
}

schedule_systemd() {
  if ! systemctl --user show-environment > /dev/null 2>&1; then
    warn "no systemd user session: schedule $BIN_DIR/keysync yourself (cron every 15 minutes)"
    return
  fi
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/keysync.service" << EOF
[Unit]
Description=Sync SSH authorized_keys from github.com/$GITHUB_USER.keys
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=KEYSYNC_GITHUB_USER=$GITHUB_USER
ExecStart=$BIN_DIR/keysync
EOF
  cat > "$unit_dir/keysync.timer" << 'EOF'
[Unit]
Description=Run keysync every 15 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now keysync.timer > /dev/null
  # Without lingering, user timers stop when the last session closes.
  sudo loginctl enable-linger "$ME"
  info "scheduled every 15 minutes (systemd user timer, logs: journalctl --user -u keysync)"
}

ensure_key() {
  step "SSH key"
  if [ -f "$KEY" ]; then
    info "using existing $KEY"
  else
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N "" -C "$ME@$(hostname -s)" -f "$KEY"
    info "generated $KEY"
  fi
}

publish_key() {
  step "Publish key to github.com/$GITHUB_USER.keys"
  local key_body
  key_body="$(awk '{ print $2 }' "$KEY.pub")"
  if curl -fsSL --max-time 20 "https://github.com/$GITHUB_USER.keys" | grep -qF "$key_body"; then
    info "already published"
    return
  fi

  if ! command -v gh > /dev/null; then
    info "installing GitHub CLI"
    if [ "$OS" = Darwin ]; then
      command -v brew > /dev/null || die "install Homebrew or the GitHub CLI (gh), then re-run"
      brew install gh
    else
      install_pkg gh
    fi
  fi

  # A throwaway gh login, so the key-admin token never outlives this script.
  # Global so the EXIT trap can still see it after this function returns.
  GH_TMP="$(mktemp -d)"
  trap 'rm -rf "$GH_TMP"' EXIT
  info "log in to GitHub: enter the code it prints at https://github.com/login/device"
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$GH_TMP" gh auth login \
    --hostname github.com --git-protocol ssh --skip-ssh-key --web --insecure-storage \
    --scopes admin:public_key < /dev/tty
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$GH_TMP" gh ssh-key add "$KEY.pub" --title "$(hostname -s)"
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$GH_TMP" gh auth logout --hostname github.com > /dev/null 2>&1 || true
  info "published as $(hostname -s)"
}

main() {
  [ "$(id -u)" -ne 0 ] || die "run as your normal user, not root (keys belong to your account)"
  case "$OS" in
    Linux | Darwin) ;;
    *) die "unsupported OS: $OS" ;;
  esac
  # Ask for the password up front, unless sudo already works without one. Plain `sudo -v` would
  # prompt even with NOPASSWD rules when any other rule (like the sudo group) still needs a password.
  if [ "$OS" = Linux ] && ! sudo -n true 2> /dev/null; then
    # shellcheck disable=SC2024 # the redirect is for the password prompt, not a file sudo must read
    sudo -v < /dev/tty
  fi

  ensure_tailscale
  ensure_ssh_server
  install_keysync
  ensure_key
  publish_key

  step "Done"
  info "Other machines accept this one within 15 minutes. To do it now, run this"
  info "on a machine already in the mesh:  keysync --all"
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\n    Needs attention:\n'
    printf '      - %s\n' "${WARNINGS[@]}"
  fi
}

main "$@"
