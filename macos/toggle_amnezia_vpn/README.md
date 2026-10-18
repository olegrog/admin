# Caps Lock → Toggle AmneziaVPN for macOS

[Karabiner-Elements](https://karabiner-elements.pqrs.org/) remaps keyboard keys
on macOS. This rule makes Caps Lock toggle
[AmneziaVPN](https://amnezia.org/):

`Caps Lock → Karabiner → osascript → AmneziaVPN tray menu`

Keep AmneziaVPN and Karabiner's background services running. AmneziaVPN's
main window and Karabiner's settings window can stay closed.

## Install

With [Homebrew](https://brew.sh/):

```sh
brew install --cask karabiner-elements amneziavpn
```

The [AmneziaVPN cask](https://formulae.brew.sh/cask/amneziavpn) requires Rosetta 2
on Apple Silicon. Open both apps, complete Karabiner's setup prompts, configure
a connection in AmneziaVPN, and set its language to English.

From this directory:

```sh
mkdir -p ~/.config/karabiner/assets/complex_modifications
cp toggle_amnezia.applescript ~/.config/karabiner/
cp capslock_amnezia.json ~/.config/karabiner/assets/complex_modifications/
```

In **Karabiner-Elements → Complex Modifications → Add predefined rule**, enable
**Caps Lock: toggle AmneziaVPN**. Disable other Caps Lock mappings, including
those in **Simple Modifications**. Holding Caps Lock does not repeat the toggle.

## Permissions

The script uses macOS UI automation. On the first Caps Lock press, allow
**Karabiner-Console-User-Server** to control **System Events** if prompted.
This is Karabiner's background process that runs the script.

If macOS reports that assistive access is denied, enable the app named in the
error under **System Settings → Privacy & Security → Accessibility**.
Permissions apply to the background process regardless of which app is in the
foreground.

## Check

This checks menu access without changing the VPN connection:

```sh
osascript ~/.config/karabiner/toggle_amnezia.applescript --check
```

It prints `Available action: Disconnect` when connected,
`Available action: Connect` when disconnected, or `No action available` when
neither menu item is enabled. Running this from Terminal may request
Terminal's own permissions; it does not verify Karabiner's permissions.

Press Caps Lock to toggle. Check the result in AmneziaVPN's tray menu.

## Limits

The script uses the English **Connect** and **Disconnect** menu items. Changes
to AmneziaVPN's menu labels or accessibility layout can break it. A key press
requests a state change; it does not wait for the VPN to connect.
Caps Lock's green LED does not indicate VPN status.

## Update or remove

After editing the script in this repository, repeat its `cp` command to install
the changes. To restore normal Caps Lock behavior, remove the rule from
Karabiner.
