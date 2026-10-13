#!/usr/bin/env bash
# link.sh — deploy the Cisco VPN Omarchy plugin from this cloned repo onto the
# current machine.
#
# Usage:
#   ./link.sh            # symlink the plugin into ~/.config/omarchy/plugins
#                        # (repo stays the source of truth; `git pull` updates it)
#   ./link.sh --copy     # copy instead of symlink (repo can be deleted afterwards)
#   ./link.sh --uninstall
#
# After linking it runs the plugin's own install.sh, which installs openconnect
# (if missing), the passwordless sudoers rule for the root helper, and adds the
# widget to the bar. install.sh asks for your sudo password once.

set -uo pipefail

PLUGIN_ID="custom.ciscovpn"
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="$REPO_DIR/plugin"
DEST_DIR="$HOME/.config/omarchy/plugins"
DEST="$DEST_DIR/$PLUGIN_ID"

c_blue=$'\e[34m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_red=$'\e[31m' c_off=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_off"; }
ok()   { printf '  %s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_yellow" "$c_off" "$*"; }
fail() { printf '  %s✗%s %s\n' "$c_red" "$c_off" "$*"; exit 1; }

mode="link"
case "${1:-}" in
  --copy)      mode="copy" ;;
  --uninstall) mode="uninstall" ;;
  "" )         mode="link" ;;
  *) fail "unknown option: $1 (use --copy or --uninstall)" ;;
esac

[[ -d "$SRC" ]] || fail "plugin source not found at $SRC — run from inside the cloned repo"

if [[ "$mode" == "uninstall" ]]; then
  step "Uninstalling"
  sudo rm -f /etc/sudoers.d/omarchy-ciscovpn && ok "removed sudoers rule" || warn "could not remove sudoers rule (needs sudo)"
  sudo rm -rf /usr/local/lib/omarchy-ciscovpn && ok "removed root-owned helper" || warn "could not remove /usr/local/lib/omarchy-ciscovpn (needs sudo)"
  rm -f "$HOME/.local/bin/ciscovpn" && ok "removed CLI symlink"
  if command -v omarchy-bar >/dev/null; then
    omarchy-bar remove "$PLUGIN_ID" >/dev/null 2>&1 && ok "removed widget from bar" || warn "remove widget manually: omarchy bar remove $PLUGIN_ID"
  fi
  rm -rf "$DEST" && ok "removed $DEST"
  rm -rf "$HOME/.config/omarchy/ciscovpn" "$HOME/.local/state/omarchy/ciscovpn" && ok "removed local config/state"
  printf '\n%sUninstalled.%s\n' "$c_green" "$c_off"
  exit 0
fi

step "Deploying plugin ($mode)"
mkdir -p "$DEST_DIR"

# If something is already there, back it up unless it's our own symlink.
if [[ -e "$DEST" || -L "$DEST" ]]; then
  if [[ -L "$DEST" && "$(readlink -f "$DEST")" == "$(readlink -f "$SRC")" ]]; then
    ok "already linked to this repo"
  else
    bak="$DEST.bak-$(date +%Y%m%d%H%M%S)"
    mv "$DEST" "$bak" && warn "existing $PLUGIN_ID moved to $bak"
  fi
fi

if [[ "$mode" == "link" ]]; then
  if [[ ! -L "$DEST" ]]; then
    ln -sfn "$SRC" "$DEST" && ok "symlinked $DEST -> $SRC"
  fi
else
  rm -rf "$DEST"
  cp -a "$SRC" "$DEST" && ok "copied plugin to $DEST"
fi

chmod +x "$DEST/bin/"* "$DEST/install.sh" 2>/dev/null || true

step "Running the plugin installer (needs sudo once)"
bash "$DEST/install.sh"

printf '\n%sDone.%s The shield icon should appear on your bar.\n' "$c_green" "$c_off"
printf 'Open the panel and enter your VPN gateway hostname to finish.\n'
