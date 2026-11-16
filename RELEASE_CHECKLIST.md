# Release checklist

Everything a release of OpenRay needs that the repository cannot do for itself:
the accounts, keys and settings that have to exist before the first tag, the
steps of each release, and the checks that need a person at a Mac.

Milestone 6 was built without an Apple Developer account, without any secret and
without launching the app. The release job in
[.github/workflows/release.yml](.github/workflows/release.yml) has therefore
never run, CI has never run on GitHub's `macos-26` runner, and nothing that
milestone 6 put on screen has been looked at. This file is the list of what is
left. How the pieces work is in section 6 of [docs/DESIGN.md](docs/DESIGN.md).

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

## 2. One-time setup

In this order. Later steps need what earlier ones make.

### Get CI green

`.github/workflows/ci.yml` has never run for milestones 1 to 6: everything was
built with a newer Xcode than the Xcode 26 and Swift 6.2 of the `macos-26`
runner.

- [ ] Open a pull request, or push to `main`, and read the run: CI runs on
  those two and on nothing else. The three things most likely to fail there
  and nowhere else:
  1. Swift 6.2 compiling `OpenRay/System/SparkleUpdater.swift`, which conforms
     to `SPUStandardUserDriverDelegate` with `@preconcurrency` (design §6.4).
     Only a newer compiler has seen it.
  2. "Run core benchmarks", which builds the package in release mode with
     `-Xswiftc -enable-testing`. This step cannot fail the job; a failure
     shows as a warning on the run. Read its log either way.
  3. "Build app (Release)", the configuration the release job archives, and
     with it Xcode 26 merging the partial `Config/Info.plist` into the
     Info.plist it generates.
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
  build. It also settles item 29.
- [ ] **homebrew-cask** (item 25). Submitting the cask to Homebrew itself
  needs a repository that is older and better known than a new one can be.
  Until then the tap is the way to install.
- [ ] **Ranking constants** (item 9). They are still the first guesses of
  milestone 2. Tuning them needs recorded sessions, and there are none.
- [ ] **UI tests in CI** (item 20), and the lint step for `swift format`,
  which CI does not run yet (design §5.4).
- [ ] UNVERIFIED notes in the design that belong to features not built yet:
  file previews and Files & Folders prompts (milestone 7), Apple events from
  a script's `osascript` (milestone 8), and whether pasteboard access has a
  usage-description key (clipboard history).
