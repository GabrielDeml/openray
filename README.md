# OpenRay

An open-source launcher for macOS: summon it with a hotkey, type, and act.

<!-- The demo goes here, as docs/demo.gif (RELEASE_CHECKLIST.md, section 5). -->

OpenRay is still early. Right now a global hotkey opens the launcher, and it
finds and opens the apps on your Mac, ranking them by what you pick. It also
runs system commands such as Sleep and Empty Trash, opens quicklinks with what
you type, and lists more actions for the selected result with ⌘K. Type a
calculation or a unit conversion and the answer is the first result: Return
copies it, and ⌘Return pastes it into the app you came from once OpenRay has
the Accessibility permission. Type a question and press Tab to ask Claude with
your own Anthropic API key: the answer streams into the launcher, and
follow-ups stay in the same thread. The key is kept in the macOS Keychain.
Window commands such as Left Half, Maximize Window and Move Window to Next
Display move the front window of the app you are in, and Restore Window puts
it back; they need the Accessibility permission too. So does Lock Screen,
which presses ⌃⌘Q for you; whether macOS locks the screen for that has not
been tried yet, and the command goes if it does not. Snippets are pieces of
text you write once and paste from the launcher by name or keyword, or from
the Search Snippets list, which also searches their text; a snippet can fill
in the date, the time or what you last copied, and say where the caret goes.
Search Files finds files and folders by name through Spotlight: Return opens
one, and ⌘K has Show in Finder, Open With, a Quick Look preview, Copy Path
and Move to Trash. These two are new and have only been run by their tests:
no snippet has been pasted into a real app yet, and Search Files has searched
a stand-in for Spotlight, never a real home folder. Aliases, quicklinks,
snippets, launch at login, the API key, the gap between tiled windows, where
Search Files looks and updates are set up in its settings window, which also
shows the version and the licences of what OpenRay is built with. A released
build keeps itself up to date if you let it; a Debug build from source never
looks for updates.

OpenRay sends no telemetry. [PRIVACY.md](PRIVACY.md) lists what it sends and
what it stores.

## Install

OpenRay needs macOS 26 or later.

Releases start with v0.1.0. Once it is on the
[Releases page](https://github.com/GabrielDeml/openray/releases), install
OpenRay with Homebrew:

```bash
brew install gabrieldeml/openray/openray
```

or download `OpenRay-<version>.zip` from that page, unzip it and move OpenRay
to your Applications folder. Either way it then keeps itself up to date, if
you let it.

While the Releases page is empty there is nothing to install, and the way to
get OpenRay is to build it.

## Build and run

Building needs Xcode 26 or later, and no Apple Developer account.

Open `OpenRay.xcodeproj` in Xcode and run the `OpenRay` scheme, or build from
the command line:

```bash
xcodebuild -project OpenRay.xcodeproj -scheme OpenRay build
```

The first build downloads the two dependencies,
[GRDB](https://github.com/groue/GRDB.swift) and
[Sparkle](https://github.com/sparkle-project/Sparkle), so it needs a network
connection.

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
- `Config/` holds the build settings, the entitlements and the Info.plist
  keys that Xcode does not generate.
- `Scripts/` holds the scripts of the release job, with their tests, and the
  script that records Claude API responses as test fixtures. Nothing in the
  build or the tests calls the API; that script does, and only when you run
  it with a key.
- `Casks/` holds the Homebrew cask. The release job copies it to the tap.
- `docs/` holds the design.

## More

- [ROADMAP.md](ROADMAP.md): what is planned and in what order.
- [docs/DESIGN.md](docs/DESIGN.md): how it is built.
- [CONTRIBUTING.md](CONTRIBUTING.md): building, testing and changing OpenRay.
- [PRIVACY.md](PRIVACY.md): what leaves your Mac and what is kept on it.
- [DEPENDENCIES.md](DEPENDENCIES.md): the two libraries OpenRay ships with.
- [CHANGELOG.md](CHANGELOG.md): what changed in each release.
- [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md): how a release is made.

## Licence

[MIT](LICENSE)
