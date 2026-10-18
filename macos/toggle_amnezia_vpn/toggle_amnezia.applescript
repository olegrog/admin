on run args
    if args is not {} and args is not {"--check"} then error "Usage: osascript toggle_amnezia.applescript [--check]"
    if application "AmneziaVPN" is not running then tell application "AmneziaVPN" to launch

    tell application "System Events"
        tell process "AmneziaVPN"
            repeat 50 times
                if exists menu bar item 1 of menu bar 2 then exit repeat
                delay 0.1
            end repeat
            if not (exists menu bar item 1 of menu bar 2) then error "AmneziaVPN menu bar icon is unavailable."

            click menu bar item 1 of menu bar 2
            set actionName to ""
            tell menu 1 of menu bar item 1 of menu bar 2
                if enabled of menu item "Connect" then
                    set actionName to "Connect"
                else if enabled of menu item "Disconnect" then
                    set actionName to "Disconnect"
                end if
            end tell

            if args is {"--check"} or actionName is "" then
                key code 53
            else
                click menu item actionName of menu 1 of menu bar item 1 of menu bar 2
            end if
        end tell
    end tell
    if actionName is "" then return "No action available"
    return "Available action: " & actionName
end run
