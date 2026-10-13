# omarchy-ciscovpn

Connect to a **Cisco Secure Client / AnyConnect** VPN with **SAML single sign-on
(CyberArk)** from the [Omarchy](https://omarchy.org) top bar. A shield icon shows
the live connection state; click it to connect, disconnect, and set your gateway.

It uses the open-source [`openconnect`](https://www.infradead.org/openconnect/)
client (which speaks the Cisco Secure Client / AnyConnect protocol) instead of
the proprietary Cisco client. SSO happens in your **system browser** via
openconnect's `--external-browser` flow: on connect your browser opens the
CyberArk IdP, you log in, and openconnect receives the SAML token and builds the
tunnel.

> Built for the Omarchy Quickshell bar (the shell under `/usr/share/omarchy/shell`).

---

## Quick start (this machine)

```bash
# from a clone of this repo
./link.sh
```

`link.sh` symlinks the plugin into `~/.config/omarchy/plugins/custom.ciscovpn`
and runs its installer (installs `openconnect` if missing, adds a tight
passwordless `sudoers` rule for the root helper, and puts the widget on the bar).
It asks for your sudo password once.

Then:

1. Click the **shield icon** on the bar → the panel opens.
2. Type your VPN gateway hostname (e.g. `vpn-ssl.telecom.com.ar`) → **Save**.
3. Click **Connect with SSO** → a terminal opens and your browser opens for
   CyberArk login. Finish the login in the browser.

Right-click the bar icon = quick connect/disconnect toggle.

---

## Distribute to your own repo and install on another machine

### 1. Publish from this machine

```bash
cd "omarchy-ciscovpn"
git init -b main
git add .
git commit -m "feat: Omarchy Cisco VPN plugin (SAML/CyberArk via openconnect)"

# create an EMPTY repo on your host first (no README), then:
git remote add origin git@github.com:<you>/omarchy-ciscovpn.git   # or GitLab/HTTPS
git push -u origin main
```

> The big proprietary Cisco installer is **git-ignored** and never pushed. See
> `.gitignore`.

### 2. Install on another Omarchy machine

```bash
git clone git@github.com:<you>/omarchy-ciscovpn.git
cd omarchy-ciscovpn
./link.sh                 # symlink + install (git pull keeps it updated)
# or:
./link.sh --copy          # copy instead of symlink (repo can be removed after)
```

Open the panel, enter that machine's gateway host, connect.

### 3. Update later

```bash
cd omarchy-ciscovpn
git pull
./link.sh                 # re-runs the installer (idempotent)
```

### Uninstall

```bash
./link.sh --uninstall
```

---

## Requirements

- Omarchy with the Quickshell bar (`/usr/share/omarchy/shell`).
- `openconnect` **v9.17+** (SAML external-browser support). v9.21 verified.
  `link.sh`/`install.sh` install it via `pacman` if missing.
- A gateway that advertises SAML **external-browser** SSO (Cisco ASA/FTD 9.17+).
- A browser registered as the `xdg-open` default.

## What's in here

```
omarchy-ciscovpn/
├── README.md          ← this file (quick start + distribution)
├── DOCS.md            ← architecture, reverse-engineering notes, troubleshooting
├── LICENSE            ← MIT (+ openconnect LGPL / Cisco proprietary notes)
├── link.sh            ← deploy on any machine from a clone (symlink/copy/uninstall)
├── .gitignore
└── plugin/            ← the plugin itself (what gets linked into Omarchy)
    ├── manifest.json  ← Omarchy plugin manifest (bar-widget)
    ├── Panel.qml      ← the bar icon + popout UI
    ├── install.sh     ← per-plugin installer (openconnect, sudoers, bar entry)
    ├── README.md      ← plugin-local usage notes
    └── bin/
        ├── ciscovpn       ← user-side CLI/backend (status, connect, config, …)
        └── ciscovpn-root  ← the only part that runs as root (openconnect up/down)
```

See **[DOCS.md](DOCS.md)** for how it works, how it was reverse-engineered, the
privilege model, and troubleshooting (including the `sudo: a password is
required` case).

## License

MIT. Uses OpenConnect (LGPL-2.1), installed from your distro — not bundled.
The Cisco Secure Client software and installer are proprietary to Cisco and are
**not** included in or distributed by this repository.
