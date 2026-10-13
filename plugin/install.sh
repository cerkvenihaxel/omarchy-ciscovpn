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
command -v xdg-open >/dev/null && ok "xdg-open present (SSO browser launcher)" || warn "xdg-open missing — SAML browser launch may fail"

# ---------------------------------------------------------------- sudoers rule
step "Passwordless root helper (sudoers)"
# Only the exact helper path, nothing else. visudo-checked before install.
TMP_SUDO="$(mktemp)"
cat > "$TMP_SUDO" <<EOF
# Installed by the Cisco VPN Omarchy plugin ($PLUGIN_ID).
# Lets $USER run ONLY the plugin's VPN root helper (openconnect up/down)
# without a password, so the bar toggle works without a prompt.
$USER ALL=(root) NOPASSWD: $ROOT_HELPER
EOF
if sudo visudo -c -f "$TMP_SUDO" >/dev/null 2>&1; then
  sudo install -m 0440 "$TMP_SUDO" "$SUDOERS_FILE" || fail "could not install sudoers rule"
  ok "sudoers rule installed at $SUDOERS_FILE"
else
  rm -f "$TMP_SUDO"
  fail "sudoers rule failed validation (visudo) — not installed"
fi
rm -f "$TMP_SUDO"

if sudo -n "$ROOT_HELPER" check >/dev/null 2>&1; then
  ok "passwordless root helper works"
else
  warn "root helper check did not pass yet — openconnect may be missing or path changed"
fi

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

# ---------------------------------------------------------------- done
step "Status"
"$CLI" status | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  state:",d["state"],"| gateway:",d["server"] or "<not set>")' 2>/dev/null || true

printf '\n%sDone.%s Click the shield icon in the bar.\n' "$c_green" "$c_off"
printf 'If no gateway is set yet, open the panel and enter your VPN hostname (e.g. vpn.company.com).\n'
printf 'Diagnostics any time: %sciscovpn doctor%s\n' "$c_blue" "$c_off"
