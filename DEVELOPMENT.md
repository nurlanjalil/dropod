# Developing Dropod

How Dropod is built, why it works the way it does, and where things live. For what Dropod does, see the [README](README.md).

## Build

```sh
./build.sh             # build/Dropod.app
./build.sh --install   # quit the running copy, move the build to /Applications, open it
./build.sh --dmg       # build/Dropod.dmg, the drag-to-Applications disk image to attach to a release
./build.sh --release   # build/Dropod-<version>.zip, the same app as a zip
./build.sh --run       # run from build/ (avoid: it leaves a second Dropod in the Apps list)
```

- `swiftc` compiles `Sources/*.swift` with the Swift 6 compiler in Swift 5 language mode, for arm64 and macOS 14 or later. There is no Xcode project.
- The app icon is drawn in code by `scripts/make-icon.swift` and only redrawn when that script changes.
- Signing is ad hoc unless a code-signing identity called "Dropod Local Signing" exists (or `SIGN_IDENTITY` names another). A stable identity lets macOS remember folder access and the login item across builds.
- Use `--install` for day-to-day testing: Open at Login only registers when Dropod runs from /Applications.

## Architecture

AppKit, no SwiftUI. A menu bar app (`LSUIElement`) with one floating, non-activating window.

```
DragWatcher ── shake / ⇧ ──┐
HotKey ── ⇧⌘Space, ⌃⌘V ────┼─► ShelfManager ── owns ──► DropodWindow ── TabBar, CapsuleView, UndoToast, Peek
ScreenshotWatcher ─────────┤     save / restore              │
ClipboardWatcher ──────────┘     shelves.json                └─► ShelfController (one per tab) ─► ShelfView
                                                                   items, selection, keys,         pile, list, grid,
                                 Importer ◄── drops ───────────────  menus, actions, Quick Look      clipboard list
                                 Actions  ◄── quick actions ───────┘
```

| File | Responsibility |
|:--|:--|
| `main.swift`, `AppDelegate.swift` | Start-up, the menu bar menu and its settings, saving on quit |
| `Settings.swift`, `Shortcut.swift`, `HotKey.swift` | Preferences, shortcut recording, global shortcuts (Carbon hot keys) |
| `DragWatcher.swift` | Notices drags anywhere on screen; shake recognition |
| `ShelfManager.swift` | Shake sessions, Screenshots and Clipboard tabs, expiry, the ⌃⌘V session, saving and restoring |
| `DropodWindow.swift` | The window: tabs, tab bar and chips, collapsing, Undo for closed tabs, sizing |
| `Capsule.swift` | The collapsed capsule: chips, unfolding labels, badges, drops |
| `ShelfController.swift` | One tab: items, name, colour, pin, selection, keys, menus, actions, Quick Look |
| `ShelfItem.swift` | An item (file, text card, link), its kind, size and tag; tab colours |
| `ShelfViews.swift`, `ShelfGrid.swift`, `ClipboardView.swift` | The panel, glass backdrop, pile, list rows, grid, clip list and search |
| `Peek.swift` | The text preview beside the window (JSON and code formatting, links) |
| `ScreenshotWatcher.swift`, `ClipboardWatcher.swift` | Watching the screenshot folder and the pasteboard |
| `Importer.swift`, `Actions.swift`, `Thumbnails.swift` | Turning drops into items, quick actions, previews |
| `LoginItem.swift`, `MenuBarIcon.swift`, `Motion.swift` | Open at Login, the menu bar icon, shared animations |

## Key decisions

- **Drag detection without permissions.** A global mouse-down monitor needs no permission. While the button is held, the drag pasteboard is polled at 60 Hz: a real content drag changes it, while moving a window or selecting text doesn't. Drags that start in Dropod are ignored, so dragging items out never opens a new tab.
- **Shake.** Three changes of direction, each after at least 28 px of travel, within 0.8 s.
- **Focus.** The window is a non-activating panel, so appearing never takes focus. It becomes key only when clicked, or while Undo or ⌃⌘V needs the keyboard. After ⌃⌘V, Dropod re-activates the app you came from.
- **Liquid Glass.** The installed SDK predates `NSGlassEffectView`, so it is looked up at runtime and set up with key-value coding. Without it, `NSVisualEffectView` is used.
- **One window, tabs, a capsule.** Separate shelf windows were confusing, so each pile is a tab. Screenshots and Clipboard are permanent system tabs: they can't be closed, and clearing them asks first.
- **The capsule has no totals.** A running count mostly measured clipboard history. Badges count only what arrived while Dropod was collapsed or hidden, and the chip that received something unfolds a one-line label for 3 s. The capsule grows towards the middle of the screen so it never drifts.
- **Screenshots.** The folder from `com.apple.screencapture` is watched with a `DispatchSource`. New files are recognised by the `kMDItemIsScreenCapture` extended attribute. The temporary folder used while the floating thumbnail shows is protected, so a screenshot is copied when its file is saved; "Instant" turns the thumbnail off.
- **Clipboard.** The pasteboard's `changeCount` is polled every 0.5 s. Concealed, transient and auto-generated types (nspasteboard.org) are skipped, as are 1Password and file copies. Clips are capped at 100,000 characters.
- **Dragging out.** Items leave an unpinned tab once dragged somewhere (a setting), and an emptied unpinned tab closes itself.
- **Editing keys.** The app has no Edit menu, so the panel handles ⌘C, ⌘V, ⌘X and ⌘A for text fields itself.
- **ZIP, images, text.** ZIP uses `ditto` without resource forks or extended attributes, so there are no `__MACOSX` folders. Images use ImageIO and never enlarge. Text recognition uses Vision on the device.

## Naming

The app was first called Stash and was renamed to Dropod, because a shelf app called "Stash" already exists. The bundle identifier is `io.github.nurlanjalil.Dropod`.

## Storage

Everything lives under `~/Library/Application Support/Dropod/`:

| Path | Contents |
|:--|:--|
| `shelves.json` | `{x, y, collapsed, active, tabs}`: every tab with items, every pinned tab and every named tab, with its items, clips and dates. Written shortly after each change and on quit. The older array format is migrated. |
| `Drops/<id>/` | Dropped text, links, images, promised files and action results |

At launch, tabs are restored first; then any `Drops` folder that no tab refers to is removed. Preferences are stored in `UserDefaults` under the bundle identifier.

**Before testing against the real app**, back up the folder above and quit Dropod before writing test state, so a test can't overwrite your tabs.

## Testing

Pointer and keyboard interactions (shaking, dragging between apps, clicks) are checked by hand. Logic that runs on its own was tested with small one-off harnesses compiled with the sources (top-level code goes in a `main.swift`):

| Area | Tested |
|:--|:--|
| Shake | Simulated pointer paths: quick shakes open; wiggles, slow moves and straight drags don't |
| Import | Text, links with page titles, image data, files, unsafe names, blank text |
| Actions | Resizing, format conversion, ZIP of a file, a folder and several items, text recognition |
| Screenshots and clipboard | Screenshot detection by attribute; skipping private and concealed copies |
| Tabs | Closing and Undo; system tabs refusing to close; drop rules per tab |
| Peek | JSON and code detection, links, and 100,000 characters formatted in about 55 ms |
| Saving | Round trips of the real `shelves.json`, including migration and cleanup of unused drops |

## Known limitations

- Apple silicon only for now: the build targets arm64.
- Quick Look and AirDrop make Dropod the active app; click back into your app afterwards.
- On macOS 26, new menu bar icons can be hidden. Allow Dropod in System Settings → Menu Bar.
- Converting an image with transparency to JPEG fills the transparent areas.
- Ad hoc signing means macOS asks again for folder access after each update. Notarizing with an Apple Developer ID would fix this and remove the "Open Anyway" step.

## Ideas for later

- A universal build (Intel and Apple silicon) and notarized releases.
- Downloads arriving in a tab automatically, without taking focus.
- A drop zone at the MacBook notch, or a shelf that slides out from a screen edge.
- Shortcuts app actions.
- Adjustable shake sensitivity.

Deliberately skipped: cloud share links. They would need a server and accounts, and Dropod would no longer be fully private.
