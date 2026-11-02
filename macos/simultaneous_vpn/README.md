# Simultaneous VPNs on macOS

Use an internet VPN, institutional VPNs and the current LAN together.
VPN clients establish tunnels and supply their routes and DNS. An updater
keeps local routes and DNS consistent as you change networks.

| Current LAN | Skoltech | FRCCSC |
| --- | --- | --- |
| Home/other | `sk` | OpenVPN Connect |
| Skoltech | Direct | OpenVPN Connect |
| FRCCSC | `sk` | Direct |

Run institutional VPNs when off site. Leave the internet VPN connected.

## Install

Requires macOS 14+, Homebrew and Xcode Command Line Tools
(`xcode-select --install` if missing). From this directory:

```sh
brew install dnsmasq
./setup.sh build
sudo ./setup.sh install
```

Build on each recipient's Mac as your normal user. Installation registers
dnsmasq and an updater that launchd runs every five seconds.
Do not start another dnsmasq service.
The installer refuses an existing installation; remove it with its original
installer before replacing it. VPN apps, profiles and credentials are separate.

## Configure

Edit `config.json` before installation:

- `vpn_dns`: public/provider DNS addresses routed through the internet VPN.
- `networks`: each institution's domain, VPN server `endpoints`, and private
  `routes` to use directly when inside its LAN.
- `lan`: identify that LAN by `dhcp_server` or a DNS `probe` under its domain.
  Omit this field for a VPN-only network.

DHCP matching also checks the domain and address range. A probe must return a
private IPv4 address from LAN DNS. Current/home LANs are discovered automatically.
After a probe times out, its last successful match is retained for up to one minute.
Local names and reverse queries use LAN DNS; institutional names use their
published VPN DNS or detected LAN DNS. Public names use configured DNS whose
routes lead through a tunnel. Without such a route and without a full tunnel,
public names use LAN DNS. A full tunnel with no eligible DNS produces an error.

In your internet VPN, allow LAN access and DNS to localhost, LAN and institutional
servers. Exclude the institutional VPN **server endpoints**; route `vpn_dns`
through the internet VPN. Permanent institutional subnet exclusions are
unnecessary: the updater adds direct routes only on the corresponding LAN.
Client kill switches must permit these exceptions.

For AmneziaVPN, add `"firewall": "amnezia"` at the top level to maintain narrow
exceptions in its existing firewall tables. This never loads or flushes rules.
Other clients use their own LAN/DNS exceptions; omit `firewall` for them.

For FRCCSC, import your issued profile into OpenVPN Connect with:

```text
pull-filter ignore "block-outside-dns"
dhcp-option DOMAIN frccsc.ru
```

## Optional passwordless `sk`

Requires Python 3 for the build. Install the main helper first, then:

```sh
brew install openconnect
cp sk/openconnect.conf.example sk/openconnect.conf
${EDITOR:-vi} sk/openconnect.conf
./setup.sh build sk
sudo ./setup.sh install sk
mkdir -p ~/.local/bin
install -m 700 sk/sk ~/.local/bin/sk
```

Set your `user=` and verify `servercert=pin-sha256:...` with IT. Keep the password
in the login Keychain. In Keychain Access, add a password item with:

- Name: `local.sk-vpn.vpn.skoltech.ru`
- Account: the same login as `user=`
- Password: your VPN password

Put `~/.local/bin` in PATH and remove any older `sk` alias. Run `sk`; stop with
Ctrl-C. On the Skoltech LAN it reports that VPN is unnecessary. `sk --check`
tests authentication without a tunnel; Keychain may ask for access on first use.

Both Homebrew locations are supported. To select a client explicitly, run
`python3 sk/build.py --openconnect PATH`. The build copies OpenConnect and its
libraries into a protected runtime. A restricted sudo rule permits only the
fixed `connect` wrapper without arguments. Rebuild to update that runtime.
The DNS hook preserves the upstream vpnc-script and scopes Skoltech DNS.

To change the installed login or certificate pin, use:

```sh
sudo -e /Library/PrivilegedHelperTools/local.sk-vpn/openconnect.conf
```

## Check and remove

```sh
base=/Library/PrivilegedHelperTools/local.vpn-coexist
"$base/vpn-coexist" --status
"$base/vpn-coexist" --inspect skoltech.ru
scutil --dns
host NAME
route -n get ADDRESS
```

`--inspect` without a domain lists detected institutional LANs. Inspection is
read-only. Status reports each institution as `lan`, `vpn` or `disconnected`;
VPN status is inferred from published DNS. Errors also go to
`/var/log/vpn-coexist.log`. dnsmasq logs use `/var/log/vpn-coexist-dns.log`.

To edit installed settings, use `sudo -e "$base/config.json"`. Validate with
`"$base/vpn-coexist" --check-config "$base/config.json"`; changes are picked up
on the next update.

The updater changes only its owned routes and stale configured endpoint routes.
It repairs routes after DHCP address changes and preserves unrelated routes.
dnsmasq listens on `127.0.0.1:53`; native DNS is retained if it is unavailable.
IPv4 is supported; Bonjour `.local` stays with macOS. PTR records must exist
on the LAN DNS server. Builds run offline regression tests from `tests.swift`.
Check network changes on each recipient's Mac before relying on the setup.

Stop `sk` before removal:

```sh
sudo ./setup.sh remove sk  # if installed
sudo ./setup.sh remove
```

Remove the user launcher and Keychain item separately. Logs are retained.
To update binaries, remove, rebuild as your normal user, and install again.
Share sources only: private configuration, profiles and build output are ignored.
