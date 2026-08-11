<<<<<<< HEAD
# Gruppen
=======
# Gruppen

Version 2.0 — workspace manager plus a stash/clipboard engine with notch and
shelf overlays.

A macOS workspace manager. Group your applications, launch a whole group with
one click or one hotkey, and force close the group when you're done with that
context.

Native SwiftUI, built with the Xcode Command Line Tools — there is no Xcode
project and no third-party dependency.

## Build

```bash
./build.sh              # build into ./build
./build.sh --install    # build, then replace /Applications/Gruppen.app
./build.sh --run        # build and launch
./build.sh --dmg        # package build/Gruppen-<version>.dmg for sharing
```

Regenerate the app icon after changing `Tools/makeicon.swift`:

```bash
swift Tools/makeicon.swift && ./build.sh
```

## Using it

- **+ New Gruppe** creates a group. **Edit** opens its configuration sheet.
- Add apps from a picker rooted at `/Applications`, or drag `.app` bundles onto
  the list from Finder.
- **Launch** starts every app in the Gruppe. Apps already running are left
  alone, and nothing steals focus unless you turn that on in Konfiguration.
- **Terminate** force closes the Gruppe's apps.
- **When partly running** — some apps up, some down, is the one genuinely
  ambiguous state. Each Gruppe decides for itself: on, the button reads
  **Launch Rest** and starts what is missing; off, it reads **Terminate** and
  closes what is up. The card button, the context menu, the menu bar item and
  the global shortcut all resolve through the same rule.
- **Global shortcut** — click the field, press the combination you want. It
  binds system-wide and toggles the Gruppe from any app.
- Search filters by Gruppe name *or* by application name.
- **Snapshot** turns whatever you have open right now into a Gruppe: a
  pre-checked list of your running windowed apps, which you can trim or top up
  with apps that aren't running.
- **Suggested Gruppen** chips appear when a preset rule matches what is
  installed. One click creates the Gruppe.
- **Strict Execution Sequence** (per Gruppe) launches apps 1→N in list order
  and terminates them N→1 in reverse, pausing a configurable 0–3s between
  steps. Drag rows to set the order; each row shows an illuminated step badge.
- **Colour** is any hex. Five quick-select swatches (Guards Red, Acid Green,
  Industrial Orange, Signal Yellow, Cobalt) sit next to a native colour picker.

## Konfiguration

Opened from the header button, the menu bar item, or `⌘,`.

| Setting | Effect |
| --- | --- |
| Launch at startup | Registers Gruppen as a login item via `SMAppService` |
| Show in menu bar | Menu bar item for toggling Gruppen without the window |
| Show Dock icon | Turn off for a menu-bar-only app |
| Focus apps when launching | Bring windows forward instead of opening behind your work |
| Termination behaviour | Force quit immediately, or quit gracefully with a 3s/10s leash |
| Rescan Applications | Re-evaluate presets, repair moved `.app` paths, drop stale icons |
| Show suggested Gruppen | Hide the preset chips on the overview entirely |

Menu bar and Dock icon can't both be switched off — the last one on refuses,
so the app is always reachable.

## Behaviour worth knowing

- **Status is polled every two seconds.** macOS posts no launch or terminate
  notifications for `LSUIElement` menu-bar apps, which is most of what ends up
  in a Gruppe, so notifications alone leave the indicators stale.
- **Helpers count as the app.** Some apps hand off to a helper and exit —
  Backdrop leaves only `Backdrop.app/Contents/Resources/BackdropWallpaper.app`
  behind. Any running process inside the app bundle counts, otherwise those
  apps read as stopped and deactivation has nothing to close.
- **Shared apps are protected.** An app in two Gruppen is spared when one is
  terminated while the other is still active.
- **Reactivating cancels a pending force quit.** With a grace period set,
  deactivation resolves the exact processes to close up front and only kills
  those. Relaunching during the grace period cancels the kill, so apps you
  just started are never caught by an earlier deactivation's timer.
- **Sequenced termination is LIFO on purpose** — the last app launched is the
  first closed, which is what you want when later apps depend on earlier ones.
  Relaunching mid-sequence cancels the in-flight sequence rather than letting
  the two interleave.
- **Adding apps to a sequenced Gruppe appends** rather than sorting
  alphabetically; in a sequence, order *is* the configuration.
- **Recording releases existing hotkeys**, so pressing an already-bound
  combination records it instead of firing it. Escape cancels, Delete clears.
- **Gruppen never force quits itself**, even if you add it to a Gruppe.
- **One window, one instance.** The main scene is a `Window`, not a
  `WindowGroup`, so it cannot be duplicated. Copies of the bundle in different
  locations are separate processes to LaunchServices, so a second Gruppen
  really can start — it detects the running one, focuses it, and quits.
  Clicking the Dock icon with the window closed brings that window back.
- Shortcuts macOS or another app already owns show struck through and dimmed
  rather than silently failing.

## Performance

The main thread must stay idle when nothing is happening. Two rules earn that:

- **Never hand a `@Published` property straight to a SwiftUI binding that the
  framework writes back to.** `@Published` republishes on *every* assignment,
  identical or not, because it fires in `willSet` — ahead of any `didSet`
  equality guard. `MenuBarExtra(isInserted:)` writes back on each scene update,
  so `$settings.showMenuBar` span the main thread at 100% forever. The binding
  filters no-op writes instead.
- **The application index is pull-only.** Preset matching is a handful of
  `fileExists` calls, run at launch and when you press Rescan — never on a
  timer. The directory walk happens off the main actor; the LaunchServices
  lookups that repair moved bundles stay on it.
- **Sequencing uses `Task.sleep`, not a polling loop.** One cancellable task
  per Gruppe, nothing spinning between steps.
- **The poll builds its lookup once.** Resolving "is this app running" used to
  filter the whole process list per app, allocating an array each time and
  touching `bundleURL` — an expensive cross-process property — once per app per
  process. It now builds a bundle-id set and a path list once per tick and
  probes them. Measured on 23 apps against 81 processes: **10.3 ms → 0.51 ms**
  per poll, ~20× less work every two seconds.
- **Aggregate counts are cached, not recomputed in `body`.** The status bar
  reads `activeCount` / `runningTotal`, maintained when the data changes.
- **App icons are cached.** `NSWorkspace.icon(forFile:)` hits IconServices per
  call and returns a fresh `NSImage` each time, so uncached icons both cost I/O
  and make SwiftUI treat every image as changed.

Idle cost is ~0% CPU. If that regresses, `sample Gruppen 5` will show it:
a busy `AppGraph.updateGraph` means a view-update loop, not slow work.

## Design

"Industrial Dark" — strict monospace for data, high-contrast orange and green
accents, precise hairline borders. Tokens live in `Sources/Theme.swift`.

The vocabulary follows the app icon's switch panel, kept deliberately quiet so
the UI stays readable:

- **`LED`** — a Gruppe's colour renders as an indicator lamp with a specular
  glint, lit when the Gruppe is active or its apps are running and a dark lens
  otherwise. Only lit lamps bloom, so the glow means something.
- **`.bezel()`** — hairline highlight along the top edge, the way light catches
  moulded plastic.
- Primary buttons carry a lit-cap gradient, echoing the illuminated rocker.
- The active rail glows in the Gruppe's colour.
- **`.recessed()`** — the inverse of the bezel: dark along the top lip, light
  along the bottom. Inputs, key caps and icon sockets are milled *into* the
  panel; cards sit *on* it, with a gradient and a drop shadow.
- **`.grain()`** — a 128×128 noise tile, generated once and reused, gives flat
  surfaces a moulded finish. Note that `.overlay` blending is a no-op at
  mid-grey, so the noise spans 56–200; clustered values are invisible at any
  opacity.
- Header and footer are separate plates: a highlight along their top edge and a
  hard shadow along the bottom.

### App icon

Drop a square PNG at `Resources/icon-source.png` and rerun the icon script; it
always wins over the drawn fallback.

```bash
swift Tools/makeicon.swift && ./build.sh --install
```

Any Gruppe colour is a hex string. `Color` derives the whole lamp from it —
`lensTint` (unlit smoked lens), `litCore` (near-white filament), `lensGradient`
and `bloom` — so a dark navy and a bright yellow both read as genuinely lit.
Unparseable hex falls back to `#FF6B00` rather than crashing on stored data.

Two colours deviate from the original spec, both for contrast:

| Token | Spec | Used | Why |
| --- | --- | --- | --- |
| `--text-muted` | `#525866` | `#7E8695` | 2.42:1 → 4.71:1; it carries the smallest type in the UI |
| Primary button text | `#FFF` | `#0A0B0D` | 3.30:1 → 5.95:1 on `--accent-orange` |

## Stash

A shelf for things in transit. Drag anything to the notch, to either screen
edge, or shake the pointer mid-drag; a small non-activating panel appears, you
drop into it, and you drag back out wherever you needed it. Dragging an item out
removes it, and emptying the shelf closes it.

### The Passive Sentinel pattern

The triggers cost nothing because Gruppen never asks where the cursor is.
Instead it hands the window server three microscopic transparent `NSPanel`s —
one across the notch (via `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, with a
top-centre band as fallback) and a 4pt strip down each screen edge. The window
server is already hit-testing every drag; a sentinel simply receives
`draggingEntered` when one crosses it. No polling, no timer, no cursor tracking.

### The armed drag monitor

Shake detection uses an event-driven lifecycle rather than a permanent monitor:

| Event | Effect |
| --- | --- |
| `.leftMouseDown` | **arms** the `.leftMouseDragged` monitor |
| `.leftMouseUp` | **disarms** it immediately |

While you are not holding the button, the only live monitor is a mouse-down
watcher that fires once per click. Inside the armed monitor, evaluation is
throttled to ~60Hz (`timestamp` delta ≥ 0.016), uses integer maths, and discards
anything under 5pt as jitter. Three direction reversals inside 0.5s confirm a
shake.

**Deferred IPC:** `NSPasteboard(name: .drag)` is not touched until the shake has
already been confirmed. Reading a pasteboard is cross-process traffic, so it
happens once, after the cheap arithmetic has already said yes.

## Layout

Tools are self-contained: a page, optionally its own settings pane, and nothing
the rest of the app has to know about.

| Path | Purpose |
| --- | --- |
| `Core/Model.swift` | `AppEntry`, `AppGroup`, `Shortcut`, running-instance matching |
| `Core/GroupStore.swift` | Persistence, editing, launch/terminate, hotkeys, index |
| `Core/AppSettings.swift` | App-wide preferences |
| `Core/Hotkeys.swift` | Carbon global hotkeys and the key recorder |
| `Core/Presets.swift` | Static preset rules and disk matching |
| `Design/Theme.swift` | Tokens, lamp optics, button styles, surface modifiers |
| `Design/Components.swift` | Shared rows, sections, toggles — the panel chrome |
| `Navigation/ToolPage.swift` | The tool enum: icon, badge, summary, availability |
| `Navigation/NavigationModel.swift` | Selected page, rail state, settings-pane state |
| `Navigation/SidebarView.swift` | Collapsible tool rail |
| `Navigation/RootView.swift` | Sidebar + `ToolHost` + tool header |
| `Tools/Workspaces/*` | The Workspaces tool: page, grid, editor, snapshot, settings |
| `Tools/General/GeneralSettingsPane.swift` | App-wide settings page |
| `GruppenApp.swift` | Scene, menu bar, app delegate |
| `Tools/makeicon.swift` | Builds `Resources/AppIcon.icns` from `icon-source.png` |

`build.sh` compiles `$(find Sources -name '*.swift')`, so a new file is picked
up by existing anywhere under `Sources/`.

## Adding a tool

1. Add a case to `ToolPage` with its icon, badge and summary.
2. Drop a view in `Sources/Tools/<Tool>/`.
3. Add one line to the `switch` in `ToolHost`.

Set `hasSettingsPane` if it needs isolated settings; the header grows a control
that swaps the tool for its own pane, with no separate window. Tools whose
`isImplemented` is false render an honest "not built yet" placeholder rather
than mock controls.

Gruppen are stored as readable JSON at
`~/Library/Application Support/Gruppen/groups.json`, migrated automatically
from the app's former name. Every launch and kill is recorded in
`~/Library/Logs/Gruppen.log` (capped at 512 KB), which is the fastest way to
answer "what closed my app?".

## Shipping beyond this machine

The build is **ad-hoc signed**, which is fine locally but Gatekeeper will block
it on another Mac. To distribute it you need a Developer ID certificate, then:

```bash
codesign --force --options runtime --sign "Developer ID Application: NAME (TEAMID)" "build/Gruppen.app"
xcrun notarytool submit "build/Gruppen.app.zip" --apple-id APPLE_ID --team-id TEAMID --wait
xcrun stapler staple "build/Gruppen.app"
```

`SMAppService` login items are also more reliable from a properly signed app
installed in `/Applications`. If registration fails, the Konfiguration window
shows the system's error inline rather than leaving the switch lying.

## Testing

`GroupStore(fileURL:)` takes an explicit store location, and tests must pass
one — `FileManager`'s application-support lookup does **not** respect `$HOME`,
so overriding the environment is not enough to isolate a test from live data.

UI can be snapshotted headlessly by hosting a view in an offscreen `NSWindow`
and calling `cacheDisplay(in:to:)`. `ImageRenderer` does not rasterise
`ScrollView` or `LazyVGrid` content and will silently produce empty bodies.
>>>>>>> d75669e (Group Launch + Full Stash complete)
