# DOCS — omarchy-ciscovpn

Technical documentation: how the plugin works, how it was reverse-engineered
from the Cisco Secure Client installer, the privilege model, and troubleshooting.

---

## 1. Overview

The goal: connect to a Cisco Secure Client (AnyConnect) VPN that uses **SAML SSO
through CyberArk**, from the Omarchy Quickshell bar, with a status icon that
matches the Omarchy design.

We do **not** use the proprietary Cisco client to make the connection. Instead we
drive [`openconnect`](https://www.infradead.org/openconnect/) — the mature
open-source client that implements the Cisco AnyConnect/Secure Client protocol
and, since v9.17, supports SAML SSO via an **external (system) browser**.

```
┌────────────────────┐   status/connect/disconnect (JSON)   ┌─────────────────┐
│ Panel.qml (bar UI) │ ───────────────────────────────────► │ bin/ciscovpn    │
│  shield icon +     │ ◄─────────────────────────────────── │ (user backend)  │
│  popout panel      │              state polling            └────────┬────────┘
└────────────────────┘                                                │ sudo
                                                                       ▼
                                                        ┌──────────────────────────┐
                                                        │ bin/ciscovpn-root (root)  │
                                                        │   runs: openconnect       │
                                                        │   --protocol=anyconnect   │
                                                        │   --external-browser=SHIM │
                                                        └──────────┬────────────────┘
                                   SSO URL (as root)               │
                                                                   ▼
                                           SHIM → ciscovpn _browser <URL>
                                                                   │ drop to user
                                                                   ▼
                                                   xdg-open <URL>  →  CyberArk login
```

---

## 2. Reverse-engineering the Cisco installer

The source artifact was the generic installer:
`cisco-secure-client-linux64-5.1.7.80-core-vpn-webdeploy-k9.sh`.

### 2.1 Structure

It's a **self-extracting POSIX shell script** with a gzipped tar appended. The
script locates the archive between text markers and extracts it:

```sh
MARKER=$((`grep -an "[B]EGIN ARCHIVE" $0 | cut -d ":" -f 1` + 1))
MARKER_END=$((`grep -an "[E]ND ARCHIVE" $0 | cut -d ":" -f 1` - 1))
head -n ${MARKER_END} $0 | tail -n +${MARKER} | head -c -1 > ${TARFILE}
tar xvzf ${TARFILE} -C ${TEMPDIR}
```

To extract it yourself (read-only, no install):

```sh
SRC=cisco-secure-client-linux64-5.1.7.80-core-vpn-webdeploy-k9.sh
MARKER=$(( $(grep -an "[B]EGIN ARCHIVE" "$SRC" | cut -d: -f1) + 1 ))
MARKER_END=$(( $(grep -an "[E]ND ARCHIVE" "$SRC" | cut -d: -f1) - 1 ))
head -n "$MARKER_END" "$SRC" | tail -n +"$MARKER" | head -c -1 > archive.tgz
mkdir out && tar xzf archive.tgz -C out
```

### 2.2 What's inside (and what's not)

The archive contains the client binaries and libraries (`vpn`, `vpnui`,
`vpnagentd`, `libvpnapi.so`, `libacciscossl.so`, …), the systemd unit, the
uninstaller, and:

- `ACManifestVPN.xml` — version manifest only.
- `AnyConnectProfile.xsd`, `AnyConnectLocalPolicy.xsd` — profile **schemas**.

**Key finding:** this web-deploy package contains **no company VPN profile** —
there is no `ServerList`/`HostAddress` XML with your gateway. The real client
receives the profile from the VPN head-end on first connect, or the user types
the gateway in. So the gateway hostname is **not** recoverable from the installer
and must be supplied by the user (the panel's "VPN gateway" field).

### 2.3 Consequence for this plugin

Because there's nothing machine-specific to extract, the plugin doesn't need the
Cisco binaries at all. It only needs:

- the **gateway hostname** (user-provided),
- the **protocol** (`anyconnect`),
- `openconnect` to speak that protocol and do SAML SSO.

That is why the proprietary installer is git-ignored and not required at runtime.

---

## 3. The SAML / SSO connection flow

openconnect connects in two phases: (1) authenticate and obtain a cookie, then
(2) build the tunnel with that cookie.

With a SAML gateway that advertises `single-sign-on-external-browser`:

1. `openconnect --protocol=anyconnect --external-browser=<SHIM> <gateway>` contacts
   the gateway and is told to do external-browser SSO.
2. openconnect launches `<SHIM> <SSO-URL>`.
3. The shim forwards to `ciscovpn _browser <URL>`, which opens the URL **as your
   user** with `xdg-open` → your browser shows the CyberArk login.
4. You authenticate (and MFA, if any) in the browser.
5. The IdP redirects back; openconnect captures the SAML token, exchanges it for
   the VPN cookie, and brings up the tunnel (`tun`/`vpn` interface).

openconnect must run as **root** to create the tunnel device — this is the only
privileged part (see §5).

### Protocol / tunnel-group notes

- Default protocol is `anyconnect`. Override in
  `~/.config/omarchy/ciscovpn/config.json` (`"protocol"`).
- If your gateway needs a tunnel/auth group, append it to the host as
  `host/group`, or add openconnect flags via the `"extraArgs"` config key.

---

## 4. Component reference

### 4.1 `plugin/manifest.json`

Omarchy plugin manifest. Validated by the shell's `PluginRegistry`:
`schemaVersion: 1`; required `id`, `name`, `version`, `kinds`, `entryPoints`;
`kinds: ["bar-widget"]`; `entryPoints.barWidget: "Panel.qml"`;
`barWidget.defaultSection: "right"`.

### 4.2 `plugin/Panel.qml`

The bar widget. Extends the shell's `qs.Ui.Panel`, uses `qs.Ui` controls
(`BarIconButton`, `PanelHero`, `Button`, `TextField`, `PanelSeparator`) and
`qs.Commons` theming (`Style`, `Color`) so it tracks the active Omarchy theme.

- **Bar icon**: a Nerd Font shield glyph whose color/opacity encodes state —
  accent when connected, foreground + pulse while connecting, dimmed when
  disconnected, urgent on error.
- **Popout**: hero header with live state, Connect / Disconnect buttons, a
  gateway host field + Save, a message line, and a Diagnostics button.
- **IPC**: registers target `custom.ciscovpn` with `open/close/toggle/show/hide/
  connect/disconnect/refresh`.
- **Backend calls**: `Quickshell.Io.Process` runs `bin/ciscovpn <cmd>` and parses
  the JSON it prints. A timer polls `status` (faster while connecting/open).

> The property that tracks connection state is `vpnState`, deliberately **not**
> `state` — `state` is a reserved `QQuickItem` property and shadowing it breaks
> QML state handling.

### 4.3 `plugin/bin/ciscovpn` (user side)

Prints JSON (except `doctor`). Commands:

| Command | Purpose |
|---------|---------|
| `status` | connection state from pid/state files (no root) |
| `config` | saved gateway/protocol as JSON |
| `set-server HOST` | save gateway (strips scheme + `/path`) |
| `connect` | open a styled terminal and start the SSO flow |
| `disconnect` | tear down the tunnel |
| `doctor` | human-readable diagnostics |
| `_run-connect` | *internal*: the actual connect, run inside the terminal |
| `_browser URL` | *internal*: `--external-browser` target; opens URL as the user |

State lives in `~/.local/state/omarchy/ciscovpn/` (`state`, `openconnect.pid`,
`server`, `connect.log`). Config in `~/.config/omarchy/ciscovpn/config.json`.

### 4.4 `plugin/bin/ciscovpn-root` (root side)

The only code that runs as root, kept tiny with a fixed argument shape so the
sudoers rule can whitelist it precisely:

```
ciscovpn-root connect <server> <protocol> <browser-handler> <pidfile> <user> [extra]
ciscovpn-root disconnect <pidfile>
ciscovpn-root check
```

It writes a per-connection shim for `--external-browser`, exports `SUDO_USER`/
`CISCOVPN_USER` so the browser can be opened as the real user, then `exec`s
openconnect.

---

## 5. Privilege model

openconnect needs root **only** to create/configure the tunnel device. Nothing
else in the plugin runs as root.

**No standing root grant.** This plugin installs **no** passwordless `sudoers`
rule. Each connect and disconnect runs the privileged helper through an
**interactive `sudo` in a terminal**, so you authorize the action with your
password every time. This is a deliberate security choice: a `NOPASSWD` entry
is a permanent, unattended path to root for your account, and on a security
workstation that standing exposure is not worth skipping a password prompt.
`install.sh` actively removes any legacy passwordless rule / root-owned helper
copy from earlier versions.

- **Interactive privilege only.** `ciscovpn connect`/`disconnect` open a terminal
  (`omarchy-launch-tui`) and call `sudo "$PLUGIN_DIR/bin/ciscovpn-root" …`. You
  see and approve the privileged step; nothing runs as root unattended.

- **Strict input validation in the root helper.** Every argument from the
  caller is validated before use: `server` against a hostname regex, `protocol`
  against an allowlist, `pidfile` must live under the caller's own state dir (no
  path traversal), `fingerprint` against a hex/pin format. A **server
  certificate pin is required** — the helper refuses to connect without one, so
  there is no silent cert-validation bypass.

- **No caller free-form arguments reach root.** There is no `extraArgs`
  passthrough to the root `openconnect` command; the root command line is a
  fixed, audited set of flags only.

- **The SAML session cookie never touches disk or argv.** It is read from stdin
  by the root helper and passed to `openconnect --cookie-on-stdin`. The SSO
  helper's debug logging (which includes the live session token in the auth
  XML) is suppressed below ERROR, so the credential is never written to the log.

- **Private state.** `~/.local/state/omarchy/ciscovpn` and
  `~/.config/omarchy/ciscovpn` are created `0700`. `install.sh` scrubs any old
  log that contained token material from earlier builds.

- **Safe teardown.** `disconnect` only kills a numeric PID that is actually an
  `openconnect` process (verified via `/proc/<pid>/comm` and `exe`), or — if the
  pid file was lost — an `openconnect` whose argv contains exactly this gateway.
  No broad `pkill -f` on user-influenced patterns.

### Security review checklist

- [x] No passwordless sudoers rule; every privileged action is an interactive `sudo`.
- [x] All caller inputs to the root helper are validated; injection attempts rejected (tested).
- [x] No caller-supplied free-form args in the privileged command line.
- [x] Server certificate pin mandatory; connect refused without it.
- [x] Session cookie only on stdin; never logged or in argv.
- [x] State/config dirs are `0700`; stale token-bearing logs scrubbed on install.
- [x] Teardown verifies process identity before killing.
- No secrets are stored at rest; authentication is entirely IdP-side (CyberArk).

---

## 6. Installation internals

`link.sh` (repo) → links/copies `plugin/` to
`~/.config/omarchy/plugins/custom.ciscovpn`, then runs `plugin/install.sh`, which:

1. installs `openconnect` via `pacman` if absent;
2. installs the `sudoers.d` rule (visudo-checked);
3. symlinks the CLI to `~/.local/bin/ciscovpn`;
4. registers the widget on the bar (`omarchy-bar put custom.ciscovpn
   --before omarchy.network`), or — if the running shell's IPC isn't reachable —
   you add it to `shell.json` manually (see §7).

The widget is considered **enabled** when its id appears anywhere in
`~/.config/omarchy/shell.json`. The running shell watches both `shell.json` and
the plugins directory and hot-reloads on change.

---

## 7. Troubleshooting

### `sudo: a password is required` → `openconnect exited with code 1` (browser never opened)

**Cause:** the passwordless `sudoers` rule isn't installed, and an older build
used `sudo -n` (non-interactive), which fails instantly — so openconnect never
starts and the browser never opens.

**Fix (either one):**

- Run the installer once to add the rule (then connect is prompt-free):
  ```bash
  bash ~/.config/omarchy/plugins/custom.ciscovpn/install.sh
  ```
- Or just **connect again**: the current build falls back to an interactive
  `sudo` prompt in the terminal — type your password and the SSO browser opens.

Verify the rule:
```bash
ciscovpn doctor        # look for: sudo rule : OK
sudo -n ~/.config/omarchy/plugins/custom.ciscovpn/bin/ciscovpn-root check && echo OK
```

### The widget isn't on the bar

The running shell's IPC may not be reachable (e.g. a non-standard shell config).
Add it to `shell.json` directly and the shell hot-reloads:

```bash
python3 - <<'PY'
import json
p=f"{__import__('os').path.expanduser('~')}/.config/omarchy/shell.json"
d=json.load(open(p)); right=d["bar"]["layout"]["right"]
ids=[w.get("id") for w in right]
if "custom.ciscovpn" not in ids:
    i = ids.index("omarchy.network") if "omarchy.network" in ids else len(right)
    right.insert(i, {"id":"custom.ciscovpn"}); json.dump(d,open(p,"w"),indent=2)
    print("added")
PY
```

Confirm the shell loaded it (lists `target custom.ciscovpn`):
```bash
quickshell -p /usr/share/omarchy/shell ipc show | grep custom.ciscovpn
# (use the --path your running shell was started with if different)
```

### The browser doesn't open

- Ensure a default browser is set: `xdg-settings get default-web-browser`.
- `ciscovpn doctor` should show `browser : /usr/bin/xdg-open`.
- The gateway must support **external-browser** SAML (Cisco ASA/FTD 9.17+). Older
  gateways use an embedded webview the native flow can't drive.

### `openconnect` exits right after the browser login

- Wrong gateway host, or a required tunnel/auth group. Try `host/group`.
- Check the tail of the log: `ciscovpn doctor` (prints the last connect log), or
  the terminal window output.

### Connection drops / no traffic

- Confirm the tunnel interface and IP: `ciscovpn status` (shows `interface`/`ip`),
  or `ip addr show`.
- Some gateways need a specific protocol; set `"protocol"` in
  `~/.config/omarchy/ciscovpn/config.json`.

---

## 8. Config file reference

`~/.config/omarchy/ciscovpn/config.json`:

```json
{
  "server": "vpn-ssl.telecom.com.ar",
  "protocol": "anyconnect",
  "browser": "",
  "extraArgs": ""
}
```

- `server` — gateway host (set via the panel or `ciscovpn set-server`).
- `protocol` — openconnect `--protocol` (default `anyconnect`).
- `browser` — reserved; empty uses the built-in `_browser` handler.
- `extraArgs` — extra flags appended to the openconnect command line.
