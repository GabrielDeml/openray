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

## [0.1.0] - 2026-11-24

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
- **Snippets.** Keep the text you type again and again and paste it from the
  launcher by its name or keyword. Search Snippets lists them all and also
  searches their text. A snippet can fill in the date, the time or what you
  last copied, and say where the caret goes after pasting. You write them in
  Settings › Snippets.
- **File search.** Search Files finds files and folders by name through
  Spotlight. Return opens the selected one, ⌘Return shows it in Finder, and
  ⌘K has Open With, a Quick Look preview (⌘Y), Copy Path and Move to Trash.
  It looks in your home folder unless you choose other folders, or the whole
  Mac, in Settings › File Search. When a search in the launcher finds
  nothing, Search Files is one of the rows that take what you typed. If
  Spotlight indexing is off, Search Files says so, and Settings › File Search
  has a slower search that works without it.
- **Script commands.** Make commands of your own scripts. Put an executable
  file into OpenRay's Scripts folder, which Open Scripts Folder shows, or
  into a folder you add in Settings › Scripts, and give it three comment
  lines at its top: `# @openray.schemaVersion 1`,
  `# @openray.title Toggle Wi-Fi` and `# @openray.mode silent`. A moment
  later it is in search under its title. A `silent` script runs with the
  launcher closed and shows its last line of output when it is done; a
  `fullOutput` script shows what it prints while it runs, with Stop (⌘.),
  Run Again (⌘R) and Copy Output (⌘⇧C). A script can have an icon and
  keywords, ask for up to three pieces of text before it runs, set a
  timeout, and ask to be confirmed each time. Scripts run with the
  environment of your login shell, so they find the tools you use in
  Terminal; Reload Shell Environment reads it again after you changed your
  shell's startup files. They run as you, without a sandbox. OpenRay runs a
  script only when you ask it to, does not run a file that other users of
  your Mac can change, and asks before it first runs a file you downloaded.
  Script Diagnostics lists the files that should be commands and are not,
  with the reason, and Show Last Script Output shows what the last script
  printed.
- **Hotkeys for commands.** Give any app or command a global hotkey of its
  own in Settings › Commands: click the field in its row and type the
  shortcut. Pressing it anywhere does what Return on that row does, without
  opening the launcher first. Left Half moves the window you are in, a
  snippet is pasted where you are typing, an app opens, a script runs. A
  command that asks before it acts, such as Shut Down, or that needs you to
  type something, such as a quicklink, opens the launcher for just that. A
  shortcut that already opens the launcher or belongs to another command is
  refused, and the row says which; so is one that another app holds. The
  launcher shows a command's hotkey on its row, and Set Hotkey… in ⌘K leads
  to where it is set. The × beside a hotkey removes it.
