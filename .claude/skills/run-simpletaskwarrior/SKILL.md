---
name: run-simpletaskwarrior
description: Run, drive, and screenshot the SimpleTaskwarrior macOS app with a scratch Replica and Taskrc. Use to launch the app, check a change in the running app, work a manual test plan, or reproduce a UI or window-restoration bug.
---

# Run SimpleTaskwarrior

Two drivers, both run from the repo root:

- **`headless.py`, the default.** A hidden instance of the Debug build, driven through the in-app
  Debug driver (`Sources/App/DebugDriver.swift`) over a Unix socket. It never touches the cursor,
  keyboard or focus of the person at the Mac, and agents run their own instances in parallel.
- **`driver.sh`, for real input.** System Events and posted mouse events on the visible app. Reach
  for it only when the bug is in what headless bypasses: window restoration, activation, the first
  click on an inactive window, or a panel's own UI. Tell Paul first: it takes over his cursor and
  keyboard.

`task` 3.5.0 must be on PATH (`brew install task`) for the fixture.

## Run headless

```bash
H=.claude/skills/run-simpletaskwarrior/headless.py
D=.claude/skills/run-simpletaskwarrior/driver.sh
F="$TMPDIR/stw-$RANDOM"                # a fresh scratch directory per agent
$D fixture "$F"                        # Replica + Taskrc with `size` (S,M,L) and `estimate` UDAs
just build                             # once; `launch` doesn't build
$H launch "$F"                         # a hidden instance of its own, named by $F
$H open "$F" "$F/replica"
$H frame "$F" 1500 700                 # the window's content size
$H choose "$F" "$F/taskrc"             # the next open panel picks this file without showing
$H menu "$F" File "Choose Taskrc…"
$H context "$F" Priority               # toggles a column in the header's menu
$H click "$F" 2                        # selects table row 2 (from 0)
$H context "$F" Delete 1               # an item in the menu on row 1, "Pay rent", which repeats…
$H sheet "$F" Delete                   # …so a sheet asks, and this answers it
$H key "$F" n command                  # ⌘N; key equivalents go through their menu item
$H type "$F" "Buy milk"                # into the first responder
$H key "$F" $'\r'
$H dump "$F"                           # the window as JSON
$H shot "$F" "$F/table.png"            # then Read the PNG
$D layout "$F/replica"                 # the table's autosaved columns and sort
$H quit "$F"
```

`$H help` lists the commands.

**Check with `dump`, confirm with `shot`.** Every command but `launch`, `choose` and `quit` replies
with a `dump`: each table's visible columns, cell text and selected rows, the first responder, and
the sheet's text and buttons. An `error` in the reply, with exit status 1, means the command did
nothing: a menu item that's disabled, a title that isn't there. Read the table from `dump`, then look at a screenshot
for anything visual. The fixture gives 7 Pending rows plus 2 Recurrence instances: an active task
(3), a blocked one (7), one with 2 annotations (4), one `scheduled` 4 minutes out (9), and one
waiting.

**Screenshots are the window alone**, rendered by the app at the display's scale (2× on Retina), so
a point is `pixel / 2` from the window's top left.

## Gotchas

- **The sidebar renders blank white in `shot`.** The window renders itself, and its glass material
  doesn't. Check the sidebar's content through `dump`, where it's the `outline` table.
- **Menus are validated as the app would.** The hidden app is never active and so has no key
  window; the driver finds each item's target from the Replica window and asks it whether the item
  is enabled. A wrongly disabled item is a driver bug as much as an app one: compare with
  `driver.sh` before chasing it.
- **`choose` covers the Open Replica, Choose Taskrc and Locate Replica panels**, whichever opens
  next. A panel with no override would show on Paul's screen: give it one in `PanelOverride` too.
- **Each `$F` is one instance.** Commands for it go to a socket at `/tmp/stw-<hash>.sock`, which
  `launch` creates. Window restoration is off, so a launch opens no windows until `open`. Every
  window the instance shows, sheets and alerts included, is transparent and lets clicks through.
- **The Debug driver is linted by the app build** with SwiftLint strict, as is everything under
  `.claude/`: a violation fails `just build` with exit 65 and no error printed. Find it with
  `just build > log 2>&1; grep ❌ log`.
- **`task` creates Recurrence instances only when a report runs**, so the fixture ends with
  `task next`. Without it the Replica has the template and no instances.
- **Autosave is keyed by the standardized path**, which drops `/private` and doubled slashes
  (`$TMPDIR` ends in `/`): `/private/tmp/x` is saved as `replica:/tmp/x/`. `layout` normalises
  its argument to match.

## Run with real input

```bash
$D launch                          # `just run`: builds, quits the old dev copy, opens the app
$D open "$F/replica"               # opens the Replica, no panel
$D frame                           # front window to (100,100), 1500×700
$D taskrc "$F/taskrc"              # File > Choose Taskrc… via Go to Folder
$D header Priority                 # toggles a column in the header's context menu
$D click 1100 166                  # left-click in global points; the header row is y=166
$D shot "$F/table.png"             # capture the framed window
$D relaunch                        # ⌘Q, then launch with no file: restoration only
```

The terminal running the agent needs Accessibility access (System Settings > Privacy & Security),
or every `osascript` call fails. `$D help` lists the commands.

- **`shot` captures a screen region in points**, and the PNG holds the display's pixels for it.
  With the default frame, a point is `100 + pixel / scale` on each axis; the Read tool shows a
  downscaled image and states the original size, so convert through that.
- **Keystrokes need the app frontmost.** `osascript -e 'tell application "System Events" to
  keystroke …'` goes to the terminal, which is how a Choose Taskrc… panel silently gets nothing.
  The driver's `se` sets `frontmost` inside the `tell process` block every call.
- **Menus are driven by type-select**: right-click, type the item's title, Return. Positions of
  context-menu items move with the click point, so don't click them by coordinate. Chained straight
  after `taskrc`, `header` once missed a UDA column; screenshot to confirm, and rerun if it did.
- **The previous session's Replica windows come back** on launch through window restoration.
  Harmless; `se` acts on the frontmost window, which is the one `open` just brought forward.
- **Stale builds:** `open -a` reuses a running copy; `launch` goes through `just run`, which quits
  the old dev build first.

## Human path

`just run`, then File > Open Replica… (⌘O) and File > Choose Taskrc… (⌥⌘O).
