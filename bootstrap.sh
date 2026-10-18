#!/usr/bin/env bash
# bootstrap.sh: join this machine to the SSH mesh. Safe to re-run; finished steps are skipped.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/peraltafederico/bootstrap/main/bootstrap.sh)"
#
# Optional environment:
#   BOOTSTRAP_HOSTNAME     tailnet name to claim (default: the system hostname)
#   BOOTSTRAP_GITHUB_USER  GitHub account whose keys form the mesh (default: peraltafederico)
#   BOOTSTRAP_AGENT_SYNC   0 skips the Syncthing step for agent config, 1 forces it
#                          (default: skip only on AGENT_SYNC_SKIP_HOSTS)
set -euo pipefail

GITHUB_USER="${BOOTSTRAP_GITHUB_USER:-peraltafederico}"
RAW_URL="https://raw.githubusercontent.com/$GITHUB_USER/bootstrap/main"
BIN_DIR="$HOME/.local/bin"
KEY="$HOME/.ssh/id_ed25519"
OS="$(uname -s)"
# $USER is not set in every context (containers, some service shells).
ME="$(id -un)"
# Minimal installs may lack `hostname`; uname works everywhere.
HOST="$(uname -n)"
HOST="${HOST%%.*}"
WARNINGS=()
# Tailnet names that never get agent config sync: the Air MacBook is a work machine.
AGENT_SYNC_SKIP_HOSTS="airs-macbook-pro"

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

allow_ssh_in_firewall() {
  # When ufw denies incoming traffic, open SSH on the tailnet only, not on whatever Wi-Fi a
  # laptop happens to join.
  local ufw_active=false
  if command -v ufw > /dev/null && sudo ufw status 2> /dev/null | grep -q '^Status: active'; then
    ufw_active=true
  fi
  if $ufw_active; then
    sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH over tailnet' > /dev/null
    info "ufw: allowed SSH on tailscale0 only"
  fi
}

# Installs a file from this repo: the local checkout when run from one, else GitHub.
install_repo_file() {
  local name=$1 dest=$2 mode=$3 here="" tmp
  mkdir -p "$(dirname "$dest")"
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [ -n "$here" ] && [ -f "$here/$name" ]; then
    install -m "$mode" "$here/$name" "$dest"
  else
    tmp="$(mktemp)"
    curl -fsSL "$RAW_URL/$name" -o "$tmp"
    install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
  fi
}

install_tool() {
  local name=$1
  install_repo_file "$name" "$BIN_DIR/$name" 755
  info "installed $BIN_DIR/$name"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on PATH: add it to your shell profile to run $name by name" ;;
  esac
}

install_keysync() {
  step "keysync"
  install_tool keysync

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
    ssh-keygen -q -t ed25519 -N "" -C "$ME@$HOST" -f "$KEY"
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

  if gh_publish; then
    info "published as $HOST"
  else
    # Inbound SSH already works at this point, so a trusted machine can finish the job.
    warn "could not publish the key automatically. Add $KEY.pub at https://github.com/settings/ssh/new, or from a trusted machine: ssh $HOST cat .ssh/id_ed25519.pub | gh ssh-key add - --title $HOST"
  fi
}

gh_publish() {
  if ! command -v gh > /dev/null; then
    info "installing GitHub CLI"
    if [ "$OS" = Darwin ]; then
      command -v brew > /dev/null && brew install gh || return 1
    else
      install_pkg gh || return 1
    fi
  fi

  # A throwaway gh login, so the key-admin token never outlives this script.
  # Global so the EXIT trap can still see it after this function returns.
  GH_TMP="$(mktemp -d)"
  trap 'rm -rf "$GH_TMP"' EXIT
  local status=0
  info "log in to GitHub: enter the code it prints at https://github.com/login/device"
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$GH_TMP" gh auth login \
    --hostname github.com --git-protocol ssh --skip-ssh-key --web --insecure-storage \
    --scopes admin:public_key < /dev/tty \
    && env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$GH_TMP" gh ssh-key add "$KEY.pub" --title "$HOST" \
    || status=$?
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$GH_TMP" gh auth logout --hostname github.com > /dev/null 2>&1 || true
  return "$status"
}

require_ssh_keys() {
  step "Key-only SSH"
  local conf=/etc/ssh/sshd_config.d/10-keys-only.conf
  local wanted='PasswordAuthentication no
KbdInteractiveAuthentication no'
  # Turning passwords off before any trusted key is in place would lock everyone out.
  local keys_in_place=false
  if grep -q '^# >>> keysync' "$HOME/.ssh/authorized_keys" 2> /dev/null \
    && grep -Eq '^(ssh-|ecdsa-|sk-)' "$HOME/.ssh/authorized_keys"; then
    keys_in_place=true
  fi
  if ! $keys_in_place; then
    warn "no synced keys yet: leaving SSH password login on, re-run once keysync works"
    return
  fi

  if [ "$(sudo cat "$conf" 2> /dev/null)" = "$wanted" ]; then
    info "already on"
    return
  fi
  printf '%s\n' "$wanted" | sudo tee "$conf" > /dev/null
  sudo chmod 644 "$conf"
  # A broken config would keep sshd from starting, so validate before it takes effect.
  if ! sudo sshd -t; then
    sudo rm -f "$conf"
    warn "sshd rejected the key-only config, so it was removed and password login stays on"
    return
  fi
  # macOS starts sshd per connection, so only Linux needs a reload.
  if [ "$OS" = Linux ]; then
    if [ ! -d /run/systemd/system ]; then
      warn "no systemd here: restart sshd yourself to apply key-only login"
      return
    fi
    sudo systemctl reload ssh 2> /dev/null || sudo systemctl reload sshd
  fi
  info "SSH password login is off, keys only"
}

install_syncthing() {
  if command -v syncthing > /dev/null; then
    info "syncthing already installed"
  elif [ "$OS" = Darwin ]; then
    command -v brew > /dev/null || return 1
    brew install -q syncthing
  elif command -v apt-get > /dev/null; then
    # Debian and Ubuntu still ship Syncthing 1.x; the official repo matches the Macs' 2.x.
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo curl -fsSL -o /etc/apt/keyrings/syncthing-archive-keyring.gpg https://syncthing.net/release-key.gpg
    echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable-v2" \
      | sudo tee /etc/apt/sources.list.d/syncthing.list > /dev/null
    install_pkg syncthing
  else
    install_pkg syncthing
  fi

  if [ "$OS" = Darwin ]; then
    brew services start syncthing > /dev/null
  else
    systemctl --user show-environment > /dev/null 2>&1 || return 1
    systemctl --user enable --now syncthing.service > /dev/null 2>&1
    sudo loginctl enable-linger "$ME"
  fi
}

# Points $2 at relative target $1. Symlinks are replaced; real files and folders are left alone.
link_relative() {
  local target=$1 link=$2
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$target" ] && return
    rm "$link"
  elif [ -e "$link" ]; then
    warn "$link is a real file or folder, not linking it to $target"
    return
  fi
  ln -s "$target" "$link"
  info "linked $link -> $target"
}

# Codex reads Claude's instructions and skills through relative links, so they work under any home.
link_codex() {
  local skills="$HOME/.codex/skills" entry
  mkdir -p "$HOME/.codex"
  link_relative ../.claude/CLAUDE.md "$HOME/.codex/AGENTS.md"

  if [ -d "$skills" ] && [ ! -L "$skills" ]; then
    # Only links from the old sync-codex layout and Codex's built-ins (.system) can be moved aside.
    for entry in "$skills"/* "$skills"/.[!.]*; do
      if [ -e "$entry" ] && [ ! -L "$entry" ] && [ "$(basename "$entry")" != .system ]; then
        warn "$skills has a real skill, $(basename "$entry"): move it into ~/.claude/skills, then re-run"
        return
      fi
    done
    find "$skills" -mindepth 1 -maxdepth 1 -type l -delete
    if [ -d "$skills/.system" ]; then
      rm -rf "$HOME/.claude/skills/.system"
      mv "$skills/.system" "$HOME/.claude/skills/.system"
    fi
    rmdir "$skills"
  fi
  link_relative ../.claude/skills "$skills"
}

# Shares ~/.claude's portable config (CLAUDE.md, skills, agents, memories) with the other machines.
ensure_agent_sync() {
  step "Agent config sync (Syncthing)"
  local tailnet_name
  tailnet_name="$("$(tailscale_cli)" status --peers=false 2> /dev/null | awk 'NR==1 { print $2 }' || true)"
  case "${BOOTSTRAP_AGENT_SYNC:-auto}" in
    0)
      info "skipped (BOOTSTRAP_AGENT_SYNC=0)"
      return
      ;;
    auto)
      if [[ " $AGENT_SYNC_SKIP_HOSTS " == *" ${tailnet_name:-none} "* ]]; then
        info "skipped on $tailnet_name (set BOOTSTRAP_AGENT_SYNC=1 to force)"
        return
      fi
      ;;
  esac
  if ! install_syncthing; then
    warn "could not install or start Syncthing (macOS needs Homebrew, Linux a systemd user session)"
    return
  fi

  # The ignore list must be in place before the folder exists, or everything in ~/.claude would sync.
  mkdir -p "$HOME/.claude/skills"
  install_repo_file claude.stignore "$HOME/.claude/.stignore" 644

  local tries=0
  until syncthing cli show system > /dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      warn "Syncthing did not answer after 30 seconds, re-run to finish its setup"
      return
    fi
    sleep 1
  done
  local c=(syncthing cli config)
  # Peers are dialed on their tailnet address, so nothing goes through public discovery or relays.
  "${c[@]}" options global-ann-enabled set false
  "${c[@]}" options relays-enabled set false
  "${c[@]}" options natenabled set false
  "${c[@]}" options uraccepted set -- -1
  if ! "${c[@]}" folders list | grep -qx claude; then
    "${c[@]}" folders add --id claude --label claude --path "$HOME/.claude" --type sendreceive
  fi
  "${c[@]}" folders claude versioning type set staggered
  info "folder claude = ~/.claude, old versions kept in ~/.claude/.stversions"

  local link
  for link in "$HOME/.claude/skills"/*; do
    if [ -L "$link" ] && [[ "$(readlink "$link")" == /* ]]; then
      warn "$link is an absolute symlink: replace it with the real folder before pairing, or the dead link syncs everywhere"
    fi
  done

  link_codex

  local id ip
  id="$(syncthing device-id)"
  ip="$("$(tailscale_cli)" ip -4 2> /dev/null | head -1 || true)"
  [ -n "$ip" ] || ip="<tailnet-ip>"
  info "to pair, run these on a machine already syncing, then the same here with its id, name and ip:"
  info "  syncthing cli config devices add --device-id $id --name $HOST --addresses tcp://$ip:22000"
  info "  syncthing cli config folders claude devices add --device-id $id"
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
  [ "$OS" = Darwin ] || allow_ssh_in_firewall
  install_keysync
  step "wake"
  install_tool wake
  ensure_key
  publish_key
  require_ssh_keys
  ensure_agent_sync

  step "Done"
  info "Other machines accept this one within 15 minutes. To do it now, run this"
  info "on a machine already in the mesh:  keysync --all"
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\n    Needs attention:\n'
    printf '      - %s\n' "${WARNINGS[@]}"
  fi
}

main "$@"
