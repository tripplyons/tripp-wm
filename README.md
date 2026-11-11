# tripp-wm

tripp-wm is a scrolling window manager in the style of Niri, with Hyprland's
Alt+HJKL key layout. Each monitor shows one of nine workspaces. A workspace is
a horizontal strip of columns, and each column holds one or more stacked
windows. Opening a window adds a column to the right of the focused one, and
the strip scrolls to keep the focused column on screen. Workspaces are virtual:
all of them live on the current macOS Space, and tripp-wm hides a workspace by
moving its windows to a screen corner, as AeroSpace does. It needs no SIP
changes and ignores full-screen windows.

The Swift package is in `~/.local/libexec/tripp-wm`, and the config is
`~/.config/tripp-wm/config.toml`. tripp-wm reloads the config when it changes,
and keeps the last good config if the new one has an error. The menu bar item
shows occupied workspaces, with the focused one in brackets. Its menu shows
config errors and taken keys. Choose "Disable tripp-wm" in that menu to release
its shortcuts, stop tiling and pointer actions, hide the border, and bring hidden
workspace windows back on screen. Choose "Enable tripp-wm" to resume managing
windows. It starts enabled after a restart. Logs go to
`~/Library/Logs/tripp-wm.log`.

Use the menu's "Screen warmth" slider to reduce blue and green output across
all connected displays, including other apps and full-screen windows. The slider
runs from Off to 100% warmth; it is a manual strength, not a color-temperature
measurement. It starts Off on first launch, remembers changes in the app's
UserDefaults (not `config.toml`), and reapplies after wake or display changes.
Warmth stays active when tiling is disabled and needs no extra permissions.
Move the slider to Off or quit tripp-wm normally to restore the display color
curves captured before warming. A forced kill cannot run that cleanup.

Turn off Night Shift, True Tone, and other display-color tools to avoid competing
adjustments. Support depends on the display and macOS; some HDR or virtual
displays may reject gamma-table changes or accept them without a visible effect.
Reported failures appear below the slider, with details in its tooltip and the
log. Other displays continue to update. If you change a color profile while
warmth is active, turn warmth Off before changing the profile, then enable it
again so tripp-wm captures the new curves. This feature does not use an overlay,
a schedule, or private Night Shift APIs.

Focus scrolling and window moves animate for 180 ms with ease-out cubic easing.
Updates follow the display's refresh rate, including high-refresh-rate displays.
Pure moves write only the position, not the size. Animation frames use cached
geometry, with real-window reads when interrupted and when the animation finishes.
Each app writes animation frames on its own worker queue. Slow apps skip obsolete
pending frames instead of blocking the display loop or replaying a backlog.
Workers reuse the starting geometry read during layout so the first animation
frame does not wait for a second Accessibility read.
Layout changes drain in-flight writes before reading real geometry. The border
checks frontmost-app state and changes its window ordering outside display ticks.
Repeated focus notifications for the selected window preserve the running scroll.
New window transitions start their timer after layout and focus setup so slow
Accessibility calls do not consume the animation duration. Resizes suppress the
app's native resize animation once per transition, not on every frame, and restore
its Accessibility mode on completion or cancellation. This avoids repeated
Accessibility-mode changes in Chrome during animated resizes.
Focus changes immediately. The border glides to the newly focused window,
including changes in size, using `[animations.focus]`. Rapid focus changes retarget
from the border's current position. The border follows moves of the same focused
window without adding lag. Repeated commands retarget from the current window
position. Offscreen windows enter from their strip position at the screen edge;
departing windows park only after
the transition finishes. These are real-window animations, with no screen capture
permission required. macOS can constrain offscreen positions. Workspace switches stay
instant. Configure `[animations.focus]` for focus scrolling and centering, and
`[animations.move]` for moving, consuming or expelling, and resizing columns.
Each accepts `duration` in milliseconds (0 disables animation) and `easing`:
`linear`, `ease-out-cubic`, or `ease-in-out-cubic`. Settings reload without a restart.

Default keys:

| Key | Action |
| --- | --- |
| Alt+H/L | Focus the column to the left or right |
| Alt+J/K | Focus the window below or above in the column |
| Alt+Shift+H/L | Move the column left or right |
| Alt+Shift+J/K | Move the window down or up in the column |
| Alt+[ / Alt+] | Move the window into the neighboring column, or out of its column |
| Alt+R | Cycle the column width: 1/3, 1/2, 2/3, full |
| Alt+F | Toggle a full-width column |
| Alt+C | Center the focused column |
| Alt+Shift+F | Toggle floating |
| Alt+Space | Open or close the pointer grid |
| Alt+T | Open a new Ghostty window |
| Alt+1-9 | Show a workspace |
| Alt+Shift+1-9 | Move the window to a workspace |
| Alt+Tab | Show the previous workspace |
| Alt+F17 | Show workspace 1, or 2 when 1 is focused |
| Alt+N / Alt+P | Show the next or previous workspace |
| Alt+Shift+R | Reload the config |

Alt+Space covers the monitor under the pointer with a grid targeting 24x24
logical-point cells (48x48 physical pixels on a 2x Retina display). Rows and
columns adapt to the monitor size. Each cell has a three-letter label in row
order: `aaa`, `aab`, and so on. Type a label to click the cell's center;
nonmatching labels dim as you type. Hold Shift on the third letter to
right-click, or Command to middle-click. Backspace removes the last typed
letter, and Escape or Alt+Space closes the grid. While
the grid is open, tripp-wm takes every key, so nothing reaches the app below.
The `[grid]` section of the config sets its colors. It replaced Neru.

Tap right Option on its own to enter the action mode. In it, every key runs
the binding it would run with Option held: H focuses left, Shift+H moves left,
N shows the next workspace. Keys without a binding do nothing, and no key
reaches the app. Right Option, Escape, or I leave the mode, and so do bindings
that hand the keyboard elsewhere (`grid` and `exec`). The focus border turns
gray while the mode is on; `mode-color` in `[border]` sets that color. Right
Option held together with another key still types as Option.

Resizing a tiled window with the mouse sets its column width. Windows that
cannot be resized, and apps matched by a `[[rules]]` entry with `float = true`,
float above the strip. A rule with `workspace = "N"` sends an app's new windows
to that workspace.

`tripp-wmctl` sends the same commands over a socket, for example
`tripp-wmctl workspace 3`, `tripp-wmctl focus left`, or `tripp-wmctl grid`.
`tripp-wmctl query state` prints the workspaces, columns, and window titles as
JSON.

A binding such as `"alt-t" = "exec open -na Ghostty.app"` runs a shell command with
`/bin/sh`, with `/opt/homebrew/bin` and `/usr/local/bin` added to `PATH`. The
program runs in its own session, so it keeps running when tripp-wm restarts.

### Install

tripp-wm needs Swift from Xcode Command Line Tools. Builds always use ad hoc
signing, without a trusted certificate or keychain identity. Changed binaries
can require manual reapproval of Accessibility and Input Monitoring permissions.
Identical rebuilds and relaunches do not necessarily require approval. This is
separate from Gatekeeper's "Open Anyway" check.

If you previously ran `tripp-wm-create-signing-cert`, use Keychain Access to
remove the "tripp-wm local signing" certificate and its associated private key
from the login keychain. The build no longer uses them, but removing the helper
does not remove existing keychain items. The installed app keeps its old
signature until it is rebuilt.

This repository owns the source and configuration, independently of dotfiles.
To install manually on macOS (these commands replace an existing installation):

```sh
mkdir -p "$HOME/.local/libexec/tripp-wm" "$HOME/.local/bin" "$HOME/.config/tripp-wm" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp Package.swift Package.resolved Info.plist "$HOME/.local/libexec/tripp-wm/"
cp -R Sources Tests "$HOME/.local/libexec/tripp-wm/"
cp bin/tripp-wm "$HOME/.local/bin/tripp-wm"
chmod +x "$HOME/.local/bin/tripp-wm"
ln -sf tripp-wm "$HOME/.local/bin/tripp-wmctl"
# Keep an existing personal config. Copy the default only on a new install.
test -e "$HOME/.config/tripp-wm/config.toml" || cp config/config.toml "$HOME/.config/tripp-wm/config.toml"
python3 - <<'PY'
from pathlib import Path
from xml.sax.saxutils import escape
home = Path.home()
template = Path("launchd/dev.tripp.tripp-wm.plist.in").read_text()
(home / "Library/LaunchAgents/dev.tripp.tripp-wm.plist").write_text(
    template.replace("@HOME@", escape(str(home)))
)
PY
"$HOME/.local/bin/tripp-wm" --build
# Only when you intend to restart the installed window manager:
launchctl bootout "gui/$(id -u)/dev.tripp.tripp-wm" 2>/dev/null || true
while launchctl print "gui/$(id -u)/dev.tripp.tripp-wm" >/dev/null 2>&1; do sleep 0.1; done
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.tripp.tripp-wm.plist"
```

The wrapper retains `~/.cache/dotfiles/tripp-wm` for compatibility with the
existing installation. No chezmoi hooks are required. After source changes,
copy the updated package and wrapper, then build and restart explicitly.
The checked-in config has concrete colors from the former dotfiles theme.

On first start, grant tripp-wm two permissions in System
Settings, Privacy & Security. With Accessibility, it starts managing windows a
moment later, and the pointer grid can read keys. With Input Monitoring, manual mouse resizing updates column widths, and the right Option action mode can read keys.
Without it, tripp-wm cannot detect mouse releases. Until both are granted, the menu shows which one
is missing. launchd starts it at login and restarts it after a crash, but not
after Quit. When it stops, it moves hidden windows back on screen.

Run the tests before installing:

```sh
bash scripts/run-tripp-wm.sh
bash scripts/run-tripp-wm-wrapper.sh
```
