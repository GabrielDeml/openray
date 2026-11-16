# Changelog

What changed in each release of OpenRay, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version numbers
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The section of a version is also the text of its GitHub release and what
OpenRay shows when it offers the update, so it is written for the people who
use the app. What is not released yet is collected under Unreleased;
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) says how that section becomes a
release.

## [Unreleased]

The first public release.

### Added

- **Launcher.** A global hotkey, ⌥Space unless you choose another, opens a
  search field over whatever you are doing. Everything works from the
  keyboard: arrows and Return, ⌘1 to ⌘9 for a row, Esc to go back.
- **App search.** Finds the apps on your Mac by fuzzy matching, including
  their localised names, and learns from what you pick: the app you usually
  mean by "s" moves to the top. More folders to search can be added in
  Settings.
- **Actions.** ⌘K lists what else can be done with the selected result, such
  as Show in Finder, Quit, Copy Path and Copy Bundle Identifier for an app.
- **System commands.** Sleep, Restart, Shut Down, Log Out, Empty Trash, Toggle
  Appearance and Quit All Apps, and Quit and Force Quit for each running app.
  Commands that cannot be undone ask first.
- **Quicklinks.** Open a link with what you type in it. Google and DuckDuckGo
  are there from the start, and you can add your own.
- **Aliases.** Give any app or command a short name of your own, or hide the
  ones you never use.
- **Calculator.** Type a calculation, a percentage or a unit conversion and
  the answer is the first result. Return copies it, and ⌘Return pastes it into
  the app you came from once OpenRay has the Accessibility permission.
- **Quick AI.** Type a question and press Tab to ask Claude with your own
  Anthropic API key. The answer streams into the launcher and follow-ups stay
  in the same thread. The key is kept in the macOS Keychain.
- **Settings.** The hotkey, launch at login, permissions, commands and
  quicklinks, Quick AI, updates, and the version and licences.
- **Updates.** OpenRay checks for new versions if you allow it. "Check for
  Updates" is in the menu-bar menu and in the launcher.
- **Homebrew.** `brew install gabrieldeml/openray/openray`.
- **Window management.** Nineteen commands move and resize the front window
  of the app you are in: the halves, the quarters, thirds and two thirds,
  Maximize Window, Almost Maximize Window, Center Window, Move Window to Next
  Display and to Previous Display, and Restore Window, which puts the window
  back where it was. Type "window", "tile" or "snap" to see them all. They
  need the Accessibility permission, and OpenRay shows where to grant it the
  first time you use one. Settings › Window Management has the gap to leave
  around windows and the room to leave for Stage Manager.
- **Lock Screen.** Locks the screen from the launcher. It needs the
  Accessibility permission.
