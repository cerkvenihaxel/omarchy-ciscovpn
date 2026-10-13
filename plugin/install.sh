#!/usr/bin/env bash
# One-time (idempotent) setup for the Cisco VPN Omarchy plugin (custom.ciscovpn).
#
# Run it in a terminal — it asks for your sudo password once:
#   bash ~/.config/omarchy/plugins/custom.ciscovpn/install.sh
#
# What it does (all steps are safe to re-run):
#   1. installs `openconnect` (the open-source Cisco AnyConnect/Secure Client
#      compatible client) if it isn't present.
#   2. installs a tight sudoers rule so the bar can run ONLY the plugin's root
#      helper (openconnect connect/disconnect) without a password prompt.
#   3. puts the `ciscovpn` CLI on your PATH and the widget on the bar.
#
# It does NOT install the proprietary Cisco Secure Client, and does not touch
# any unrelated software.

set -uo pipefail

PLUGIN_ID="custom.ciscovpn"
PLUGIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CLI="$PLUGIN_DIR/bin/ciscovpn"
ROOT_HELPER="$PLUGIN_DIR/bin/ciscovpn-root"
SUDOERS_FILE="/etc/sudoers.d/omarchy-ciscovpn"

c_blue=$'\e[34m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_red=$'\e[31m' c_off=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_off"; }
ok()   { printf '  %s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_yellow" "$c_off" "$*"; }
fail() { printf '  %s✗%s %s\n' "$c_red" "$c_off" "$*"; exit 1; }

chmod +x "$CLI" "$ROOT_HELPER" 2>/dev/null || true

# ---------------------------------------------------------------- packages
step "openconnect"
if command -v openconnect >/dev/null; then
  ok "openconnect present ($(openconnect --version 2>/dev/null | head -1))"
else
  if command -v pacman >/dev/null; then
    sudo pacman -S --needed --noconfirm openconnect || fail "could not install openconnect"
  else
    fail "openconnect missing and no pacman found — install it with your package manager"
  fi
  ok "openconnect installed"
fi
command -v xdg-open >/dev/null && ok "xdg-open present" || warn "xdg-open missing"

# ---------------------------------------------------------------- SAML webview deps
step "SAML SSO webview (single-sign-on-v2)"
# This gateway family uses Cisco's single-sign-on-v2 (embedded SAMLv2) flow,
# which native openconnect --external-browser cannot drive. bin/ciscovpn-saml
# does the login in a Qt WebEngine window and reuses the proven protocol code
# from the openconnect_sso package. We need that package importable + PyQt6
# WebEngine.
if python3 -c "import openconnect_sso, PyQt6.QtWebEngineWidgets" >/dev/null 2>&1; then
  ok "openconnect_sso + PyQt6 WebEngine present"
else
  warn "SAML webview deps missing."
  echo "    Install from the AUR (uses system PyQt6, works on current Python):"
  echo "      yay -S openconnect-sso"
  echo "    (pulls python-pyqt6-webengine and the openconnect_sso module this plugin reuses)"
  if command -v yay >/dev/null; then
    read -rp "    Install openconnect-sso with yay now? [y/N] " ans
    if [[ "${ans,,}" == y* ]]; then
      yay -S --needed openconnect-sso && ok "openconnect-sso installed" || warn "yay install failed — install manually"
    fi
  fi
fi

# ---------------------------------------------------------------- sudoers rule
step "Privilege model"
# By design this plugin installs NO passwordless sudoers rule and NO standing
# root grant. Each connect/disconnect runs the privileged helper through an
# interactive `sudo` in a terminal, so you authorize the action with your
# password every time. If an old passwordless rule from a previous version is
# present, remove it now.
if [[ -f /etc/sudoers.d/omarchy-ciscovpn ]]; then
  sudo rm -f /etc/sudoers.d/omarchy-ciscovpn && ok "removed a legacy passwordless sudoers rule" \
    || warn "could not remove /etc/sudoers.d/omarchy-ciscovpn (remove it manually)"
fi
if [[ -d /usr/local/lib/omarchy-ciscovpn ]]; then
  sudo rm -rf /usr/local/lib/omarchy-ciscovpn && ok "removed a legacy root-owned helper copy" \
    || warn "could not remove /usr/local/lib/omarchy-ciscovpn (remove it manually)"
fi
ok "no standing root grant — connect/disconnect prompt for sudo in a terminal"

# ---------------------------------------------------------------- CLI + bar
step "CLI and bar widget"
mkdir -p "$HOME/.local/bin"
ln -sfn "$CLI" "$HOME/.local/bin/ciscovpn"
ok "~/.local/bin/ciscovpn -> plugin"

if grep -q "\"$PLUGIN_ID\"" "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
  ok "widget already on the bar"
else
  if command -v omarchy-bar >/dev/null; then
    omarchy-bar put "$PLUGIN_ID" --before omarchy.network >/dev/null 2>&1 \
      || omarchy-bar put "$PLUGIN_ID" >/dev/null 2>&1 \
      && ok "widget added to the bar" \
      || warn "could not add automatically; run: omarchy bar put $PLUGIN_ID"
  else
    warn "omarchy-bar not found; add manually: omarchy bar put $PLUGIN_ID"
  fi
fi

# ---------------------------------------------------------------- harden state
step "Private state directory"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/ciscovpn"
CONFIG_SUBDIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ciscovpn"
mkdir -p "$STATE_DIR" "$CONFIG_SUBDIR"
chmod 0700 "$STATE_DIR" "$CONFIG_SUBDIR"
# Older builds could log the SSO auth XML (which contains the live session
# token). Remove any such logs so stale credentials don't linger on disk.
if [[ -f "$STATE_DIR/connect.log" ]] && grep -qa 'session-token\|sso-token' "$STATE_DIR/connect.log" 2>/dev/null; then
  shred -u "$STATE_DIR/connect.log" 2>/dev/null || rm -f "$STATE_DIR/connect.log"
  ok "scrubbed an old log that contained SSO token material"
else
  ok "state dir is private (0700); no credential leak in logs"
fi

# ---------------------------------------------------------------- done
step "Status"
"$CLI" status | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  state:",d["state"],"| gateway:",d["server"] or "<not set>")' 2>/dev/null || true

printf '\n%sDone.%s Click the shield icon in the bar.\n' "$c_green" "$c_off"
printf 'If no gateway is set yet, open the panel and enter your VPN hostname (e.g. vpn.company.com).\n'
printf 'Diagnostics any time: %sciscovpn doctor%s\n' "$c_blue" "$c_off"
