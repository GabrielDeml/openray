# Release checklist

Everything a release of OpenRay needs that the repository cannot do for itself:
the accounts, keys and settings that have to exist before the first tag, the
steps of each release, and the checks that need a person at a Mac.

Milestone 6 was built without an Apple Developer account, without any secret and
without launching the app. The release job in
[.github/workflows/release.yml](.github/workflows/release.yml) has therefore
never run, and the checks of section 4 have not been worked through. The
owner ran a Debug build of milestone 6 on 2026-11-15 and reported that it
works, Quick AI with a real key included. That was a try-out and not this
list. This file is the list of what is left. How the pieces work is in section 6 of
[docs/DESIGN.md](docs/DESIGN.md).

Milestone 7 has added the window commands, Lock Screen, snippets and file
search, built the same way: no window was moved, the screen was never locked,
no snippet was pasted, the clipboard was never read and no real folder was
searched. CI has built and tested the window commands and Lock Screen;
snippets and file search get their first run with the pull request that adds
them. Their checks are under "New in
milestone 7" in section 4: a block for the window commands and Lock Screen,
one for snippets and one for file search.

Milestone 8 has added script commands, built the same way again: OpenRay was
not launched, no login shell was started, and the only scripts that ever ran
were ones the tests wrote into temporary folders. Their checks are under "New
in milestone 8" in section 4, and what their first release fixes for good is
in section 1.

Work through sections 1 and 2 once. Sections 3 and 4 are for every release.

## 1. Confirm before the first tag

Milestone 6 took the design's default for each of these. The first two cannot
be changed once a release has shipped: installed copies keep asking the old
feed, and macOS keeps permissions, preferences and the Keychain item under the
old identifier.

- [ ] **Feed URL** (design §8, item 21). Default:
  `https://gabrieldeml.github.io/openray/appcast.xml`, on GitHub Pages. Buy a
  domain first if the feed should ever be able to move away from GitHub.
  Change it in `SPARKLE_FEED_URL` in
  [Config/Shared.xcconfig](Config/Shared.xcconfig), where the two slashes are
  written `/$()/`, and in the `livecheck` block of
  [Casks/openray.rb](Casks/openray.rb). The release job fails before
  notarising if the two differ. If the feed leaves GitHub, the sentence
  "OpenRay downloads its list of releases from GitHub" (`whatACheckSends` in
  `OpenRay/Settings/UpdatesSettingsView.swift`) and the Updates section of
  [PRIVACY.md](PRIVACY.md) have to change with it.
- [ ] **Bundle identifier** (item 22). Default:
  `io.github.gabrieldeml.openray`. Change it in `OPENRAY_BUNDLE_IDENTIFIER` in
  `Config/Shared.xcconfig` and in the three `zap` paths of the cask. The
  release job compares the first of them with the app. `CONTRIBUTING.md`,
  `PRIVACY.md` and the design name the identifier in examples.
- [ ] **Intel** (item 23). Default: a universal build, `arm64` and `x86_64`,
  because macOS 26 still runs on Intel Macs. To ship Apple silicon only, add
  `ARCHS = arm64` to [Config/Release.xcconfig](Config/Release.xcconfig) and
  `depends_on arch: :arm64` to the cask.
- [ ] **Installing updates without asking** (item 24). Default: off. A user
  can turn it on in Settings › Updates. The default is `SUAutomaticallyUpdate`
  in [Config/Info.plist](Config/Info.plist).
- [ ] **The tap's name.** Default: `GabrielDeml/homebrew-openray`, which makes
  the install command `brew install gabrieldeml/openray/openray`. It is
  `TAP_REPOSITORY` in `release.yml` and is repeated in the comment at the top
  of the cask, in `README.md` and in `CHANGELOG.md`.
- [ ] **The links that name the GitHub account.** `AboutLinks.repository` in
  `OpenRay/Settings/AboutSettingsView.swift` and `url` and `homepage` in the
  cask all say `https://github.com/GabrielDeml/openray`. They are right as
  long as the repository stays where it is. The release job checks the cask's
  `url` against the repository it runs in.
- [ ] **What the first release carries.** `CHANGELOG.md` has window
  management, Lock Screen, snippets, file search and script commands under
  Unreleased, beside everything of v0.1. The roadmap has each feature of
  milestone 7 ship as a release of its own, and script commands are a
  milestone of their own: move the five entries to the versions they ship
  in, or leave them where they are if v0.1 is to have them. The status
  paragraph of `README.md` names all five as well, and `README.md` has a
  section on writing a script command.
- [ ] **The snippet table** (item 33). The first release that has snippets
  fixes it, because an installed copy runs the migration `m7_snippets` once
  and never again. Default: an integer key, `row_id`, that the search index
  hangs on, and the snippet's UUID in a `UNIQUE` column beside it (design
  §4.3.2 has the reasons). The index and its tokenizer can be rebuilt by a
  later migration. The table's columns cannot change, because a database
  that fails to migrate is still read for its snippets. To change any of it,
  edit the migration in
  `Packages/OpenRayCore/Sources/OpenRayCore/Storage/AppDatabase.swift` before
  that release. The same release fixes the IDs that picks and aliases are
  stored under (`snippet:<uuid>`, `file:<path>`,
  `command:files.openWith.<app path>`) and the shape of the `files.scope`
  preference (design §4.2.1, §4.3.4).
- [ ] **Script commands: what their first release fixes** (item 34). People
  will write scripts for it, and those have to keep working. Fixed from then
  on: the header (`@openray.schemaVersion 1`; the keys `title`, `mode` with
  `silent` and `fullOutput`, `icon`, `description`, `keywords`, `argument1`
  to `argument3` with `placeholder` and `optional`, `timeout` and
  `needsConfirmation`; the four comment prefixes; the first 8 KiB), what a
  script is handed (its arguments as argv, the folder of its file as working
  directory, `OPENRAY`, `OPENRAY_VERSION` and `OPENRAY_SCRIPT_PATH`), and
  the place of the default folder. A later version can still add keys, which
  this one skips, and a `schemaVersion 2`, which this one refuses with a
  line in Script Diagnostics. The same release fixes the IDs that picks and
  aliases are stored under (`script:<absolute path>`,
  `command:scripts.openFolder` and the four beside it) and the
  `scripts.folders` preference, a list of the added folders as absolute
  paths (design §4.10, §4.3.4). To change any of it, do so before that
  release, in `Packages/OpenRayCore/Sources/OpenRayCore/Scripts`.
- [ ] **Lock Screen: keep it or take it out** (item 8). It ships only if the
  check in section 4 shows that it locks the screen. If it does not, remove
  the command (`lockScreen` in `SystemCommandSource`, `SystemControl` and
  `MacSystemControl`, with its tests and its catalog entries) and its name
  from the Permissions step of onboarding, `README.md`, `PRIVACY.md`,
  `ROADMAP.md`, `CHANGELOG.md` and design §4.2.10.

## 2. One-time setup

In this order. Later steps need what earlier ones make.

### Get CI green

`.github/workflows/ci.yml` has passed for milestones 1 to 8, clipboard
history apart, and all of that is on `main`. The runner had Xcode 26.6
with Swift 6.3.3, older than what everything was written with.
Two runs before that stopped in "Test core package", both on the same test:
first on a `Task` whose result type the runner's compiler could not infer,
then on a local constant named like the helper that the closure above it
calls. The newer compiler accepts both.

- [x] A green run with everything up to the window commands. It settled the
  four things that were most likely to fail there and nowhere else:
  `SparkleUpdater.swift` conforming to `SPUStandardUserDriverDelegate` with
  `@preconcurrency` (design §6.4); "Run core benchmarks" in release mode with
  `-Xswiftc -enable-testing`; "Build app (Release)" with Xcode 26 merging the
  partial `Config/Info.plist`; and `AXWindowController.swift` with the typed
  throws of `Windows/`.
- [x] A green run with snippets and file search. The runner's compiler took
  `Files/SpotlightSearcher.swift` as it is: an actor on a dispatch queue of
  its own that calls `MDQuery` and uses the `kMDItem…` and `kMDQueryScope…`
  constants of CoreServices.
- [x] A green run with script commands, the first whose tests start
  processes. "Test core package" took three minutes there, the build
  included, and no test ran into its time limit. The runner's SDK has
  `posix_spawn_file_actions_addchdir` and `SF_DATALESS`, which
  `PosixScriptRunner.swift` and `ScriptSecurity.swift` use.
- [ ] `shellcheck Scripts/*.sh` and `actionlint` once. Neither was installed
  where the scripts and the workflows were written; they were only parsed
  (`bash -n`, and as YAML).

### Apple

- [ ] Join the Apple Developer Program. It is paid, and notarisation needs it
  (design §8, item 27).
- [ ] Create a **Developer ID Application** certificate: Xcode › Settings ›
  Accounts › Manage Certificates › + › Developer ID Application, as the
  Account Holder.
- [ ] Export it from Keychain Access (My Certificates, the certificate
  together with its private key) as a `.p12` with a password of its own. The
  release job reads the team ID off this certificate, so there is no secret
  for the team.
- [ ] Create an App Store Connect API key for notarising: App Store Connect ›
  Users and Access › Integrations › App Store Connect API. A **Team key** with
  the Developer role is what the job expects. Note its Key ID and the Issuer
  ID at the top of that page, and download the `.p8` file, which Apple offers
  once. An **Individual key** works too: it has no issuer, so leave the secret
  `NOTARY_ISSUER_ID` out and the job leaves `--issuer` out.

### The update key

Sparkle signs every update with an EdDSA key. The public half is built into
the app, the private half signs the appcast entries in the release job.

`SPARKLE_PUBLIC_ED_KEY` in `Config/Shared.xcconfig` is empty. While it is
empty, no build starts the updater, a Release build says in Settings › Updates
that it was made without the key, and the release job stops at "Check what the
release needs" before anything is signed. Nobody but you can fill it in:
`generate_keys` writes the private key into your login keychain.

- [ ] Get Sparkle's tools from the release the app links, 2.10.1, and check
  the tarball before running anything from it. The hash is the one in
  `release.yml`:

  ```bash
  curl -LO https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
  echo "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  Sparkle-2.10.1.tar.xz" | shasum -a 256 -c -
  mkdir sparkle-tools && tar -xf Sparkle-2.10.1.tar.xz -C sparkle-tools
  ```

- [ ] Run `sparkle-tools/bin/generate_keys`. It makes the key pair, keeps the
  private key in your login keychain and prints the public key.
- [ ] Put the public key after `SPARKLE_PUBLIC_ED_KEY =` in
  `Config/Shared.xcconfig`, without quotes, and commit it. The key is Base64
  and `//` starts a comment in an xcconfig file: if the key contains `//`,
  write that as `/$()/`, as in the feed URL above it. From this commit on, a
  Release build that anyone makes from a clone starts the updater.
  `CONTRIBUTING.md` has the line for `Config/Local.xcconfig` that keeps such
  a build from updating itself; a Debug build never does.
- [ ] Check that the app got the whole key. Build Release and compare:

  ```bash
  xcodebuild -project OpenRay.xcodeproj -scheme OpenRay -configuration Release \
    -derivedDataPath /tmp/openray-key-check build CODE_SIGNING_ALLOWED=NO
  plutil -extract SUPublicEDKey raw -o - \
    /tmp/openray-key-check/Build/Products/Release/OpenRay.app/Contents/Info.plist
  sparkle-tools/bin/generate_keys -p
  ```

  The two lines must be the same.
- [ ] Export the private key once, for the secret below, and keep a copy
  somewhere safe, such as a password manager. Whoever has it can sign an
  update that every installed copy accepts, and without it no update can be
  signed at all (design §6.4, key rotation).

  ```bash
  sparkle-tools/bin/generate_keys -x sparkle-private-key.txt
  ```

  Delete the file when the secret and the backup exist.

### GitHub

- [ ] Make `GabrielDeml/openray` public, if it is not yet. On a free plan a
  private repository gets neither required reviewers for an environment nor
  Pages, and the cask downloads the zip without a login, so
  `brew install` would get a 404 from a private one.
- [ ] Create the environment **`release`**: Settings › Environments › New
  environment. Add yourself under Required reviewers and leave "Prevent
  self-review" off, or nobody can approve. Do this before the first tag: a
  workflow that names an environment which does not exist creates it without
  any protection.
- [ ] Add the secrets to that environment (Environment secrets, not
  repository secrets, so that only an approved release job can read them).
  The names are exactly these:

  | Secret | What goes into it |
  |---|---|
  | `DEVELOPER_ID_P12_BASE64` | The `.p12`, in Base64: `base64 -i DeveloperID.p12 \| pbcopy` |
  | `DEVELOPER_ID_P12_PASSWORD` | The password you gave the `.p12` |
  | `NOTARY_KEY_P8_BASE64` | The API key file, in Base64: `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy` |
  | `NOTARY_KEY_ID` | The Key ID of that API key |
  | `NOTARY_ISSUER_ID` | The Issuer ID of a Team key. Leave this secret out for an Individual key |
  | `SPARKLE_ED_PRIVATE_KEY` | The contents of `sparkle-private-key.txt`: `pbcopy < sparkle-private-key.txt` |
  | `HOMEBREW_TAP_TOKEN` | The token for the tap, below |

  `gh secret set <name> --env release` reads a value from standard input, if
  you would rather keep the values off the clipboard.
- [ ] Leave immutable releases off for the repository. A release job that is
  run a second time replaces the zip of the release it made the first time.
- [ ] Create the `gh-pages` branch, with nothing on it but a `.nojekyll`
  file, which tells Pages to serve the files as they are:

  ```bash
  git worktree add --detach ../openray-pages
  cd ../openray-pages
  git switch --orphan gh-pages
  touch .nojekyll
  git add .nojekyll
  git commit -m "Start gh-pages"
  git push origin gh-pages
  cd -
  git worktree remove ../openray-pages
  git branch -D gh-pages
  ```

- [ ] Settings › Pages: deploy from a branch, `gh-pages`, folder `/ (root)`.
  The feed URL answers 404 until the first release has published the appcast,
  which is fine: no installed copy asks before then.
- [ ] If `gh-pages` gets a branch protection rule, it has to let the release
  job push to it.

### Homebrew

- [ ] Create the public repository `GabrielDeml/homebrew-openray` with a
  README, so that it has a first commit and a default branch. The release job
  makes the `Casks` folder and puts the cask in it.
- [ ] Create a fine-grained personal access token: your account's Settings ›
  Developer settings › Personal access tokens › Fine-grained tokens.
  Repository access: only
  `homebrew-openray`. Permissions: Contents, read and write. Nothing else.
  It goes into the secret `HOMEBREW_TAP_TOKEN`.
- [ ] Note when the token expires. With an expired token the last step of a
  release fails after the release itself is out. Make a new token, replace
  the secret, and update the tap by hand for that release ("When a step
  fails", below).

## 3. Each release

- [ ] In [CHANGELOG.md](CHANGELOG.md), rename `## [Unreleased]` to
  `## [X.Y.Z] - YYYY-MM-DD` and put a new, empty `## [Unreleased]` above it.
  The section is the text of the GitHub release and what OpenRay shows when
  it offers the update, so read it once more as a user would.
- [ ] Commit, and push `main`. Wait for CI.
- [ ] Tag that commit and push the tag. A release tag is `v` and three
  numbers, such as `v0.1.0`, and its commit has to be on `main`:

  ```bash
  git tag vX.Y.Z
  git push origin vX.Y.Z
  ```

- [ ] Approve the run: Actions › Release › Review deployments. Nothing runs
  and no secret is read before that.
- [ ] Watch it finish. It takes the version from the tag and the build number
  from the number of commits, so no file changes for a release except the
  changelog.

### When a step fails

The job checks the cheap things first, so most mistakes stop it before
anything is signed.

| Step | What to look at |
|---|---|
| Check that the tag is on main | The commit of the tag is not on `main` |
| Read the version and set the paths | The tag is not `vX.Y.Z` |
| Extract the release notes | The changelog heading was not renamed, its section is empty, or a code block in it is never closed |
| Check what the release needs | A secret named in the log is missing from the `release` environment, `SPARKLE_PUBLIC_ED_KEY` is empty, there is no `gh-pages` branch, the tap does not exist or is not public, or `SPARKLE_VERSION` in `release.yml` is not the Sparkle in the project's `Package.resolved` |
| Fetch Sparkle's tools | The tarball does not have the pinned hash. Find out why before changing the hash |
| Import the Developer ID certificate | The `.p12` does not hold the certificate with its private key, or the password is wrong. If both are right, see the first point under "The first release" |
| Archive, Export | The log of `xcodebuild`. `Config/ExportOptions.plist` has not been tried with a real identity |
| Check the exported app | The cask disagrees with the app about the feed, the bundle identifier or the download address |
| Notarise | The artefact `notary-log` of the run says what Apple objected to, file by file |
| Generate the appcast | "not signed" means `SPARKLE_ED_PRIVATE_KEY` is not the private half of the key in the app |
| Publish the appcast | The push to `gh-pages` was refused, Pages is not set to `gh-pages`, or Pages did not build after the push. The step waits 15 minutes; see below |
| Update the Homebrew tap | The token has expired or cannot write to the tap |

What to do next depends on how far the run got.

**Up to and including "Publish the GitHub release", or with a push to
`gh-pages` that was refused.** If the reason is outside the repository (a
secret, a setting, Apple's service), start the run again from its page with
"Re-run failed jobs". It builds, signs and notarises again, replaces the zip
of the release if there is one, and the appcast and the cask then name the
new zip. No installed copy has been offered the release yet, so nothing is
lost.

**"Publish the appcast" timed out, and `gh-pages` has the new appcast.** Pages
did not build. If Settings › Pages is not set to the branch, setting it
builds the site. Otherwise ask for a build:

```bash
gh api -X POST repos/GabrielDeml/openray/pages/builds
```

If the step is still waiting, it passes once the feed serves the appcast.
If it has failed already, check the feed URL in a browser and then update
the tap by hand, as below. Do not run the job again for this: every run makes
a new zip and pushes a new appcast, which would need a build by hand again,
and until that build is served, installed copies get the new zip with the
signature of the old one and refuse the update.

**Only "Update the Homebrew tap" failed.** The release and its appcast are
out and right. Update the tap by hand with the zip that is published, from a
checkout of the tag:

```bash
gh release download vX.Y.Z --repo GabrielDeml/openray --pattern 'OpenRay-X.Y.Z.zip'
git clone https://github.com/GabrielDeml/homebrew-openray.git
mkdir -p homebrew-openray/Casks
cp Casks/openray.rb homebrew-openray/Casks/openray.rb
Scripts/update-cask.sh X.Y.Z \
  "$(shasum -a 256 OpenRay-X.Y.Z.zip | cut -d ' ' -f 1)" \
  homebrew-openray/Casks/openray.rb
git -C homebrew-openray add Casks/openray.rb
git -C homebrew-openray commit -m "openray X.Y.Z"
git -C homebrew-openray push
```

Do not run the job again for this either. It would replace a zip that people
have already installed with a different one of the same version, to redo a
step that only needs the hash of the zip that is there.

**A file in the repository is wrong.** That needs a new commit, and the tag
points at the old one. If the release was not published yet, delete the tag
(`git push origin :refs/tags/vX.Y.Z`, `git tag -d vX.Y.Z`), fix `main` and tag
again. If it was published, leave the tag alone and release the fix as the
next patch version.

### Check the release

- [ ] Download the zip from the Releases page with a browser, so that it is
  quarantined, unzip it and open the app. macOS should ask once whether to
  open an app downloaded from the internet, and not refuse it.
- [ ] `spctl -a -vv -t exec OpenRay.app` says "accepted" and "Notarized
  Developer ID", and `xcrun stapler validate OpenRay.app` passes.
- [ ] Settings › About shows the version of the tag and a build number.
  Settings › Updates has working switches and no note about a missing key.
- [ ] `brew install gabrieldeml/openray/openray` on a Mac, or in a user
  account, that does not have OpenRay yet. Then
  `brew audit --cask gabrieldeml/openray/openray` and
  `brew livecheck gabrieldeml/openray/openray`, which should print the version
  just released.
- [ ] The feed URL in a browser shows the appcast with the new entry.

### The first release

No step of `release.yml` has ever run. Besides the table above, watch for
what could not be checked without an account (design §6.3, "Not run"):

- [ ] Whether the runner has Apple's Developer ID intermediate certificate.
  Without it `security find-identity -v` does not call the imported identity
  valid, and "Import the Developer ID certificate" fails although the `.p12`
  is right. One fix is to export the `.p12` again with the "Developer ID
  Certification Authority" certificate selected along with your own.
- [ ] Whether the export accepts `Config/ExportOptions.plist` as it is.
- [ ] What `notarytool` prints for a zip it turns down.
  `Scripts/notarize.sh` expects one JSON object with `id` and `status`.
- [ ] Whether the Sparkle tarball has `bin/generate_appcast` where the job
  looks for it.
- [ ] Whether the push to `gh-pages`, made with the job's own token, starts a
  Pages build. Watch "Publish the appcast": if the feed has not changed a few
  minutes after the appcast commit landed on `gh-pages`, ask for a build
  while the step is still waiting (`gh api -X POST
  repos/GabrielDeml/openray/pages/builds`, under "When a step fails"). If
  that is what it takes, the step should make the same call itself after its
  push, which needs `pages: write` among the job's permissions.
- [ ] How long Apple takes. The first submissions of a new team are often
  held for longer, the job ends after 60 minutes (`timeout-minutes`), and
  `Scripts/notarize.sh` waits without a limit of its own. If "Notarise" is
  still waiting when the job is cancelled, look at the submission from your
  Mac with the same key, `xcrun notarytool history --key AuthKey_XXXXXXXXXX.p8
  --key-id <Key ID> --issuer <Issuer ID>`, and run the job again once Apple
  has answered it. The new run submits a new zip.
- [ ] On a second run of a job, whether `gh release view` finds the release
  the first run made.

### The first update

One release cannot show that updating works. After `v0.1.0`:

- [ ] Install 0.1.0 and leave it installed. Release `v0.1.1` (any change, or
  only a changelog section).
- [ ] In the installed 0.1.0, choose "Check for Updates…". Sparkle should
  offer 0.1.1 with the notes from the changelog, install it and start it
  again. Settings › About then shows 0.1.1.
- [ ] `brew upgrade` leaves the installed copy alone: `auto_updates true` in
  the cask tells Homebrew that the app updates itself.

## 4. Manual checks

By hand on macOS 26 and on macOS 27, for each release. None of this can be
tested in CI, and most of it has never been run at all: every milestone so far
was built without launching the app, sending an Apple event, raising a
permission prompt or calling the Claude API. The numbers in brackets are the
open questions of section 8 of the design; settle each there once it has an
answer.

### New in milestone 8

Script commands (design §4.10) were built without launching OpenRay, without
starting a login shell and without running any script but the ones the tests
wrote for themselves. So none of this has been seen. The number in brackets
is item 18 where the check answers part of it.

Write the scripts for these checks yourself, in the Scripts folder, and keep
them to things that do no harm: `echo`, `sleep`, `date`. Each needs the
three lines `# @openray.schemaVersion 1`, `# @openray.title …` and
`# @openray.mode silent` or `fullOutput` under its `#!` line.

- [ ] The Scripts folder. After the first launch
  `~/Library/Application Support/<bundle id>/Scripts` exists with mode 700
  (`ls -ld`). "Open Scripts Folder" opens it in Finder. Delete the folder
  while OpenRay runs and use the command again: the folder is made again,
  and a script saved into it then shows up.
- [ ] A script appears, changes and goes without a restart. Save an
  executable script into the folder: it is in search under its title within
  about a second. Change the title in an editor and save: the row follows.
  Delete the file: the row goes. A script in a subfolder shows the
  subfolder's name at the end of its row, and one two folders down is not
  listed. Put the Mac to sleep and wake it: a script saved right afterwards
  still shows up.
- [ ] What is no script. A file without `@openray.` lines in the folder is
  neither in search nor in Script Diagnostics. A script is found by its
  title and by each of its keywords, and Settings › Commands lists it, where
  it can be given an alias or switched off.
- [ ] Icons of all three kinds, in a row and on the argument screen: an
  emoji, `sf:wifi`, and `icon.png` for a picture beside the script. A
  picture that is missing, and `../icon.png`, give the terminal symbol.
- [ ] A silent script. One that prints two lines: the launcher closes and
  the HUD shows the second. One that prints nothing: the HUD shows its
  title. One that ends with `exit 3`: "Script failed", and "Show Last Script
  Output" then shows what it printed and "Exit code 3". For the first script
  after OpenRay started, how long is the wait while the shell is asked?
- [ ] A silent script that sleeps ten seconds. Open the launcher again
  meanwhile and use it: the HUD still comes when the script is done. "Show
  Last Script Output" while it runs says "Running…", and Esc there stops it.
- [ ] A fullOutput script that prints a line every second. The lines arrive
  as they are printed and the view stays at the bottom; ↑ and ↓ scroll;
  the status line says "Running…" and then "Finished". Text in colour
  (`printf '\033[31mred\033[0m\n'`) arrives without the codes, and a
  progress line written with `\r` stays one line. A script that writes to
  stdout and stderr in turn shows both in the order written.
- [ ] The keys of the output screen, where the search field is hidden. ⌘⇧C
  copies the output and the launcher stays while the script runs; ⌘. stops
  the script and does not close the launcher, although AppKit knows that
  chord as Cancel; ⌘R runs it again once it is over; ⌘O opens the file in
  an editor; ⌘K lists all of them, and Return copies. ⌘O works on a script's
  row in search as well.
- [ ] A held key acts once. A fullOutput script with
  `date >> runs.txt; wc -l < runs.txt`, which counts its own runs in a file
  beside itself: hold ⌘R for two seconds once it is over. The count goes up
  by one, not by ten, and nothing beeps. The same on a row in search: ⌘O
  held opens the file once.
- [ ] Stopping by leaving. Esc while the script runs stops it ("Script
  stopped") and only the next Esc leaves. Delete and ⌘[ do the same: the
  first stops the script and leaves the screen where it is, the second
  goes back. Start it again, hide the launcher with the hotkey and show it
  again: the root is back, `pgrep` no longer finds the script, and "Show
  Last Script Output" has what it printed until then.
- [ ] Behind a hidden launcher. A fullOutput script that sleeps a minute
  and prints a line at its end. Start it and click into another app, so
  that the launcher hides, and do not open the launcher: `pgrep` still
  finds the script, as design §4.10 says it should. Wait for it to end and
  open "Show Last Script Output": the whole output and "Finished". Then the
  same with a script that runs `open -a TextEdit` and goes on printing: it
  must not be stopped when TextEdit comes to the front. Is a script that
  the next press of the hotkey stops, without a word, what you want? If
  not, that is the "runs on without its screen" of the design's future
  work.
- [ ] A script that prints without end: `yes` as a fullOutput script. The
  launcher stays responsive, ⌘. stops it at once, and OpenRay's memory in
  Activity Monitor stays flat instead of growing with the output. Almost
  at once the top of the output says "Earlier output was dropped. Only the
  newest is kept.": a line counts 64 bytes besides its text, so for `yes`
  the 4 MB are full after some 65,000 lines, about 130 KB of output. Let
  it run for a minute to be sure it stays so. Can the output still be
  scrolled while it floods? The buffer keeps at most
  some 65,000 lines; does a list of that many rows still scroll once the
  script is stopped?
- [ ] One very long line: a fullOutput script with
  `base64 -i /usr/share/dict/words`, which prints megabytes without a line
  end, and one that prints minified JSON. The launcher must stay
  responsive while it arrives and ⌘. must get through; the output shows as
  blocks of about 4 KiB, each beginning on a new row. ⌘⇧C and a paste into
  an editor give one line, with no line ends that the script did not
  print.
- [ ] Pictures for a terminal: a script that prints
  `printf '\033Pq#0;2;0;0;0#0~~\033\\after\n'` shows "after" and nothing of
  the sixel data before it.
- [ ] Arguments. A script with three, the second optional, that prints each
  on a line of its own. The placeholder changes with every step, and the
  values entered so far are listed. Return on an empty required one says
  "… is required", and the notice goes with the next key. The optional one
  has its hint, and left out it reaches the script as an empty argument in
  its place. Spaces, quotes, `$HOME` and `*` arrive exactly as typed. Esc
  leaves the whole screen. After a fullOutput run, Esc from the output
  leads back to an empty form. With `needsConfirmation true` the question
  comes after the last argument.
- [ ] `needsConfirmation true` on a script without arguments: "Run “…”?"
  before every run, and again for Run Again. The question is drawn with
  the button of a destructive confirmation; does "Run" in that colour read
  right (design §4.1.6)?
- [ ] A timeout. `# @openray.timeout 5` on a script that starts
  `sleep 600 &` and then waits: after five seconds it says "Script timed
  out", and `pgrep -f "sleep 600"` finds nothing, because the whole process
  group was ended. A silent script without the line that sleeps a minute is
  stopped after 30 seconds. A script with `trap '' TERM` is gone about two
  seconds after Stop.
- [ ] The documented way out. A script that starts a child in a session of
  its own, such as
  `perl -MPOSIX -e 'setsid(); exec "sleep", "600"' &`, and waits: after
  Stop the script is gone and that `sleep` still runs. That is the limit
  design §4.10 names; end it with `kill`.
- [ ] Quitting OpenRay while a silent and a fullOutput script run. Are both
  still running afterwards (`pgrep`)? Does one that prints after OpenRay
  has gone end by itself? Write what happens into design §4.10.
- [ ] Open in Editor opens an editor and runs nothing, for a script named
  `x.sh`, for one without an extension and for one named `x.command`: no
  Terminal window, and a line the script would print appears nowhere. Which
  app opens, and is it the one you expect? macOS's default for plain text
  is TextEdit.
- [ ] Make Executable. A script with a `#!` line and mode 644 is in search
  and Return offers "Make Executable": the HUD says "“…” can be run now",
  the launcher stays, and the next Return runs it. The same file without
  its `#!` line is in Script Diagnostics instead.
- [ ] Files OpenRay refuses. After `chmod o+w` on a script, and on a
  subfolder with scripts in it, they leave search and are in Script
  Diagnostics with a sentence that names `chmod o-w`. If you care to, do
  the same with a file given to root (`sudo chown root`): "belongs to
  another user".
- [ ] A downloaded script [18]. Download a script with a browser, move it
  into the Scripts folder and make it executable; `xattr -l` shows
  `com.apple.quarantine`. Return asks "Run “…”?" and says that the file was
  downloaded. Cancel: nothing runs and the attribute is still there. Run:
  the script runs, the attribute is gone, and the next run asks nothing.
  Then the question behind it: would macOS have stopped the script without
  that? Put the attribute back
  (`xattr -w com.apple.quarantine "0083;00000000;Safari;" <file>`), run the
  file from Terminal, and note what macOS does, in design §4.10.
- [ ] Script Diagnostics: each row has the file's name, the sentence of its
  problem and "File" or "Folder" at its end; typing filters by the name and
  by words of the sentence; Return opens a file in the editor and shows a
  folder in Finder; with nothing wrong the list says "No problems in your
  script folders." A script with `# @openray.mode loud` and one with
  `schemaVersion 2` are good ones to try. Beside the list the selected row
  is shown with its name, its path and the whole sentence: for a script
  after `chmod o+w` the row cuts the sentence off, and the part that names
  `chmod o-w` has to be readable there. Does the list still have room for
  the names with that view beside it?
- [ ] A link to a script elsewhere. Make a folder with mode 777 outside the
  script folders, put a script into it and a symbolic link to that script
  into the Scripts folder. The link is in search, and Return refuses it
  with the sentence about the folder everybody can change. After
  `chmod 755` on that folder it runs. Is the HUD up long enough to read
  that sentence (two lines, about a second and a half)?
- [ ] A file saved by a Windows editor: UTF-8 with a byte order mark and
  CR LF line ends, the `@openray.` lines first and no `#!` line. Script
  Diagnostics says that it is not executable and has no `#!` line, and
  not that its `schemaVersion` is missing.
- [ ] "Add Script Folder…" from the launcher. The launcher closes, Settings
  comes forward on Scripts, and the folder panel opens by itself, with
  "Add" on its button. Choose a folder with a script in it: its row appears
  in the pane and the script in search, without a restart. Close Settings:
  the keyboard is back in the app you came from. Try it with Settings
  closed before, open on another pane, and open on Scripts already. Cancel
  the panel: nothing is added, and the command works again afterwards.
  Remove the folder: its scripts go.
- [ ] A script folder in Documents, on a fresh account or after
  `tccutil reset SystemPolicyDocumentsFolder <bundle id>`. The row has the
  warning. When does macOS ask: when the folder is added, at the next
  launch, both? Is the text the one from `Config/Shared.xcconfig`? While
  the prompt is up, can the launcher be opened and used, with the five
  script commands in it? After "Don't Allow", Script Diagnostics should say
  "OpenRay cannot read this folder." and the scripts of the other folders
  should still be there; and at the next launch? Then Desktop, Downloads
  and a folder in iCloud Drive: does macOS ask about that one at all?
  Write the answers into design §5.1.
- [ ] Files iCloud has moved off the Mac. Add a folder in iCloud Drive
  that holds some large files, and remove their downloads in Finder
  ("Remove Download", a cloud beside the name). Quit and start OpenRay:
  none of them is downloaded again, the scripts of the other folders are
  in search at once, and a script among the removed files is missing from
  search until it is downloaded, after which it shows up without a
  restart. Nothing could try this while it was built: a test cannot make
  such a file.
- [ ] launchd's environment [18]. Start a build from Finder and read
  `ps eww -p $(pgrep -x OpenRay)`: what is `PATH`, and is `SHELL` there?
  That line holds your whole environment, so read it and do not paste it
  anywhere. Write the two answers into design §4.10.
- [ ] The capture under each shell [18]. With zsh, bash and fish in turn as
  your login shell (`chsh -s`, or an account for each): a silent script
  with `echo "$PATH"` shows the Homebrew folder, and one that echoes a
  variable you export only in `.zshrc`, `.bashrc` or `config.fish` shows
  it. Settings › Scripts says "Scripts run with the environment of zsh: …
  variables." and names no variable. Before the first script it says "Not
  read yet…", and opening the pane does not start the shell.
- [ ] Startup files that misbehave [18]. With `echo hello` in the rc file
  the capture still works. With `read answer` in it, which waits for input
  that never comes, the first script waits some seconds under "Reading
  your shell environment…" and then runs all the same; the pane says "zsh
  did not report its environment…", and a script still finds a Homebrew
  tool through the fallback. Afterwards `pgrep -fl -- "-l -i"` should find
  no shell left over; if it does, that is the way out of the process group
  that design §4.10 expects of an interactive shell.
- [ ] "Reload Shell Environment" after adding an `export` to the rc file:
  the HUD has the sentence of the pane, and the next script sees the
  variable. The pane's Reload button does the same.
- [ ] What OpenRay adds: a script that prints `$OPENRAY`,
  `$OPENRAY_VERSION`, `$OPENRAY_SCRIPT_PATH`, `$NO_COLOR`, `$TERM` and
  `$LANG` shows 1, the version, its own path, 1, `dumb`, and your locale
  or `en_US.UTF-8`. `pwd` in a script prints the folder the script is in.
- [ ] The one test that asks your real shell [18]:
  `OPENRAY_SHELL_ENV_TESTS=1 swift test --package-path Packages/OpenRayCore --filter RealShellEnvironmentTests`.
  It starts your login shell with your startup files and prints where the
  environment came from, the shell's name and the number of variables,
  never a value. It should pass under each of the three shells. Does the
  terminal you ran it from behave normally afterwards?
- [ ] Automation from a script [18]: a script with
  `osascript -e 'tell application "Finder" to get name of startup disk'`.
  Which app does the prompt name, and is its text the one of
  `NSAppleEventsUsageDescription`? After "Don't Allow", what does the
  script print? On a signed, hardened build: does the event go out at all,
  and does it depend on OpenRay's Apple-events entitlement (design §5.1)?
- [ ] Files & Folders from a script [18]: a script with `ls ~/Documents`,
  on an account where OpenRay was never asked about that folder. Which app
  does the prompt name, and with which text? After a refusal the script
  should print "Operation not permitted".
- [ ] A hardened Release build, signed with your team (design §6.6), runs a
  script whose first line is `#!/opt/homebrew/bin/python3`, or any other
  interpreter from Homebrew, and one with `#!/usr/bin/env python3`.
- [ ] Settings › Scripts: how the pane looks. The default folder's row has
  no Remove button; a folder that was deleted says "This folder does not
  exist."; the text under each section fits.
- [ ] How the argument screen and the output screen look, and the status
  line under a start error, such as a script whose `#!` line names a
  program that does not exist.
- [ ] VoiceOver on the output screen: can the lines be read, and the
  status line? The HUD of a silent script is announced. Should new output
  or the end of a run be announced too (design §5.5)?

### New in milestone 7

Three blocks: window management with Lock Screen, then snippets, then file
search. For the window commands and Lock Screen OpenRay needs the
Accessibility permission, and the window commands act on the front window of
the app the launcher was opened over.

- [ ] First use without the permission [15]. From a state where
  Accessibility is not granted, run Left Half and then Lock Screen: each
  should show the permission screen and do nothing else. Grant it from the
  screen's button and run the command again without relaunching OpenRay.
- [ ] The permission taken away while OpenRay runs [15]. Switch
  Accessibility off in System Settings and run a window command: either the
  permission screen appears, or the HUD says "Accessibility is no longer
  allowed. Grant it in Settings › General." Note which, and whether macOS
  answers the first call with `kAXErrorAPIDisabled` as design §5.1 expects.
- [ ] Every window command on a Safari window, on one display [16]: the
  four halves, the four quarters, the three thirds, the two two-thirds,
  Maximize Window, Almost Maximize Window, Center Window and Restore Window.
  Two halves side by side, and three thirds, should meet without a hole or
  an overlap. A command repeated on a window that is in place does nothing.
- [ ] A window command with the launcher opened over Settings [16]. The
  command acts on the app that was in front before OpenRay, so a window
  behind the Settings window moves. Is that what one expects, or should it
  say "No window to move"?
- [ ] Windows that do not take the size they are given [16]. Terminal grows
  by whole characters: Right Half should end against the right edge and
  Bottom Half against the bottom. System Settings has a size that cannot be
  set: it should only move. A window with a minimum size larger than its
  tile, such as a narrow third for Xcode, should keep to the edge of the
  tile. Repeat each of these commands: the window should stay where it is
  and not jump to its tile's corner and back.
- [ ] Chrome and an Electron app, such as Visual Studio Code or Slack [16].
  The window should land in one step, without an animation that leaves it
  short of its tile. Afterwards the app's `AXEnhancedUserInterface` is back
  as it was: with VoiceOver on, the app still reads its content. Then stop
  the app while VoiceOver is on (`kill -STOP`), run a window command on it,
  let it go on (`kill -CONT`) and run a window command on any app: after
  that one the stopped app should read its content to VoiceOver again.
- [ ] A full-screen window [16]: the HUD says "Full-screen windows cannot be
  moved" and nothing moves. This rests on the undocumented `AXFullScreen`
  attribute; if a full-screen window is moved or resized instead, the
  attribute is not there.
- [ ] No window and a slow app [16]. Over the Finder with every window
  closed: "No window to move". Over an app that is stopped (`kill -STOP`
  with its process ID, `kill -CONT` afterwards): "App not responding" after
  about a second, and the launcher does not hang. If an app can be caught
  so that it stops halfway through a move, repeat the command once it
  answers again and then use Restore Window: it should lead back to where
  the window was before the first try.
- [ ] Two displays of different sizes [16]. Move Window to Next Display and
  to Previous Display: a window that fills a tile fills the same tile on
  the other display, any other window keeps its place and its share of the
  screen, and after the last display comes the first. Try a display left of
  and one above the primary. A window that hangs over the edge of its
  display, or lies across two, should end up wholly on the display it moves
  to. On one display the HUD says "No other display".
- [ ] Restore Window [16]. After two commands in a row it leads back to
  where the window was before the first. After dragging the window and one
  more command it leads back to where it was dragged. Without an earlier
  command the HUD says "No earlier position to restore". Tile a window on
  an external display, unplug the display and use Restore Window: the HUD
  says the same and the window stays in sight. Plug the display in again:
  Restore Window now leads back.
- [ ] Settings › Window Management: how the pane looks, a gap of 12 points
  (the same space at the edges of the screen and between two tiles), and
  that a negative number is stored as 0 [16].
- [ ] Stage Manager [16]. With it on and the inset at 0: do the tiles already
  stay clear of the strip, which would mean `visibleFrame` leaves it out
  and the setting is not needed? If not, set the room for Stage Manager and
  see that it is left on the side the strip is on. OpenRay takes that to be
  the left, and the right when the Dock is set to the left edge, which it
  reads from the `orientation` default of `com.apple.dock`: try the Dock at
  the bottom, on the left, on the left and hidden, and on the left with the
  window on a second display that does not hold the Dock. Turn Stage
  Manager off and see that the room is given back, which shows that the
  `GloballyEnabled` default says what it is taken to say.
- [ ] macOS's own tiling [16]. Tile a window with macOS (drag it to an edge,
  or Fn-Control-arrow), then use an OpenRay command on it, and the other
  way round. Does the window keep a tiled state that macOS then acts on,
  and how does "Tiled windows have margins" look next to a gap of 0?
- [ ] The commands in search: "window", "tile" and "snap" each list all
  nineteen, and the symbols fit. Center Third and the two two-thirds have
  the nearest symbol there is, not one of their own.
- [ ] Settings › General, the Accessibility row. It should read "Pasting
  into the app you came from, Lock Screen, Left Half, and 18 more" on one
  line. Whether there is a comma before the "and" depends on the region
  the Mac is set to: US English has it, British English does not.
- [ ] The Permissions step of onboarding on a fresh account: it has a third
  paragraph now, about the window commands and Lock Screen. Does it still
  fit the window?
- [ ] Lock Screen [8]. With Accessibility granted, does the command lock the
  screen, on macOS 26 and on macOS 27? Try it on a Dvorak layout as well,
  where Q is another key, and with the launcher opened over OpenRay's own
  Settings window. The command presses ⌃⌘Q whatever the Apple menu says, so
  on a Mac where that shortcut was given to something else it does that
  other thing. If it does not lock, Lock Screen goes: see
  "Lock Screen: keep it or take it out" in section 1.

Snippets are the first feature with a list screen (design §4.1.5, §4.9), so
these are also the first checks of that screen. Nothing here was ever on
screen, and no snippet was ever pasted.

- [ ] Settings › Snippets: how the pane and the editor look. Make a snippet
  with a name, a keyword and a few lines; the preview follows what is typed.
  A snippet without a name or text, and one with `{cursor}` twice, cannot be
  saved and the editor says why. A second snippet with the same keyword is
  refused with "Another snippet already has the keyword …" and the editor
  stays open on what was typed. Delete asks first.
- [ ] Root search finds a snippet by its name and by its keyword. Return
  pastes it into TextEdit, ⌘Return copies it, ⌘E opens the editor on it and
  ⌃X asks and then deletes it. "Create Snippet" opens the editor on a new
  one. Does the editor's sheet come up when Settings was closed before, and
  when it was open on another pane?
- [ ] An open editor keeps what was typed. Type into the editor, then run
  "Add Alias…" on some item from the launcher, which shows another pane,
  and go back to Snippets: the sheet is there again with the text. Type
  into the editor and run "Create Snippet" or "Edit Snippet…" on another
  snippet from the launcher: Settings comes up with the editor as it was.
  Does typing in the editor feel as quick as in any text field?
- [ ] Search Snippets, the first list screen [28]: the rows, and the detail
  pane beside them with the name, the keyword and the text of the selected
  snippet. Arrows, Return, ⌘1 to ⌘9 and ⌘K work as in root search, and Esc
  leads back to it. Three letters from the middle of a word in a snippet's
  text find it, and so do one and two letters. Return pressed right after
  the last letter pastes a snippet of the new rows, never one of the old.
- [ ] A held Return acts once (design §4.1.3). With "Delay Until Repeat" in
  System Settings › Keyboard at its shortest, select "Search Snippets" in
  root search and hold Return for a second: the list opens and nothing is
  pasted. The same on the "Search Files" row under a search that finds
  nothing: the list opens and no file does. In root search a held Return
  on an app opens it once, and the search field never loses its caret.
  Then the same with ⌘1 held on the "Search Snippets" row: nothing is
  pasted, and nothing beeps while the key is down.
- [ ] What an empty list says: "No snippets yet. Add one with Create
  Snippet." while there are none, whatever is typed, and "No Results" for a
  text that finds nothing among the ones there are. Is the text centred in
  the list, and easy to read?
- [ ] The list follows the store. Delete a snippet from the list: the row
  goes and the selection stays in place. Edit one in Settings while the
  list is open: the list follows.
- [ ] ⌘K in Search Snippets with no row selected, which is the case while
  the list is empty: the action panel opens and says "No Matching Actions".
  Should it stay shut instead (design §4.1.5)?
- [ ] `{cursor}` [30]. Paste "Dear {cursor}, thanks 👨‍👩‍👧‍👦" into TextEdit,
  Terminal, a browser's text field and an Electron app: is the caret after
  "Dear " in each, or do the arrow presses come too early, or count the
  emoji as more than one step? Try a snippet of two lines with the cursor
  on the first as well.
- [ ] `{clipboard}` [6]. Copy a few words in another app and paste a snippet
  with `{clipboard}`. Does macOS show its paste alert, and where: over the
  app, now that the launcher has closed? If it does, does the snippet still
  arrive in the app, or does the HUD say "Copied — press ⌘V"? Copy an image
  and paste the same snippet: the placeholder leaves nothing. A snippet
  without the placeholder must never bring the alert up, and neither must
  the preview in Settings.
- [ ] Without the Accessibility permission, Return on a snippet copies it
  and the HUD says to press ⌘V.
- [ ] `{date}`, `{time}` and `{datetime}` on a Mac set to another region and
  to 24-hour time: do they read the way the menu-bar clock does? Change the
  time zone and the region while OpenRay runs: the next `{time}` follows
  without a relaunch. Braces that are no placeholder, such as
  `${{ secrets.TOKEN }}`, arrive as typed.

File search was built without one query of a real home folder (design §4.8),
so everything about real files is still to be seen. The number in brackets is
item 17.

- [ ] Search Files, by its name, by "Find File" and with Tab, and from the
  "Use … with" rows of a search that found nothing: the last puts what was
  typed into the field of the screen. The empty field says "Type to search
  for files by name".
- [ ] Results on your own files [17]. Do the files you mean come first? Type
  the exact start of the name of a file you have not opened for months: is
  it there, or did Spotlight's caps leave it out? Try the same with a word
  from the middle of a long-unused name, and with two words in the other
  order than the name has them. Do files in `~/Library`, in `node_modules`
  and in `.git` stay at the bottom, while a document in iCloud Drive or in
  a Dropbox or OneDrive folder ranks like one in Documents? Do files in the
  Trash show up at all? Does a `?` in the text act as a wildcard? Open one
  file from the list a few times: it should move up for that text.
- [ ] Typing fast and slowly: the list follows a moment after the typing
  stops, and Return pressed right after the last letter opens the file of
  the new results, never one of the old. A text that finds nothing says "No
  files found".
- [ ] The row actions: Return opens, ⌘Return shows the file in Finder, ⌘⇧C
  copies the path, ⌃X asks, naming the file, and then moves it to the
  Trash, and the row goes without the list jumping. Search again a moment
  later: does the trashed file come back for a while?
- [ ] Open With: the list names the apps with the default first and marked
  "Default", typing narrows it, Return opens the file with the app chosen,
  and Esc leads back to the files. A file that no app opens gets "No app
  can open this file".
- [ ] The detail pane and ⌘Y [17]: the icon, the folder, the kind and the
  date. Does the Quick Look preview draw inside the launcher, for an image,
  a PDF, a text file and a folder, does it follow the selection, and does
  ⌘Y bring the facts back? The keyboard should stay with the search field
  throughout.
- [ ] Files & Folders prompts [17], on a fresh user account: select, preview
  and trash a file in Desktop, in Documents and in Downloads. Does macOS
  ask, with the text from `Config/Shared.xcconfig`, and does the prompt come
  up over the launcher or under it? While the prompt of Move to Trash is
  up, does the launcher still react: can you type, and does Esc close it?
  After "Don't Allow", Move to Trash should fail with a message in the HUD
  and the row should stay. Try a file on a USB stick with the scope set to
  everywhere.
- [ ] Settings › File Search: how the pane looks, the three scopes, adding
  and removing a folder, and the list of folders coming back after another
  scope was chosen. With chosen folders, only files in them are found.
- [ ] Spotlight off, on a Mac or a volume you can spare: after
  `sudo mdutil -i off /` Search Files should show the notice, three lines
  with the command to turn indexing on. Do they fit the list? Switch on the
  slower search in the pane: the results come under "Found without
  Spotlight". On a fresh account, does macOS ask about Desktop, Documents
  and Downloads when the slower search first runs [17], and where? Turn
  indexing back on; the notice goes within five minutes.
- [ ] Settings › Commands › Fallback: "Search Files" has its name and a
  Remove button, and after removing it the Add menu offers it again. In
  Settings › Commands the command can be given an alias and switched off
  like any other.
- [ ] VoiceOver on the two lists: the rows are read as in root search. What
  does it make of the detail panes and of the Quick Look preview?

### New in milestone 6

- [ ] A Debug build launches. It links `Sparkle.framework` for the first
  time, ad-hoc signed like the app (design §6.6). If it stops at launch with
  a library-validation error, say so in §5.1.
- [ ] A Release build straight from a clone is expected *not* to launch: it
  is hardened, and library validation refuses the ad-hoc signed framework.
  `CONTRIBUTING.md` says how to run one locally. Confirm that this is what
  happens, and that signing with your team in `Config/Local.xcconfig` (the two
  lines of design §6.6) makes it launch and makes Accessibility grants survive
  a rebuild (`codesign -d -r-` before and after) [15]. Once the public key is
  in `Config/Shared.xcconfig`, such a build starts the updater and would
  replace itself with the published release: put `SPARKLE_PUBLIC_ED_KEY =`
  into `Config/Local.xcconfig` as well, and see that Settings › Updates then
  says the build was made without the key.
- [ ] Settings › Updates and Settings › About look right, in a Debug build
  (switches disabled, with the reason) and in a release. Both licence texts
  open and scroll. The link opens the repository.
- [ ] The onboarding step "Stay up to date". Your own copy shows it once,
  because the onboarding version went from 2 to 3. On a fresh account: the
  whole of onboarding, with the checkbox ticked and Continue, and once more
  with it cleared.
- [ ] "Check for Updates…" from the menu-bar menu, from Settings › Updates
  and from the launcher ("Check for Updates"). Where does Sparkle's window
  appear for an app without a Dock icon, and does it come to the front?
- [ ] The keyboard after Sparkle's window. With no other window of OpenRay
  open, choose "Check for Updates…" from the menu-bar menu while TextEdit is
  in front, and close "You're up to date" with OK: typing should go to
  TextEdit again (design §6.4). The same after Remind Me Later on an update.
- [ ] The gentle reminder. With an older version installed and automatic
  checks on, leave OpenRay running until a scheduled check has found the
  update (Sparkle looks once a day; `SUScheduledCheckInterval` in the app's
  defaults shortens that, see Sparkle's documentation). The menu-bar menu
  should then begin with "Update Available…" and the empty launcher should
  have an "Update Available" row. Both should open Sparkle's window, and both
  should be gone once you have looked at it. Is Return on an empty search
  field opening the update window too forward?
- [ ] Sparkle's own permission prompt. A user who closes the onboarding
  window before the Updates step has not been asked, so Sparkle asks at the
  next launch. Close onboarding early on a fresh account, quit, launch
  again, and see that the prompt appears once and that Settings › Updates
  shows the answer.
- [ ] One question at a time. On a fresh account, quit OpenRay at the first
  launch with the onboarding window still open, and launch it again:
  onboarding comes back, and Sparkle's prompt does not appear beside it
  (design §4.3.7).
- [ ] An update from end to end, as under "The first update".
- [ ] After an update, look for `~/Library/HTTPStorages/io.github.gabrieldeml.openray`
  and for files beside Sparkle's folder in
  `~/Library/Caches/io.github.gabrieldeml.openray`. If macOS made any, add
  the first path to the cask's `zap` and correct "The updater's cache" under
  "What is kept on your Mac" in `PRIVACY.md`.

### Launcher

- [ ] The panel opens over full-screen Safari, QuickTime and a Keynote
  presentation; on every Space, with "Displays have separate Spaces" on and
  off; in Stage Manager; on two displays [1].
- [ ] The panel's level [1]. It is `.screenSaver` (design §4.1.1). With the
  level and the assertion beside it changed to `.popUpMenu` in a Debug build,
  does the panel still open over a full-screen app? If so, the lower level
  is the better one.
- [ ] What the panel's level hides [1]. Does the tooltip of "Copy Code" in a
  Quick AI answer appear above the panel, and does a system prompt, such as
  the Automation alert of a system command, come up in front of the panel
  and not behind it?
- [ ] The hotkey opens and closes it. ⌥Space registers on both systems, the
  ⌃⌥Space fallback appears when it does not, and the hotkey still fires under
  Secure Event Input (a password field), during Mission Control and while
  another app's menu is open [2] (design §4.1.10).
  Decide whether ⌥Space stays the default or onboarding pushes ⌘Space [3].
- [ ] A chord that another app holds [2]. Record a chord in Settings ›
  General that another app has registered as a global shortcut, once from an
  app that registers it exclusively and once from one that does not: which
  of the two makes the recorder say the chord is in use (design §4.1.2)?
- [ ] With ⌘Space chosen in onboarding: are the labels of the Spotlight
  shortcut in System Settings the ones the step names, and what happens while
  Spotlight still holds the chord?
- [ ] Input-method candidate windows (Japanese, Pinyin) appear above the
  panel.
- [ ] The caret is back in TextEdit after the launcher is dismissed, also
  after Settings was opened from the launcher and closed [4].
- [ ] ⌘C, ⌘V and ⌘Z work in the search field and in Settings, and ⌘W closes
  the Settings window. All four go through the main menu that OpenRay
  installs by hand and never shows [4].
- [ ] Settings comes to the front from the menu-bar menu and from the
  launcher over a full-screen app.
- [ ] The latency budget of design §4.1.9 in Instruments, on the oldest
  Apple-silicon Mac at hand: hotkey to first frame, keystroke to results, and
  the list with 200 rows [5]. Xcode's Profile action builds the Release
  configuration, which does not launch from a clone as it is: sign it with
  your team in `Config/Local.xcconfig` first, or attach Instruments to the
  installed release.
- [ ] VoiceOver: the search field, the rows and their announcements, the
  action panel, Settings, the Quick AI chat.

### Permissions and system commands

- [ ] Every permission flow, from a state where nothing is granted. For
  Accessibility: does a grant take effect without a relaunch, and does "Open
  System Settings" read well the first time, when macOS shows its own alert
  as well [15]?
- [ ] System commands on the signed release build: Sleep, Empty Trash,
  Toggle Appearance, Quit All Apps, Quit and Force Quit, and Restart, Shut
  Down and Log Out. Does sending to the login window prompt, does the dark
  mode event do what it should, and does the link to Privacy & Security ›
  Automation open the right page [7]?
- [ ] Launch at login on the installed release: the switch, the system's
  notification, the state after a restart, and "Open Login Items" when macOS
  wants approval.
- [ ] Launch at login where registering may fail (design §4.3.6): in a copy
  that runs translocated, which is the downloaded zip opened from Downloads
  without moving the app, and in a Release build signed ad hoc. Does the
  switch stay off and show the error?

### Paste

- [ ] ⌘Return on a calculator result pastes into TextEdit, Terminal and a
  browser, with no pause needed after the panel closes. Try it on Dvorak and
  on "Dvorak – QWERTY ⌘" [30].
- [ ] Without the Accessibility permission the same key copies and the HUD
  says to press ⌘V.

### Quick AI, with a key of your own

- [ ] Save & Verify accepts a real key, which also shows that
  `GET /v1/models` takes `x-api-key` [14]. A wrong key is rejected and not
  stored.
- [ ] After an ad-hoc rebuild of a Debug build, does the Keychain ask before
  the key is read [14]?
- [ ] Record the fixtures with `Scripts/record-claude-fixture.sh` and compare
  them with the hand-written ones the tests use [14].
- [ ] The longest silence in a reply at high effort on the largest model:
  is the 60 second timeout right [14]?
- [ ] Haiku against Sonnet at low effort on about thirty ordinary launcher
  questions, for time to first token and quality. The default model was
  chosen without this comparison [12].
- [ ] Ask from root search, leave the chat with Paste Answer or the hotkey,
  and open the launcher again: the question is still in the field. Decide
  whether a question that was handed to the chat should leave the root empty
  [32].

### Daily use

- [ ] A date or a phone number typed into the launcher gets a calculator row
  (`2024-11-15`, `555-1234`). On 2026-11-15 the decision was to leave this as
  it is [31]; reopen it if it gets in the way.

## 5. The demo

The README has a comment where the demo goes, right under the first
sentence.

- [ ] Record about half a minute with a release build, so that nothing on
  screen says "OpenRay Dev": the hotkey, an app found in two letters, a
  calculation pasted with ⌘Return, a quicklink, ⌘K on a result, and a
  question to Quick AI with its answer streaming in.
- [ ] Nothing private in the frame: no real key, no personal windows behind
  the panel.
- [ ] Save it as `docs/demo.gif`, a few megabytes at most, and replace the
  comment in `README.md` with `![OpenRay in use](docs/demo.gif)`.

## 6. Pins, and what to copy again when one changes

Nothing in `release.yml` is a placeholder: every pin was read and is written
there with its source. Read on 2026-11-15 from the public GitHub API:

| Pin | Value | Read from |
|---|---|---|
| `actions/checkout` v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` | `api.github.com/repos/actions/checkout/commits/v7.0.1` |
| `actions/upload-artifact` v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` | `api.github.com/repos/actions/upload-artifact/commits/v7.0.2` |
| `Sparkle-2.10.1.tar.xz`, SHA-256 | `1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27` | the `digest` of the asset in `api.github.com/repos/sparkle-project/Sparkle/releases/tags/2.10.1` |

`ci.yml` still uses `actions/checkout@v4` by tag. It reads no secret.

When a dependency is bumped, [DEPENDENCIES.md](DEPENDENCIES.md) has the steps.
In short:

- [ ] The version in `DEPENDENCIES.md` and in design §5.2.
- [ ] The licence file in `OpenRay/Resources/Licenses`, copied again from the
  library's `LICENSE` at the new version.
- [ ] For GRDB: both `Package.resolved` files, which CI compares.
- [ ] For Sparkle: `SPARKLE_VERSION` and `SPARKLE_TARBALL_SHA256` in
  `release.yml`. The release job stops early if the version was forgotten,
  but nothing notices a forgotten licence file.

## 7. Yours too, but not holding up v0.1

- [ ] **The pasteboard experiment** (design §4.5, and item 6 of §8). Clipboard
  history, its settings pane and onboarding step 4 are not built and do not
  start before this has been run on macOS 26 and 27 with the probe of a Debug
  build. It also settles item 29. A snippet with `{clipboard}` does not wait
  for it: it reads the clipboard once when it is pasted, and its check is in
  section 4.
- [ ] **homebrew-cask** (item 25). Submitting the cask to Homebrew itself
  needs a repository that is older and better known than a new one can be.
  Until then the tap is the way to install.
- [ ] **Ranking constants** (item 9). They are still the first guesses of
  milestone 2. Tuning them needs recorded sessions, and there are none.
- [ ] **UI tests in CI** (item 20), and the lint step for `swift format`,
  which CI does not run yet (design §5.4).
- [ ] The UNVERIFIED note in the design that belongs to a feature not built
  yet: whether pasteboard access has a usage-description key (clipboard
  history). The one about Apple events from a script's `osascript` has its
  check in section 4 since milestone 8.
