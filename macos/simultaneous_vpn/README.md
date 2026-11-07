# Simultaneous VPNs on macOS

Use an internet VPN, Skoltech VPN, FRCCSC VPN and the current LAN together.
LAN names use DHCP DNS; institutional names use their LAN or VPN DNS.
Public names use configured DNS routed through the internet VPN, falling back
to LAN DNS when no eligible tunnel route exists and no full tunnel is active.
Routes and DNS refresh every five seconds. IPv4 only; Bonjour `.local` stays
with macOS.

## Installation

Requires macOS 14+, Homebrew, Python 3 and Xcode Command Line Tools.
Run commands from this directory as your normal user, using sudo where shown.
Remove an older installation with its original installer first.

```sh
xcode-select -p                 # if missing: xcode-select --install
brew install dnsmasq openconnect
./setup.sh build                # compiles and runs offline tests
sudo ./setup.sh install
```

The installer starts its own dnsmasq on `127.0.0.1:53`; do not run another there.
Keep normal DNS server addresses in your VPN client. The helper publishes
localhost DNS itself after checking that dnsmasq responds.

For `sk`, first of all, set your login and the certificate pin confirmed by IT:

```sh
cp sk/openconnect.conf.example sk/openconnect.conf
vim sk/openconnect.conf
```

Then build and install the openconnect wrapper:

```sh
./setup.sh build sk
sudo ./setup.sh install sk
mkdir -p ~/.local/bin
install -m 700 sk/sk ~/.local/bin/sk
export PATH="$HOME/.local/bin:$PATH"
```

Add the last line to your shell startup file if needed.
Store the password in the login Keychain as your normal user, or retain the
existing matching item. Confirm that the default Keychain is `login.keychain-db`:

```sh
security default-keychain -d user
account=$(sed -n 's/^user=//p' sk/openconnect.conf)
security add-generic-password -U -a "$account" \
  -s local.sk-vpn.vpn.skoltech.ru -w
unset account
```

Enter the password at the hidden prompt.

Run `sk` off campus; stop with Ctrl-C. It stops automatically on campus.
Only one instance, including `sk --check`, can run at a time.
Connect FRCCSC in OpenVPN Connect when outside its LAN. Leave the internet VPN
connected. The fixed sudo rule permits only the protected OpenConnect wrapper,
without arguments, so `sk` needs no administrator prompt.

For access to FRCCSC LAN, first install OpenVPN Connect:

```sh
brew install openvpn-connect
```

Add these lines to your issued FRCCSC profile and import it into OpenVPN
Connect:

```text
pull-filter ignore "block-outside-dns"
dhcp-option DOMAIN frccsc.ru
```

## Testing

```sh
base=/Library/PrivilegedHelperTools/local.vpn-coexist
"$base/vpn-coexist" --check-config "$base/config.json"
"$base/vpn-coexist" --status
"$base/vpn-coexist" --inspect
dig +time=2 +tries=1 @127.0.0.1 example.com
host example.com
curl -4 -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  --connect-timeout 5 --max-time 10 https://chatgpt.com
sk --check
```

Expect valid configuration, recent status with no errors, a DNS answer and an
HTTP response. `--inspect` lists detected institutional LANs; `[]` is normal
elsewhere. `sk --check` authenticates without changing routes or printing cookies.
With both institutional VPNs connected off site, check:

```sh
host hilbert.skoltech.ru
host login.hpc.frccsc.ru
for target in hilbert login.hpc.frccsc.ru chatgpt.com google.com; do
  route -n get "$target" | grep interface
done
```

Compare the `interface` fields with your VPN clients and their routes:

| Destination | Expected connection off site |
| --- | --- |
| `hilbert` | Skoltech tunnel |
| `login.hpc.frccsc.ru` | FRCCSC tunnel |
| `chatgpt.com` | Internet VPN tunnel |
| `google.com` | Physical LAN if excluded from the internet VPN |

Tunnel numbers (`utunN`) can change. On an institutional LAN, its hosts should
use the physical interface instead. Hostnames can have several IP addresses;
`route get` checks the address shown in its output.
While `sk` is connected, a second `sk` must exit without starting another tunnel.
SSH examples require your own aliases. Test a known LAN name too. Repeat after
stopping `sk`, changing networks and sleep/wake. On each institutional LAN,
status should report `lan` without that institution's VPN running.

## Troubleshooting

- Inspect `--status`, `scutil --dns`, `route -n get ADDRESS` and
  `tail -n 30 /var/log/vpn-coexist*.log`.
- If an IP works but its name fails, compare `dig @127.0.0.1 NAME` with
  `dig @LAN_DNS NAME`. For short names, check LAN DNS and `scutil --dns`
  search domains. Reverse lookup requires a PTR record on the LAN DNS server.
- Check that `vpn_dns` uses a tunnel and DNS/firewall exceptions permit access.
  This helper manages routes and DNS; VPN clients establish the connections.
- For `sk`, check the login, Keychain item and certificate pin. To edit them:
  `sudo vim /Library/PrivilegedHelperTools/local.sk-vpn/openconnect.conf`.
- To change main settings, edit `config.json`, validate with
  `"$base/vpn-coexist" --check-config config.json`, then run
  `sudo install -o root -g wheel -m 644 config.json "$base/config.json"`.
- If selected internet sites fail after wake and reconnecting fixes them,
  update the internet VPN client. Test full-tunnel mode to isolate its
  split-tunneling recovery; this helper does not reconnect VPN clients.

To update binaries, remove, rebuild and reinstall. Rebuild `sk` to update its
bundled OpenConnect runtime.

## Uninstall

Stop `sk` with Ctrl-C. If a VPN or Wi-Fi DNS server was manually set to
`127.0.0.1`, restore normal DNS and reconnect that client first.

```sh
sudo ./setup.sh remove sk       # if the optional helper is installed
sudo ./setup.sh remove
rm -f ~/.local/bin/sk ~/Library/Caches/local.sk-vpn.lock
```

Remove any `sk` alias pointing to this launcher. To also delete the saved
password, local build/configuration and logs:

```sh
account=$(sed -n 's/^user=//p' sk/openconnect.conf)
security delete-generic-password -a "$account" \
  -s local.sk-vpn.vpn.skoltech.ru "$HOME/Library/Keychains/login.keychain-db"
unset account
rm -rf build
rm -f sk/openconnect.conf
sudo rm -f /var/log/vpn-coexist.log /var/log/vpn-coexist-dns.log
```

Removal deletes owned routes, DNS resolver, firewall additions, services and
installed files. VPN apps and issued profiles remain separate. Share sources
only; private configuration and build output are ignored.
