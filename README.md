# FocusDim

A tiny, free macOS menu bar app that dims every window except the one you are working in. It works across all your screens, so with a MacBook and two external monitors only the focused window stays bright.

Inspired by [HazeOver](https://hazeover.com/).

## Features

- Dims all other windows on every connected display
- Full-screen windows are never dimmed
- Toggle with **⌘⇧D** (Command + Shift + D) from any app
- Menu bar icon: half-filled circle = on, empty circle = off
- Adjustable dim level (slider in the menu)
- Starts automatically at login (can be turned off in the menu)
- No permissions needed (no Accessibility or Screen Recording access)
- Single Swift file, no dependencies

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (for `swiftc`): `xcode-select --install`

## Install

```sh
git clone https://github.com/NikRpk/FocusDim.git
cd FocusDim
./build.sh
open ~/Applications/FocusDim.app
```

`build.sh` compiles the app, signs it locally, and installs it to `~/Applications/FocusDim.app`. Keep it there: the login item points to that location.

On first launch FocusDim adds itself as a login item. macOS may show a one-time "Login item added" notice.

## Use

| Action | How |
|---|---|
| Turn dimming on/off | Press **⌘⇧D**, or click the menu bar icon → **Dim other windows** |
| Change how dark | Menu bar icon → **Dim level** slider |
| Start at login on/off | Menu bar icon → **Start at login** |
| Quit | Menu bar icon → **Quit FocusDim** |

Settings are remembered between restarts.

## Update

```sh
cd FocusDim
git pull
./build.sh
open ~/Applications/FocusDim.app
```

## Uninstall

1. Menu bar icon → untick **Start at login**, then **Quit FocusDim**
2. Delete `~/Applications/FocusDim.app`

## How it works

FocusDim places one transparent black, click-through window on each screen. Every 0.15 seconds (and whenever you switch apps) it finds the top window of the frontmost app and moves the dim layers directly behind it. Everything else sits behind the dim layer. If the focused window fills its whole screen (full screen), that screen is not dimmed.

## Known limits

- **⌘⇧D** is taken over globally while FocusDim runs, so apps that use the same shortcut won't receive it. Change it in `registerHotKey()` in `main.swift`.
- Clicking the desktop (no window focused) removes the dimming until you focus a window again.

## License

MIT
