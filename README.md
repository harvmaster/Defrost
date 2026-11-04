# Defrost

A lightweight menu bar manager for macOS 14+ (tested on macOS 26). Each menu bar item gets one of three policies:

| Policy | Behaviour |
|---|---|
| **Always** | Always visible. |
| **Focused** | Hidden until you click empty space in the menu bar, or press the hotkey (default ⌃⌥Space). |
| **Never** | Never shown, as if the app had no menu bar item. |

Defrost has no menu bar icon of its own. Open the app again from Spotlight or Finder to get to Settings.

## Resource use

The background process has no timers, does no polling and never captures the screen. It only wakes up when:
- you click,
- you press the hotkey,
- `config.json` changes,
- an app launches,
- the Mac wakes from sleep.

It uses about 20 MB of memory. The Settings window runs as a separate process that exits completely when you close it.

## Permissions

Defrost needs **Accessibility** permission to find menu bar items and move them. It does not need Screen Recording.

## Configuration

All configuration lives in `~/.config/defrost/config.json`:

```json
{
  "autoRehideSeconds" : 15,
  "defaultPolicy" : "focused",
  "hotkey" : "ctrl+opt+space",
  "items" : [
    { "id" : "com.apple.menuextra.battery", "name" : "Control Centre — Battery", "policy" : "always" },
    { "id" : "ru.keepcoder.Telegram#0",     "name" : "Telegram",                 "policy" : "focused" }
  ],
  "launchAtLogin" : false
}
```

- **`items`**: within each policy, items are listed left to right as they appear in the menu bar.
- **`id`**: the item's Accessibility identifier if it has one (Apple's items do). Otherwise it is the app's bundle ID plus `#n`, where `n` counts that app's items from the right. These IDs are the same on every Mac.
- **`name`**: only a label for the Settings window.
- **`hotkey`**: modifiers `ctrl`, `opt`, `shift` and `cmd`, plus a key: a letter, a digit, `space`, `f1`–`f12`, arrows and so on. Use `null` for no hotkey.
- **`autoRehideSeconds`**: how long before revealed items hide again. `0` means only when you click away or press the hotkey.
- **Editing by hand:** edits apply as soon as you save; there's no need to restart.

### Using one config on several Macs

You can copy `config.json` to another Mac, or symlink it into a dotfiles repo; Defrost writes through the symlink rather than replacing it.

- **Items that aren't present** (the app isn't installed or isn't running) are left alone. They are kept in the file, skipped when arranging, and shown in Settings as "Not running". When the app starts, its policy is applied.
- **New items** found on a Mac are added with `defaultPolicy`, at the left end of that group. Remove stale entries in Settings with right-click → Forget This Item, or delete them from the file.
- **`launchAtLogin`** is applied on each Mac when Defrost starts or the file changes.

## Building

```sh
swift build                 # debug build
scripts/build-app.sh        # universal build/Defrost.app, signed with the first Developer ID found (else ad-hoc)
scripts/release.sh          # signed, notarized and stapled dist/Defrost-<version>.dmg
```

`release.sh` needs notarization credentials. Store them once:

```sh
xcrun notarytool store-credentials defrost-notary --apple-id <apple-id> --team-id <team-id>
NOTARY_PROFILE=defrost-notary scripts/release.sh
```

Releases are built and notarized locally. A GitHub Actions release workflow exists but is disabled; see `.github/disabled-workflows/release.yml` for how to turn it back on.

Logs are written to `~/Library/Logs/Defrost.log`.

## How it works

Defrost uses two invisible divider status items:

```
[Never items] |N| [Focused items] |A| [Always items] [Control Centre, clock]
```

An expanded divider is 10,000 pt wide and pushes everything to its left off-screen. **N** is always expanded. **A** collapses to reveal the Focused items.

Defrost moves items with the same synthetic Cmd-drag that macOS uses for rearranging. On macOS 26 every status item window belongs to Control Centre, so Defrost matches each window to its app through that app's Accessibility tree.

The hiding approach and the item-moving recipe are adapted from [Ice](https://github.com/jordanbaird/Ice) (GPL-3.0).

## License

Defrost is free software, licensed under the [GNU General Public License v3.0](LICENSE).

Copyright © 2026 Harvey Zuccon. Portions are adapted from [Ice](https://github.com/jordanbaird/Ice), copyright © Jordan Baird, also GPL-3.0: the divider hiding technique, the private window-server declarations, and the item-moving event recipe.
