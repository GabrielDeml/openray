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
Nothing else in OpenRay makes a network request.

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

## What is kept on your Mac

### The database

`~/Library/Application Support/io.github.gabrieldeml.openray/OpenRay.sqlite`,
with the two companion files SQLite keeps beside it, holds:

- **What you picked**, so that results you use often rank higher: the app or
  command, how often and how recently.
- **What you had typed when you picked it**: the text of the search field at
  that moment, without capitals or accents and cut to 32 characters, stored
  with the result it led to. This is how "s" learns to mean Safari. That
  covers a calculation whose result you copied or pasted. It does not cover
  text you handed on to a web search or to Quick AI from the "Use … with"
  rows: that text is not stored.
- **Your aliases**, the commands and apps you hid or disabled, **your
  quicklinks**, and the order of the commands offered when a search finds
  nothing.

If the database cannot be read, OpenRay sets it aside under a name ending in
`.corrupt-` and a date, in the same folder, and starts a new one.

### Preferences

The app's preferences
(`~/Library/Preferences/io.github.gabrieldeml.openray.plist`) hold the hotkey,
which onboarding steps you have seen, the extra folders you added for app
search, whether the hint about pasting has been shown, and the model and
effort chosen for Quick AI.

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
the ID Anthropic gives a request and how the request ended, and the updater's
error message. What you type, your questions, the answers and the API key are
not logged.

## What is not kept

- **Quick AI threads.** A thread lives in memory. It is gone when OpenRay
  quits, when you start a new chat, and when you come back to it more than a
  quarter of an hour after its last answer.
- **Your clipboard.** OpenRay writes to the clipboard when you copy or paste
  a result. It does not read it, and it has no clipboard history. (A Debug
  build contains a test window, opened only with a launch argument, that
  calls the clipboard when one of its buttons is pressed. Released builds do
  not contain it.)

## Removing everything

Delete the app, the two folders and the preferences file named above, and the
Keychain item. If you installed with Homebrew,
`brew uninstall --zap --cask openray` removes the app, the folders and the
preferences; the Keychain item is removed with "Remove Key" before that, or
in Keychain Access.
