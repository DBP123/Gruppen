# Gruppen

A macOS workspace manager with a drop shelf built into the notch.

Group your applications, launch a whole group with one click or one hotkey, and
close the group when you're done with that context. Then use the same app as a
staging area for files: drag anything toward the notch, park it, and drag it out
somewhere else — or hand it to a script.

Written in Swift and SwiftUI against Apple's own frameworks. **No third-party
dependencies, no Xcode project, no analytics, no network calls** except one:
dropping a link to a remote image fetches that image.

Requires **macOS 13 (Ventura) or later**.

---

## Install

Download the `.dmg` from [Releases](../../releases), open it, and drag Gruppen to
Applications.

The app is **ad-hoc signed**, not notarised — there's no paid developer account
behind it — so Gatekeeper will refuse the first launch. Open it once with
**right-click → Open**, then **Open** in the dialog. macOS remembers after that.

If it still refuses:

```bash
xattr -dr com.apple.quarantine /Applications/Gruppen.app
```

The released build is **Apple Silicon**. On an Intel Mac, build from source (see
below) — `build.sh` compiles for whatever architecture it runs on.

---

## Gruppen (workspaces)

A *Gruppe* is a named set of applications.

- **Activate** launches every app in the group; **deactivate** closes them.
- **Hotkeys.** Record a global shortcut per Gruppe and toggle it from anywhere.
  These use Carbon's `RegisterEventHotKey`, so Gruppen does **not** need
  Accessibility permission.
- **Sequenced launch.** Optionally start apps in list order with a delay between
  each, and close them in reverse.
- **Partial state.** When only some of a Gruppe is running, you decide whether
  the primary action finishes the launch or closes what's up.
- **Menu bar.** Toggle any Gruppe without opening the window. The dropdown can
  show a live CPU/RAM/thread readout of Gruppen itself.
- **Snapshot.** Build a Gruppe from whatever is running right now.

Closing a group force-quits its apps. Anything with unsaved work will say so
first, the same as pressing ⌘Q.

## The Stash

A shelf for files in transit — the thing you want when the source and the
destination can't be on screen at the same time.

**Three ways to open one, all of them passive:**

| Trigger | What happens |
| --- | --- |
| Drag toward the notch | A tray drops out of the bezel |
| Shake a drag left-right | A floating shelf appears at the pointer |
| Drag to the left or right screen edge | A floating shelf appears there |

**What it accepts.** Files, folders, text selections, images, links, and *file
promises* — the IOU that Safari, Photos and Mail hand over instead of a file.
Anything that isn't already a file is written to one, so a snippet of text or an
image dragged off a web page can be dragged straight into Finder afterwards.

**What you can do with what's on it:**

- Drag items back out, individually. Files come out byte-for-byte and
  name-for-name identical.
- Click to select, **shift-click** to select several.
- **Convert** — images to PNG/JPEG/HEIC/TIFF/PDF, documents to
  PDF/DOCX/RTF/HTML/TXT, audio to M4A/WAV/AIFF. Only conversions that make sense
  for the selection are offered. Uses `sips`, `textutil`, `afconvert` and
  CoreGraphics.
- **Zip** the shelf or just the selection into your download folder.
- **Quick Look**, or copy the POSIX path.
- **Drop onto a Gruppe chip** to open the files with that workspace's apps.

## Script Builder

Attach a script to a Gruppe. Dropping files on that Gruppe runs the script with
their paths instead of opening them.

Pick a preset — *move files*, *transform each file*, *run a command*, *copy
paths* — fill in the fields, and you have a working automation without writing
anything. Open the source drawer to see exactly what will run, and edit it if you
want; once you do, the preset stops writing over your version.

Bash, Zsh, Python 3 and JavaScript (JXA). The interpreter row shows the resolved
path, or tells you it isn't installed.

**On safety:** dropped paths are passed as **arguments** — `$1`, `$2`, `"$@"` —
never pasted into the script text, so a file named `; echo hi` is a file name and
not a command. Preset parameters travel as environment variables for the same
reason. Scripts run with a minimal environment, and one that's still going after
60 seconds is stopped.

A script can do anything you can do in a terminal. Read what's in the drawer
before you enable one.

## Guardrails

Listed in the sidebar, marked *planned*, and honest about it — it renders a
placeholder rather than a mock-up of features that don't exist yet.

---

## Idle cost

Gruppen sits at **0.0% CPU** when you aren't using it, and that's a design
constraint rather than a happy accident:

- No polling. The running-apps tracker listens for `NSWorkspace` notifications
  instead of walking the process list on a timer.
- The stash triggers are invisible drop targets that the window server
  hit-tests anyway, plus a drag monitor that only exists between mouse-down and
  mouse-up.
- The performance readout samples only while the menu is open.
- The script engine is dormant until a drop happens.

## Where your data lives

| What | Where |
| --- | --- |
| Gruppen, hotkeys, scripts | `~/Library/Application Support/Gruppen/groups.json` |
| Preferences | `UserDefaults` (`com.dhilanpatel.gruppen`) |
| Activity log | `~/Library/Logs/Gruppen.log` (rotates at 512 KB) |
| Staged files from the stash | `$TMPDIR/Gruppen-Stash`, cleared at launch |

Nothing is sent anywhere. To remove Gruppen completely, delete the app and those
paths.

Launch-at-login uses `SMAppService`. JXA scripts that drive other apps may make
macOS ask for Automation permission — that's the system asking on the script's
behalf, not Gruppen.

---

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`). There is no
Xcode project — `build.sh` calls `swiftc` over `Sources/` directly.

```bash
./build.sh              # build into ./build
./build.sh --install    # build, then replace /Applications/Gruppen.app
./build.sh --run        # build and launch
./build.sh --dmg        # package build/Gruppen-<version>.dmg
```

Regenerate the app icon after editing `Tools/makeicon.swift`:

```bash
swift Tools/makeicon.swift && ./build.sh
```

## Layout

```
Sources/
  App/        NSApplication lifecycle, the scene, the menu bar extra
  Core/       Models, persistence, hotkeys, settings
  Design/     Theme tokens and shared controls
  Engine/     Running-app tracking, icons, zip, conversion, scripts, routing
  Pages/      One directory per tool: Workspaces, Scripts, Settings, Navigation
  Stash/      Shelf windows, drop handling, ingestion, the notch tray
```

A note for anyone reading the code: the comments explain *why* a thing is the
way it is, usually because the obvious version was tried first and measured.
Several of them record numbers — window edge highlights, notch geometry,
compression levels — that were surprising enough to be worth writing down.

## Contributing

Issues and pull requests are welcome. Two house rules:

1. **No third-party dependencies.** If AppKit can do it, AppKit does it.
2. **Nothing that runs when idle.** No timers, no polling loops. If you need to
   know when something changed, find the notification.

## Licence

Not chosen yet — until a `LICENSE` file lands here, no permissions are granted
beyond reading the source and building it for yourself.
