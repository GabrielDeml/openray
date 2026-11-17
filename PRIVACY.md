# Privacy

What OpenRay sends from your Mac and what it keeps on it. This describes the
code in this repository as it is, feature by feature. The paths below use the
bundle identifier of a released build, `io.github.gabrieldeml.openray`; a Debug
build, which is what Xcode runs from this repository, uses
`io.github.gabrieldeml.openray.debug` and keeps everything apart from an
installed copy.

OpenRay has no telemetry, no analytics and no crash reporting. It has no
account and no server of its own.

## What leaves your Mac

OpenRay connects to the network for two things: Quick AI, when you ask it
something, and updates. A third, quicklinks, hands an address to your browser.
Nothing else in OpenRay makes a network request. A script you run from
OpenRay is another matter: it is a program of your own, and what it sends is
up to it ([Scripts](#scripts) below).

### Quick AI

Quick AI sends nothing until you enter an Anthropic API key in Settings ›
Quick AI. With a key, it sends requests to `api.anthropic.com` over HTTPS, and
only at these moments:

- **When you ask**, with Tab or Return, ask a follow-up, or regenerate an
  answer: a request to `/v1/messages`. It carries your question, the earlier
  questions and answers of the current thread, a short instruction text that
  includes today's date, the name of the model, the effort setting and a limit
  on the length of the answer. Your API key goes along in a header. A request
  that failed for a passing reason, such as an overloaded server, is sent
  again unchanged, at most twice.
- **When you press Save & Verify** in Settings › Quick AI: a request to
  `/v1/models` with the key you entered, to find out whether Anthropic accepts
  it. It carries nothing else of yours.

Quick AI never sends what you type before you ask, and never your clipboard,
your selection, your files or what is on your screen.

The connection keeps no cache and no cookies and follows no redirect, so a
request never goes to another host than `api.anthropic.com`.

Anthropic handles what it receives through its API under its
[commercial terms](https://www.anthropic.com/legal/commercial-terms).

### Updates

A released build looks for updates. A Debug build, which is what Xcode runs
from this repository, never does, and neither does any build made without the
key that updates are checked against. A Release build that someone makes from
this repository with that key behaves like a released one;
[CONTRIBUTING.md](CONTRIBUTING.md) says how to make one that does not.

A released build checks on a schedule if you allowed that: in the welcome
window, in Settings › Updates, or in the updater's own question, which
appears at the second launch if you closed the welcome window before it asked.
It also checks whenever you choose "Check for Updates…". A check downloads the
list of releases from `https://gabrieldeml.github.io/openray/appcast.xml`,
which is hosted on GitHub Pages. If you install an update, it is downloaded
from the releases of this repository on GitHub.

The updater is [Sparkle](https://sparkle-project.org). Its requests say which
version of OpenRay and of Sparkle is asking (`OpenRay/0.1.0 Sparkle/2.10.1`).
Sparkle's optional system profile is switched off and nothing in OpenRay
switches it on, so no description of your Mac is sent. As with any request,
GitHub sees your IP address and the headers macOS adds on its own, such as
your preferred languages.

### Quicklinks

A quicklink, such as the Google and DuckDuckGo searches OpenRay starts with,
puts what you typed into a web address and opens it in your browser. The
request is your browser's, to the site the quicklink names. OpenRay does this
only when you run the quicklink. In the same way, a link in Settings or in an
answer of Quick AI opens in your browser when you click it.

### Scripts

A script command is your own program, which OpenRay starts when you run it
from the launcher and at no other time. It runs as you, without a sandbox,
and can read, send and store whatever you can. OpenRay does not look at what
a script does and does not limit it. OpenRay itself sends nothing when a
script runs.

A script is handed the texts you typed for its arguments, the environment
variables of your login shell, described under
[What is not kept](#what-is-not-kept), and a few variables of OpenRay's own:
that OpenRay started it, OpenRay's version and the script's path.

macOS is expected to treat OpenRay as responsible for the programs it
starts; Apple documents that for access to the local network, and it has not
been tried yet for the other permissions. So when macOS asks whether
"OpenRay" may control another app or use your Documents folder, it can be a
script you ran that is asking, and what you answer then holds for OpenRay and
for every script it runs.

## What is kept on your Mac

### The database

`~/Library/Application Support/io.github.gabrieldeml.openray/OpenRay.sqlite`,
with the two companion files SQLite keeps beside it, holds:

- **What you picked**, so that results you use often rank higher: the app,
  command, snippet, script or file, how often and how recently. A file is
  stored as its path, and only once you did something with it from the list
  of Search Files: opened it, revealed it, listed the apps that open it,
  previewed it, copied its path or moved it to the Trash. The app you chose
  in an Open With list is stored the same way, as the app's path. A script
  is stored as the path of its file (`script:` and the path) once you ran it
  or did something else with it from search. A file or folder in the Script
  Diagnostics list is stored as its path too, once you opened it, revealed
  it or copied its path from there.
- **What you had typed when you picked it**: the text of the search field at
  that moment, without capitals or accents and cut to 32 characters, stored
  with the result it led to. This is how "s" learns to mean Safari. That
  covers a calculation whose result you copied or pasted, what you typed into
  Search Snippets when you picked a snippet from its list, what you typed
  into Search Files when you did something with a file from its list, what
  you typed to find a script, and what you typed into Script Diagnostics
  when you did something with a file there. It does not cover what you type
  for a script's arguments: that is handed to the script and stored nowhere.
  Nor does it cover text you handed on to a web search or to Quick AI from the
  "Use … with" rows: that text is not stored. Text handed on to Search Files
  from those rows is not stored either, until you do something with a file it
  found; it then counts as typed into Search Files.
- **Your aliases**, the commands and apps you hid or disabled, **your
  quicklinks**, and the order of the commands offered when a search finds
  nothing.
- **Your snippets**: the name, the keyword and the text of each, and when it
  was made and last changed. Deleting a snippet removes it from the database.
  What was stored about your picks of it, as described above, is not removed
  with it: it stays under an ID that says nothing about the snippet.
- **The hotkeys you gave to apps and commands** in Settings › Commands: for
  each, the key with its modifiers and the ID of the item it runs. For an app
  that is its bundle identifier, or its path if it has none; for a script it
  is the path of its file (`script:` and the path), as for a pick. Clearing
  a hotkey removes it from the database, and so does deleting the quicklink
  or the snippet it belonged to. The hotkey of an app you uninstalled or of a
  script you deleted stays, without doing anything, so that it works again
  when the app or the script is back; it goes when you give its keys to
  another command. Pressing a hotkey is not counted as a pick: OpenRay stores
  nothing about when or how often you use one.

If the database cannot be read, OpenRay sets it aside under a name ending in
`.corrupt-` and a date, in the same folder, and starts a new one. If the
snippets and the hotkeys of commands in the old file can still be read, they
are copied into the new one.

### The Scripts folder

`~/Library/Application Support/io.github.gabrieldeml.openray/Scripts` is
made, empty, when OpenRay starts, for you alone. What is in it is yours:
OpenRay writes no file there. It reads the beginning of each file in that
folder, in the folders you added and in the folders one level below them,
8 KiB at most, to find the scripts among them, together with each file's
owner and permissions, and a picture that a script names as its icon. It
changes a script's file in two cases only, both of them after you asked:
Make Executable gives the file's owner the permission to run it, and
confirming a script that macOS marked as downloaded takes that mark off.

### Preferences

The app's preferences
(`~/Library/Preferences/io.github.gabrieldeml.openray.plist`) hold the hotkey
that opens the launcher (the hotkeys of commands are in the database),
which onboarding steps you have seen, the extra folders you added for app
search, whether the hint about pasting has been shown, the model and effort
chosen for Quick AI, the gap and the room for Stage Manager that the window
commands leave, for Search Files where it looks, the folders you chose for
it and whether the slower search without Spotlight is switched on, and the
script folders you added, as their paths.

Sparkle keeps its own settings in the same place: whether to check and to
install automatically, when it last checked, and a version you chose to skip.

### The updater's cache

Sparkle downloads updates into
`~/Library/Caches/io.github.gabrieldeml.openray/org.sparkle-project.Sparkle`
and removes what is older than ten days. It downloads with the system's
default network session, which lets macOS keep its usual cache and cookie
files for the app.

### The Keychain

Your Anthropic API key is stored in the macOS Keychain and nowhere else: not
in a file and not in the preferences. It is a password item of your login
keychain with the service `io.github.gabrieldeml.openray.anthropic` and the
account `api-key`, and it is not synced to iCloud. OpenRay reads it when it
sends a request to Anthropic and when the Quick AI pane of Settings opens.
"Remove Key" in that pane deletes it.

### Logs

OpenRay writes to the macOS unified log. Values in its messages are marked
private, so that macOS stores `<private>` in their place. The exceptions are
counts, status and error codes, the names of OpenRay's own commands, screens,
settings and database queries, the identifier of a system app that a command
is sent to, the type of what was put on the clipboard, the name of the model,
the ID Anthropic gives a request and how the request ended, the updater's
error message, why a window command moved no window, which is one of a
handful of fixed words such as `fullScreen`, and the process ID of a script
that ran for longer than it may. What you type, your questions,
the answers and the API key are not logged, and a window command logs neither
the window's title nor its app. Search Files logs that a file was moved to
the Trash, with the file's path marked private like any other value, and that
Spotlight seems to be switched off when it finds that out. It logs nothing
about what you searched for. Script commands log how many scripts and how
many files with a problem the script folders hold; where the shell
environment came from, how many variables it has and how long reading it
took; and how a script ended, with its exit code, a timeout or a stop, and
the script's path marked private. They never log what you typed for a
script's arguments, anything a script printed, or an environment variable,
neither its name nor its value. When the hotkey of a command cannot be
registered, OpenRay logs why, with the item it belongs to marked private. A
press of a hotkey adds one line of its own, and only when the press is
ignored because its command is still running; that line does not name the
item. The command a press runs logs what it logs when it is run from the
launcher, as described above. That includes a line when the command fails,
with the name of OpenRay's action and the error's domain and code. The
error's text can name a file and is marked private.

## What is not kept

- **Quick AI threads.** A thread lives in memory. It is gone when OpenRay
  quits, when you start a new chat, and when you come back to it more than a
  quarter of an hour after its last answer.
- **Your clipboard.** OpenRay writes to the clipboard when you copy or paste
  a result, and it has no clipboard history. It reads the clipboard in one
  case: when you paste or copy a snippet whose text contains `{clipboard}`,
  OpenRay reads the plain text that is on the clipboard at that moment and
  puts it into the snippet in that place. macOS may ask you before it lets
  OpenRay read. What was read is not stored and not logged, and a snippet
  without `{clipboard}` reads nothing. The preview in Settings › Snippets
  does not read the clipboard either. (A Debug build contains a test window,
  opened only with a launch argument, that calls the clipboard when one of
  its buttons is pressed. Released builds do not contain it.)
- **What a script prints.** The output of the script that ran last is kept
  in memory, 4 MB of it at most, so that Show Last Script Output can show
  it. It is gone when the next script is started and when OpenRay quits. It
  is not written to disk and not logged. The last line a silent script printed is
  shown on screen for a moment when the script is done.
- **Your shell environment.** Before OpenRay runs the first script after it
  was started, it starts your login shell the way a terminal window does, so
  your shell's startup files run, and reads the environment variables the
  shell then has. If the shell gives no answer that way, OpenRay starts it a
  second time, without the startup files that are only for a shell you type
  into. That is how a script finds the tools you use in Terminal. Reload
  Shell Environment, and the Reload button in Settings › Scripts, do it
  again. These variables can hold secrets, such as access tokens. OpenRay
  keeps them in memory only, hands them to the scripts you run and to
  nothing else, and never writes them to disk or to the log. Settings ›
  Scripts shows the name of the shell and how many variables there are, and
  no variable.
- **The windows of other apps.** A window command, such as Left Half, needs
  the Accessibility permission. With it, OpenRay reads the position and the
  size of the front window of the app you opened OpenRay over, or of the app
  in front when you press the command's hotkey, whether it is
  an ordinary window, whether its size can be changed and whether it is full
  screen, and then moves it. It does not read the window's title or what is
  in it. An app built on Chromium or Electron animates such a move unless an
  accessibility switch of the app is off, so OpenRay turns that switch off
  for the move and on again afterwards. Where a window was before OpenRay
  moved it is remembered for Restore Window, in memory only, until that app
  or OpenRay quits. To leave room for Stage Manager, OpenRay also reads from
  the preferences of macOS whether Stage Manager is on and which edge of the
  screen the Dock is on.
- **Lock Screen** presses ⌃⌘Q for you, which also needs the Accessibility
  permission. Nothing is read and nothing is kept.
- **Your files.** Search Files asks Spotlight, on this Mac, for the files
  whose names contain what you typed, and gets back their paths, their types
  and when each was last opened. Nothing of that leaves your Mac, and the
  list is not kept: only a file you act on is remembered, as described under
  the database above. OpenRay does not open the files it lists. Opening one
  hands it to its app, and the icon and the Quick Look preview of a file are
  drawn by macOS. For a file in your Desktop, Documents or Downloads folder,
  macOS may ask whether OpenRay may access that folder before it shows an
  icon or a preview or moves the file to the Trash. If Spotlight indexing is
  off and you switched on the slower search in Settings › File Search,
  OpenRay reads the names of the files in your home folder, or in the folders
  you chose, a few levels deep, each time you search; macOS may ask about the
  same three folders then. It reads names and nothing of the files'
  contents, and keeps none of it. OpenRay never asks for Full Disk Access.

## Removing everything

Delete the app, the two folders and the preferences file named above, and the
Keychain item. The first of the two folders holds your Scripts folder: move
your scripts out of it first if you want to keep them. Script folders that
you added are somewhere else and are not touched, and neither is anything a
script of yours stored. If you installed with Homebrew,
`brew uninstall --zap --cask openray` removes the app, the folders and the
preferences; the Keychain item is removed with "Remove Key" before that, or
in Keychain Access.
