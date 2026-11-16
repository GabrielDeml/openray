# Roadmap

OpenRay aims to cover the basics of a keyboard launcher on macOS, natively and
in the open. It is not trying to match any other launcher feature for feature.

This file says what ships and in what order. How each piece is built is in
[docs/DESIGN.md](docs/DESIGN.md).

## Milestones

Each milestone ends in something usable. The public release sits in the middle
on purpose: people contribute to things they can install.

| # | Milestone | What it adds | Done when |
|---|---|---|---|
| 0 | Foundations | Repo, licence, Xcode app, core Swift package, CI | CI builds a menu-bar app that launches |
| 1 | Launcher shell | Global hotkey, floating panel, search field, keyboard-driven results, a basic settings window for choosing the hotkey | It opens instantly over full-screen apps, on any Space or display, with no focus glitches |
| 2 | App search | App index kept fresh by file-system events, fuzzy matching, ranking by frequency and recency | It replaces Spotlight for launching apps in daily use |
| 3 | Command model | One interface for every feature, action panel (⌘K), the full settings window, launch at login, system commands, quicklinks, the shared permission flow | Adding a command touches no launcher code |
| 4 | First built-ins | Calculator, clipboard history, and the shared path for pasting into the previous app | Both are good enough to replace separate tools |
| 5 | Quick AI | Ask from the launcher, streamed answers, follow-ups | A question typed in the launcher gets a streamed answer using the user's own API key |
| 6 | Public v0.1 | Signing, notarisation, auto-update, Homebrew cask, demo, contributor guide | A stranger installs it with one command and it updates itself |
| 7 | More built-ins | Window management, Lock Screen, file search on its own "Search Files" screen, snippets | Each ships as its own release |
| 8 | Script commands | Scripts in a folder show up as commands, running silently or in a full-output view, with up to three text arguments | A shell script dropped in the folder runs from the launcher and shows its output |

Milestone 4 has a gate: clipboard history does not start until the pasteboard
privacy experiment under [Open questions](#open-questions) has been run.

### Where it stands

Milestones 0 to 3 and 5 are built, and of milestone 4 the calculator and the
paste path. Clipboard history still waits for the experiment.

Milestone 6 is built as far as it can be without an Apple Developer account:
the updater, the release job, the Homebrew cask and the contributor guide are
in the repository, and nothing has been released. Its test, a stranger
installing OpenRay with one command, is met once the maintainer has worked
through [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) and pushed the first tag.
The demo is on that list too.

Of milestone 7, window management and Lock Screen are built and not released.
They were built without moving a real window or locking the screen, so they
have their own block of manual checks in the release checklist. File search
and snippets are not built yet. Each of the three can ship as a release of its
own.

## Built ahead of the feature that needs it

Some shared pieces land earlier than the first feature that uses them, so that
later milestones extend them and never replace them.

| Piece | Built in | First needed by |
|---|---|---|
| Result and action types in their final shape | 1 | App search (2), command model (3) |
| Preferences store | 1 | Every later milestone |
| Shared permission flow | 3 | System commands (3), paste (4), window management (7) |
| List and custom screens inside the panel | 3 | Clipboard history (4), Quick AI (5), file search (7), scripts (8) |
| Shared paste path | 4 | Quick AI (5), snippets and Lock Screen (7) |

## Architecture

- **Layout:** a thin Xcode app target, with matching, ranking, the command
  model and storage in the `OpenRayCore` Swift package so they can be tested
  without launching the app.
- **Window:** a non-activating `NSPanel` hosting SwiftUI content.
- **Hotkey:** Carbon's `RegisterEventHotKey`, which needs no permission prompt.
- **Storage:** SQLite for usage ranking, clipboard history and snippets.
- **Distribution:** not sandboxed and outside the Mac App Store, because window
  management and unrestricted file search cannot work in the sandbox.
- **Commands:** built-in features own their SwiftUI views and plug into the
  launcher through one shared interface.
- **Minimum macOS 26.**

## Quick AI

- The first provider is the Claude API with the user's own key. It sits behind
  a small provider protocol so others (for example local models through
  Ollama) can be added without changing how the chat works.
- The key is stored in the macOS Keychain, never in a file.
- Not in the first version: saved chat history, custom AI commands, attaching
  files or screenshots.

## Out of scope for now

- A third-party extension API or extension store
- Compatibility with other launchers' extensions
- Cloud sync, team features, theming
- File results blended into the main search list
- Inline script output and scripts that refresh in the background
- Snippet expansion while typing in other apps
- Currency conversion in the calculator

## Open questions

The full list, with the milestone each must be settled by, is in section 8 of
[docs/DESIGN.md](docs/DESIGN.md). The ones that can change the roadmap:

- **Clipboard privacy (gates milestone 4):** recent macOS versions may show an
  alert when an app reads the pasteboard in the background. Run the experiment
  described in the design doc on macOS 26 and 27 before any clipboard-history
  work. If even polling for changes triggers the alert, clipboard history
  cannot ship as designed.
- **Lock Screen (milestone 7):** the command is built. It presses ⌃⌘Q for
  the user, and whether macOS locks the screen for a key press that an app
  made is still unconfirmed: it has to be tried by hand on macOS 26 and 27.
  If it does not work, the command is removed before the release that would
  carry it. No private API takes its place.
- **Notarisation (milestone 6):** the release job that signs and notarises is
  written and has never run. It needs a paid Apple Developer account and the
  rest of the one-time setup in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)
  before the first tag is pushed.
