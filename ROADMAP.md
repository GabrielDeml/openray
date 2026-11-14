# Roadmap

OpenRay aims to cover the basics of a keyboard launcher on macOS, natively and
in the open. It is not trying to match any other launcher feature for feature.

## Milestones

Each milestone ends in something usable. The public release sits in the middle
on purpose: people contribute to things they can install.

| # | Milestone | What it adds | Done when |
|---|---|---|---|
| 0 | Foundations | Repo, licence, Xcode app, core Swift package, CI | CI builds a menu-bar app that launches |
| 1 | Launcher shell | Global hotkey, floating panel, search field, keyboard-driven results | It opens instantly over full-screen apps, on any Space or display, with no focus glitches |
| 2 | App search | App index kept fresh by file-system events, fuzzy matching, ranking by frequency and recency | It replaces Spotlight for launching apps in daily use |
| 3 | Command model | One interface for every feature, action panel (⌘K), settings window, launch at login, system commands, quicklinks | Adding a command touches no launcher code |
| 4 | First built-ins | Calculator and clipboard history | Both are good enough to replace separate tools |
| 5 | Quick AI | Ask from the launcher, streamed answers, follow-ups | A question typed in the launcher gets a streamed answer using the user's own API key |
| 6 | Public v0.1 | Signing, notarisation, auto-update, Homebrew cask, demo, contributor guide | A stranger installs it with one command and it updates itself |
| 7 | More built-ins | Window management, file search, snippets | Each ships as its own release |
| 8 | Script commands | Scripts in a folder show up as commands | A shell script dropped in the folder runs from the launcher and shows its output |

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
  Ollama) can be added without touching the UI.
- The key is stored in the macOS Keychain, never in a file.
- Not in the first version: saved chat history, custom AI commands, attaching
  files or screenshots.

## Out of scope for now

- A third-party extension API or extension store
- Compatibility with other launchers' extensions
- Cloud sync, team features, theming

## Open questions

- **Clipboard privacy:** recent macOS versions restrict background pasteboard
  reads. Confirm the behaviour on current macOS before building clipboard
  history.
- **Notarisation:** needs a paid Apple Developer account before milestone 6.
