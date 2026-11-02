#!/bin/sh
set -eu
cd "$(dirname "$0")"
base=/Library/PrivilegedHelperTools
target=$base/local.vpn-coexist
state=/var/db/local.vpn-coexist
jobs=/Library/LaunchDaemons
sk=$base/local.sk-vpn
rule=/private/etc/sudoers.d/sk-vpn

usage() { echo 'Usage: ./setup.sh build|install|remove [sk]' >&2; exit 64; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
case ${2:-} in ''|sk) ;; *) usage ;; esac
case $1 in build|install|remove) ;; *) usage ;; esac

if [ "$1" = build ]; then
    [ "$(id -u)" != 0 ] || { echo 'Build as your normal user.' >&2; exit 77; }
    if [ "${2:-}" = sk ]; then exec python3 sk/build.py; fi
    brew=$(command -v brew || true)
    [ -n "$brew" ] || brew=/opt/homebrew/bin/brew
    [ -x "$brew" ] || brew=/usr/local/bin/brew
    [ -x "$brew" ] || { echo 'Install Homebrew and run brew install dnsmasq first.' >&2; exit 69; }
    mkdir -p build
    xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
        -framework SystemConfiguration vpn-coexist.swift -o build/vpn-coexist
    install -m 755 "$("$brew" --prefix dnsmasq)/sbin/dnsmasq" build/dnsmasq
    for binary in build/vpn-coexist build/dnsmasq; do
        otool -L "$binary" | awk 'NR > 1 {print $1}' | while read -r library; do
            case "$library" in
                /usr/lib/*|/System/Library/*) ;;
                *) echo "Non-system dependency: $library" >&2; exit 1 ;;
            esac
        done
        codesign --force --sign - "$binary"
        codesign --verify --strict "$binary"
    done
    build/vpn-coexist --check-config config.json
    sed '/^\/\/ Command line$/,$d' vpn-coexist.swift > build/tests.swift
    cat tests.swift >> build/tests.swift
    xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
        -framework SystemConfiguration build/tests.swift -o build/tests
    exec build/tests
fi

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
[ "$(id -u)" = 0 ] || { echo 'Run install/remove with sudo.' >&2; exit 77; }
trusted() {
    [ ! -L "$1" ] && [ "$(stat -f %u "$1")" = 0 ] || exit 77
    mode=$(stat -f %Lp "$1")
    [ $((0$mode & 0022)) = 0 ] || exit 77
}
absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || { echo "Already exists: $1" >&2; exit 73; }
}
for parent in /Library "$base" "$jobs" /private/var/db /private/etc/sudoers.d; do
    [ ! -e "$parent" ] || trusted "$parent"
done

if [ "${2:-}" = sk ]; then
    if [ "$1" = install ]; then
        owner=${SUDO_USER:?Run sudo from your normal macOS account.}
        case "$owner" in root|*[!A-Za-z0-9_.-]*) exit 64 ;; esac
        id "$owner" >/dev/null
        absent "$sk"
        absent "$rule"
        [ -x build/sk/connect ] && [ -x build/sk/runtime/openconnect ] && [ -r build/sk/openconnect.conf ] || {
            echo 'Run ./setup.sh build sk as your normal user first.' >&2; exit 69;
        }
        for binary in build/sk/connect build/sk/runtime/openconnect build/sk/runtime/*.dylib; do
            codesign --verify --strict "$binary"
        done
        stage=$(mktemp -d /private/etc/sudoers.d/.sk-vpn.XXXXXX)
        trap 'rm -rf "$stage"' EXIT HUP INT TERM
        printf '%s ALL=(root) NOPASSWD: %s/connect ""\n' "$owner" "$sk" > "$stage/rule"
        visudo -cf "$stage/rule"
        install -d -o root -g wheel -m 755 "$base" "$sk" "$sk/runtime"
        install -o root -g wheel -m 755 build/sk/connect "$sk/connect"
        install -o root -g wheel -m 644 build/sk/openconnect.conf "$sk/"
        install -o root -g wheel -m 755 build/sk/runtime/openconnect build/sk/runtime/vpnc-script "$sk/runtime/"
        install -o root -g wheel -m 644 build/sk/runtime/*.dylib build/sk/runtime/gnutls.conf "$sk/runtime/"
        install -o root -g wheel -m 440 "$stage/rule" "$rule"
        visudo -cf /private/etc/sudoers
        echo 'Installed sk helper. Install sk/sk in your user PATH; see README.md.'
    else
        trusted "$sk"
        trusted "$rule"
        grep -Fq "NOPASSWD: $sk/connect \"\"" "$rule" || exit 77
        if pgrep -f "$sk/runtime/openconnect" >/dev/null; then
            echo 'Stop sk with Ctrl-C first.' >&2; exit 75
        fi
        rm -f "$rule"
        rm -rf "$sk"
        echo 'Removed sk helper. User launcher and Keychain item retained.'
    fi
    exit 0
fi

write_job() {
    name=$1
    log=$2
    {
        cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$name</string>
<key>ProgramArguments</key><array>
EOF
        cat
        cat <<EOF
</array>
<key>RunAtLoad</key><true/>
EOF
        if [ "$name" = local.vpn-coexist ]; then
            echo '<key>StartInterval</key><integer>5</integer>'
        else
            echo '<key>KeepAlive</key><true/>'
        fi
        cat <<EOF
<key>ExitTimeOut</key><integer>30</integer>
<key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>$log</string>
<key>StandardErrorPath</key><string>$log</string>
</dict></plist>
EOF
    } > "$jobs/$name.plist"
    chmod 644 "$jobs/$name.plist"
    plutil -lint "$jobs/$name.plist"
}

if [ "$1" = install ]; then
    for path in "$target" "$state" "$jobs/local.vpn-coexist.plist" "$jobs/local.vpn-coexist.dns.plist"; do
        absent "$path"
    done
    for name in local.vpn-coexist local.vpn-coexist.dns; do
        if launchctl print "system/$name" >/dev/null 2>&1; then
            echo "Service already loaded: $name" >&2; exit 73
        fi
    done
    [ -x build/vpn-coexist ] && [ -x build/dnsmasq ] || {
        echo 'Run ./setup.sh build as your normal user first.' >&2; exit 69;
    }
    for binary in build/vpn-coexist build/dnsmasq; do codesign --verify --strict "$binary"; done
    build/vpn-coexist --check-config config.json
    install -d -o root -g wheel -m 755 "$base" "$target" "$state"
    install -o root -g wheel -m 755 build/vpn-coexist build/dnsmasq "$target/"
    install -o root -g wheel -m 644 config.json "$target/"
    cat > "$target/dnsmasq.conf" <<EOF
port=53
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-hosts
cache-size=0
user=nobody
group=nobody
pid-file=
log-facility=-
servers-file=$state/dns-servers.conf
EOF
    chmod 644 "$target/dnsmasq.conf"
    printf 'server=//\n' > "$state/dns-servers.conf"
    chmod 644 "$state/dns-servers.conf"
    "$target/dnsmasq" --test --conf-file="$target/dnsmasq.conf"
    write_job local.vpn-coexist /var/log/vpn-coexist.log <<EOF
<string>$target/vpn-coexist</string><string>--once</string>
EOF
    write_job local.vpn-coexist.dns /var/log/vpn-coexist-dns.log <<EOF
<string>$target/dnsmasq</string><string>--keep-in-foreground</string>
<string>--conf-file=$target/dnsmasq.conf</string>
EOF
    if ! launchctl bootstrap system "$jobs/local.vpn-coexist.dns.plist" ||
       ! launchctl bootstrap system "$jobs/local.vpn-coexist.plist"; then
        echo 'Startup failed; run sudo ./setup.sh remove to remove the partial installation.' >&2
        exit 70
    fi
    echo 'Installed. Check: /Library/PrivilegedHelperTools/local.vpn-coexist/vpn-coexist --status'
else
    for path in "$target" "$target/vpn-coexist" "$state"; do trusted "$path"; done
    if launchctl print system/local.vpn-coexist >/dev/null 2>&1; then
        launchctl bootout system/local.vpn-coexist
    fi
    # bootout can return before the old process releases its lock.
    cleaned=no
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if "$target/vpn-coexist" --cleanup; then cleaned=yes; break; fi
        sleep 1
    done
    [ "$cleaned" = yes ] || exit 75
    sleep 1
    if printf 'show State:/Network/Global/DNS\nquit\n' | scutil | grep -q 127.0.0.1; then
        echo 'Restore normal DNS in your VPN client/system settings, reconnect, then retry removal.' >&2; exit 75
    fi
    if launchctl print system/local.vpn-coexist.dns >/dev/null 2>&1; then
        launchctl bootout system/local.vpn-coexist.dns
    fi
    rm -f "$jobs/local.vpn-coexist.plist" "$jobs/local.vpn-coexist.dns.plist"
    rm -f "$target/vpn-coexist" "$target/dnsmasq" "$target/dnsmasq.conf" "$target/config.json" "$target/vpnc-script"
    rm -f "$state/state.json" "$state/status.json" "$state/lock" "$state/dns-servers.conf"
    rmdir "$target" "$state"
    echo 'Removed. Logs retained in /var/log/vpn-coexist*.log.'
fi
