# Cisco VPN — Omarchy bar plugin

Connect to a **Cisco Secure Client / AnyConnect** VPN with **SAML single sign-on
(CyberArk)** straight from the Omarchy top bar. A shield icon shows the live
connection state; click it to connect, disconnect, and set your gateway.

It uses the open-source [`openconnect`](https://www.infradead.org/openconnect/)
client — which speaks the Cisco Secure Client (AnyConnect) protocol — instead of
the proprietary Cisco client. SSO is handled by openconnect's
`--external-browser` flow: on connect, your system browser opens the CyberArk
IdP, you log in, and openconnect receives the SAML token and brings up the
tunnel.

## Install

```bash
bash ~/.config/omarchy/plugins/custom.ciscovpn/install.sh
```

The installer (idempotent) will:

1. install `openconnect` if it's missing,
2. add a tight `sudoers.d` rule so the bar can run *only* this plugin's root
   helper (openconnect up/down) without a password prompt,
3. symlink the `ciscovpn` CLI into `~/.local/bin` and add the widget to the bar.

It does **not** install the proprietary Cisco client or touch unrelated software.

## Use

- Click the shield icon → panel opens.
- Enter your VPN gateway hostname (the one you'd type into Cisco Secure Client,
  e.g. `vpn.company.com`) and press **Save**.
- Click **Connect with SSO** → your browser opens for CyberArk login.
- Right-click the bar icon = quick connect/disconnect toggle.

### Icon states

| Glyph | Color | Meaning |
|-------|-------|---------|
| 󰞀 | accent | connected |
| 󰦞 | foreground (pulsing) | connecting / signing in |
| 󰦝 | dimmed | disconnected |
| 󰚌 | urgent | error |

## CLI

```bash
ciscovpn status        # JSON connection state
ciscovpn config        # JSON saved gateway/protocol
ciscovpn set-server H  # save gateway host
ciscovpn connect       # start SSO connect (opens a terminal + browser)
ciscovpn disconnect    # tear down the tunnel
ciscovpn doctor        # human-readable diagnostics
```

## Notes

- The Cisco Secure Client installer that was reverse-engineered to build this is
  the generic web-deploy package: it ships the client binaries but **no company
  profile**, so the gateway hostname is not embedded anywhere — you supply it in
  the panel.
- `openconnect` needs root only to configure the tunnel device; that's the sole
  job of `bin/ciscovpn-root`, whitelisted by the sudoers rule. The SAML browser
  is always launched as your user.
- If your gateway needs an auth group / tunnel group, append it to the host as
  `host/group`, or add extra openconnect flags via
  `~/.config/omarchy/ciscovpn/config.json` (`extraArgs`).

## Uninstall

```bash
sudo rm -f /etc/sudoers.d/omarchy-ciscovpn
rm -f ~/.local/bin/ciscovpn
omarchy bar remove custom.ciscovpn
rm -rf ~/.config/omarchy/plugins/custom.ciscovpn ~/.config/omarchy/ciscovpn ~/.local/state/omarchy/ciscovpn
```
