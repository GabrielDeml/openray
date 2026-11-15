# OpenRay

An open-source launcher for macOS: summon it with a hotkey, type, and act.

OpenRay is still early. Right now a global hotkey opens the launcher, and it
finds and opens the apps on your Mac, ranking them by what you pick. See
[ROADMAP.md](ROADMAP.md) for what is planned and in what order, and
[docs/DESIGN.md](docs/DESIGN.md) for how it is built.

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

## Licence

[MIT](LICENSE)
