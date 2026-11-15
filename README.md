# OpenRay

An open-source launcher for macOS: summon it with a hotkey, type, and act.

OpenRay is still early. Right now a global hotkey opens the launcher, and it
finds and opens the apps on your Mac, ranking them by what you pick. It also
runs system commands such as Sleep and Empty Trash, opens quicklinks with what
you type, and lists more actions for the selected result with ⌘K. Type a
calculation or a unit conversion and the answer is the first result: Return
copies it, and ⌘Return pastes it into the app you came from once OpenRay has
the Accessibility permission. Aliases, quicklinks and launch at login are set
up in its settings window. See [ROADMAP.md](ROADMAP.md) for what is planned and
in what order, and [docs/DESIGN.md](docs/DESIGN.md) for how it is built.

## Requirements

- macOS 26 or later
- Xcode 26 or later

## Build and run

Open `OpenRay.xcodeproj` in Xcode and run the `OpenRay` scheme, or build from
the command line:

```bash
xcodebuild -project OpenRay.xcodeproj -scheme OpenRay build
```

The first build downloads [GRDB](https://github.com/groue/GRDB.swift), the
only dependency, so it needs a network connection.

## Test

The logic lives in a Swift package so it can be tested without launching the
app:

```bash
swift test --package-path Packages/OpenRayCore
```

## Layout

- `OpenRay/` is the app target: windows, views and system integration.
- `Packages/OpenRayCore/` is the core logic: matching, ranking, the command
  model and storage.
- `Config/` holds the app's entitlements.

## Licence

[MIT](LICENSE)
