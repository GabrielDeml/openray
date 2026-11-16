# Dependencies

OpenRay ships with two libraries it did not write. Both are pinned to an exact
version, and both licence texts are shown in Settings › About.

| | GRDB.swift | Sparkle |
|---|---|---|
| Source | <https://github.com/groue/GRDB.swift> | <https://github.com/sparkle-project/Sparkle> |
| Version | 7.12.0, exactly | 2.10.1, exactly |
| Licence | MIT | MIT, with the licences of the code Sparkle bundles (bsdiff, sais-lite, Ed25519, `SUSignatureVerifier`) in the same file |
| Pinned in | `Packages/OpenRayCore/Package.swift` | `OpenRay.xcodeproj/project.pbxproj` |
| Resolved in | `Packages/OpenRayCore/Package.resolved` and the project's `Package.resolved` | the project's `Package.resolved` |
| Linked by | `OpenRayCore`, and through it the app | the app target only, as a binary framework |
| Licence text in the app | `OpenRay/Resources/Licenses/GRDB-LICENSE.txt` | `OpenRay/Resources/Licenses/Sparkle-LICENSE.txt` |

The project's `Package.resolved` is
`OpenRay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Why each is there

**GRDB.swift** is how OpenRay talks to SQLite: a connection pool, migrations,
observation of changes and full-text search, with types that fit Swift's
concurrency checks. Usage, aliases and quicklinks are stored through it. Doing
the same against the C API would be a large amount of code of the kind where
mistakes lose data.

**Sparkle** is the updater. It checks the feed, verifies the signature of an
update, installs it and restarts the app. Writing an updater is security work
that an app should not do for itself. Only
`OpenRay/System/SparkleUpdater.swift` imports it, and `OpenRayCore` does not
depend on it.

## Changing a version

Both builds are told to keep to their `Package.resolved` (`swift test
--force-resolved-versions`, `xcodebuild -disableAutomaticPackageResolution`),
so a pin that was changed in one place and not the others fails the build.

For GRDB:

1. Change the version in `Packages/OpenRayCore/Package.swift`.
2. `swift package --package-path Packages/OpenRayCore resolve` updates the
   package's `Package.resolved`.
3. `xcodebuild -project OpenRay.xcodeproj -resolvePackageDependencies`
   updates the project's. CI fails if the two files disagree about GRDB.
4. Copy GRDB's `LICENSE` at the new version over `GRDB-LICENSE.txt`.

For Sparkle:

1. Change the version of the package reference in
   `OpenRay.xcodeproj/project.pbxproj`, or in Xcode under Package
   Dependencies.
2. `xcodebuild -project OpenRay.xcodeproj -resolvePackageDependencies`.
3. Copy Sparkle's `LICENSE` at the new version over `Sparkle-LICENSE.txt`.
   It also holds the notices of what Sparkle bundles, and those change too.
4. In `.github/workflows/release.yml`, set `SPARKLE_VERSION` and
   `SPARKLE_TARBALL_SHA256`. The hash is the `digest` of the asset
   `Sparkle-<version>.tar.xz` in
   `https://api.github.com/repos/sparkle-project/Sparkle/releases/tags/<version>`.
   The release job stops early when the version there is not the one the app
   links.
5. Read Sparkle's release notes for changes to `generate_appcast` and to the
   delegate methods `SparkleUpdater` implements.

For either, change the version in this file and in the table of section 5.2
of [docs/DESIGN.md](docs/DESIGN.md), and run the tests and both builds.

## Adding one

The rule is in section 5.2 of the design: third-party code is avoided unless
it saves substantial, risky work. A pull request that adds a dependency says
in writing what it saves and why OpenRay should not own that code, pins an
exact version, adds the dependency to this file and its licence text to
Settings › About. That section also lists what was considered and left out,
with the reasons.

The actions and tools the release job uses are pinned too, by commit or by
hash, in `.github/workflows/release.yml`. They are not part of the app.
