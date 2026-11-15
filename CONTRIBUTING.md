# Contributing

How to build OpenRay, what a build from source does differently from a
release, and what a change should look like. [ROADMAP.md](ROADMAP.md) says
what is planned, and [docs/DESIGN.md](docs/DESIGN.md) how each piece is
built; a change that departs from the design changes the design in the same
pull request.

## Build and run

You need macOS 26 and Xcode 26, or later. You do not need an Apple Developer
account.

```bash
git clone https://github.com/GabrielDeml/openray.git
cd openray
open OpenRay.xcodeproj
```

Run the `OpenRay` scheme. The first build downloads GRDB and Sparkle. OpenRay
has no Dock icon: look for the magnifying glass in the menu bar, or press
⌥Space.

## What a Debug build does differently

The scheme runs the Debug configuration, which is set up so that a build from
source can live beside an installed OpenRay without the two touching each
other.

- Its bundle identifier is `io.github.gabrieldeml.openray.debug`. It has its
  own database, preferences, Keychain item and permission grants.
- macOS shows it as "OpenRay Dev", in System Settings for instance.
- It never looks for updates. Settings › Updates says so.
- The launch-at-login switch is disabled.
- A change to the database schema erases the Debug database, so that a
  migration can be edited while it is being written.
- It contains the pasteboard probe of design §4.5, a test window that opens
  only with the launch argument `-OpenRayPasteboardProbe`.

## Signing, and permissions that stop working

A Debug build is signed ad hoc, which needs no account. The price is that
every rebuild is a different app to macOS, so a permission granted to the
build before no longer counts: System Settings shows OpenRay Dev switched on
under Accessibility, and pasting still only copies. For the same reason the
Keychain may ask again before it lets a rebuilt app read the API key.

To clear the stale grant and grant it again:

```bash
tccutil reset Accessibility io.github.gabrieldeml.openray.debug
```

To stop it from happening, sign with a team of your own; the free Personal
Team of an Apple ID is enough. Put the team into `Config/Local.xcconfig`,
which is git-ignored and which both configurations read last:

```
DEVELOPMENT_TEAM = <your team ID>
CODE_SIGN_IDENTITY = Apple Development
```

Nobody has tried these two lines yet (design §6.6). If they need a third,
please say so in an issue or a pull request.

### Release builds

`xcodebuild -configuration Release` compiles, and CI builds it, but a Release
build straight from a clone is not expected to launch. It keeps the hardened
runtime, and library validation then refuses `Sparkle.framework`, which an
ad-hoc signature gives no team. A Debug build is not affected. To run a
Release build, sign it with your team as above, or add this to
`Config/Local.xcconfig`:

```
CODE_SIGN_ENTITLEMENTS = Config/OpenRay-Debug.entitlements
```

Xcode's Profile action builds the Release configuration, so the same goes for
a run under Instruments.

A Release build is a released OpenRay in everything but its signature. It has
the bundle identifier of an installed copy, and so reads and writes that
copy's database and preferences, the update settings among them. And once the
maintainer's public update key is in `Config/Shared.xcconfig`, it looks for
updates like a released build: its build number is 1, every release is newer,
and it would replace itself with the official one. To keep it from that, add
this line to `Config/Local.xcconfig`, which leaves your build without a key:

```
SPARKLE_PUBLIC_ED_KEY =
```

## Tests

All logic is in the Swift package `Packages/OpenRayCore`, so it can be tested
without launching the app:

```bash
swift test --package-path Packages/OpenRayCore
```

- Tests use Swift Testing (`import Testing`).
- There is no app test target. Put what decides something into Core, behind
  a protocol if it needs the system, and keep the app target to what needs
  AppKit or SwiftUI.
- A test never touches your real data: no Application Support folder, no
  user defaults, no pasteboard, no Keychain, no network. It uses the
  in-memory stores and fakes in `Tests/OpenRayCoreTests`, or a folder with a
  UUID in its name under the temporary directory, which it removes.
- `bash Scripts/test-release-scripts.sh` tests the scripts of the release
  job. CI runs it.
- The benchmarks are a test target of their own and are skipped unless you
  ask for them. They print timings and assert nothing:

  ```bash
  OPENRAY_BENCHMARKS=1 swift test --package-path Packages/OpenRayCore \
    -c release -Xswiftc -enable-testing --filter OpenRayCoreBenchmarks
  ```

Before a pull request, also build the app the way CI does:

```bash
xcodebuild -project OpenRay.xcodeproj -scheme OpenRay -configuration Debug \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

CI builds with Xcode 26 and Swift 6.2. Do not use a language feature newer
than that, even if your Xcode accepts it.

## Rules the build checks

- **`OpenRayCore` imports no AppKit, SwiftUI, Carbon or Cocoa.** CI greps for
  those imports. What Core needs from the system it gets through a protocol
  that the app target implements.
- **Both targets build in the Swift 6 language mode** with strict
  concurrency. The app target is main-actor isolated by default (design
  §3.4).
- **The two `Package.resolved` files agree on GRDB**, and both builds keep to
  them ([DEPENDENCIES.md](DEPENDENCIES.md)).

## Style

The code is meant to be read by the next person who has to change it.

- Plain control flow and named intermediate values, not dense chains.
- No new protocol, generic or wrapper type unless the design calls for it or
  two real callers need it.
- Comments say why, where the code cannot. They do not narrate the change.
- Match the file you are in: its naming, its comment tone, its layout. No
  reformatting of lines you did not otherwise change.

Formatting is by convention so far: 4 spaces, 100 columns, and in a test file
`import Testing` first and the module import last, after a blank line. There
is no committed `.swift-format` and CI does not lint yet. If you run
`swift format`, give it those settings and run it on the files you changed
only.

Text that Core shows to the user goes through
`String(localized:bundle: .module)` and has an entry in
`Packages/OpenRayCore/Sources/OpenRayCore/Resources/Localizable.xcstrings`.

## Adding a command

Every command reaches the launcher the same way (design §4.2.3):

1. Its logic is a `SearchSource` in Core, in a folder of its own under
   `Packages/OpenRayCore/Sources/OpenRayCore`, with tests.
2. A `Feature` in `OpenRay/Features` makes that source and, if it has them,
   its settings pane and its screens.
3. The feature is added to the list in
   `OpenRay/Features/BuiltInFeatures.swift`. That list is the only place the
   launcher learns about it; no launcher code changes.

`OpenRay/Features/UpdatesFeature.swift` with
`Packages/OpenRayCore/Sources/OpenRayCore/Updates` is a small example.

New files under `OpenRay/` are picked up by the Xcode project on their own.
`project.pbxproj` changes only for a package dependency, an entitlement or a
build setting, and build settings live in `Config/*.xcconfig`.

## Dependencies

OpenRay has two, and adding a third needs a written reason in the pull
request: what it saves and why OpenRay should not own that code.
[DEPENDENCIES.md](DEPENDENCIES.md) has the two, their pins and how to change
one.

## Privacy

[PRIVACY.md](PRIVACY.md) lists every network request OpenRay makes and
everything it stores. A change that adds either changes that file too.

## Releases

Releases are made by the maintainer by pushing a tag.
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) has the steps. If your change is
something a user would notice, add a line under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md).
