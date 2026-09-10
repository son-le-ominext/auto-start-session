# auto-start-session

Opens a Claude Code session automatically at **07:00 every day** on your
machine, so your session and its rolling usage window are already live at the
start of the workday instead of starting whenever you first sit down.

A small status icon sits in the macOS menu bar or the Windows notification
area and tells you whether this morning's run worked, so a silent failure
cannot go unnoticed for days.

Works on **macOS** (launchd) and **Windows** (Task Scheduler). Both versions
have the same shape and the same behaviour; only the scheduler differs.

```
mac/        launchd agent + menu bar app  ->  ./install.sh   or  ClaudeAutoStart-<version>.pkg
windows/    scheduled task + tray app     ->  install.ps1    or  ClaudeAutoStart-<version>-Setup.cmd
packaging/  builds the two installers above into dist/
```

## Download and install

Take the installer for your platform from `dist/` and run it. Nothing else is
needed. Claude Code itself must already be installed and signed in.

**macOS: `ClaudeAutoStart-<version>.pkg`**

Double-click and follow the installer. It puts `Claude Auto Start.app` in your
Applications folder, registers the 07:00 job for the account that is logged
in, and puts the icon in the menu bar straight away.

The package is unsigned unless you build it with a Developer ID, so the first
time macOS will refuse to open it. Right-click the file and choose **Open**, or
go to System Settings, Privacy and Security, and click **Open Anyway**.

**Windows: `ClaudeAutoStart-<version>-Setup.cmd`**

Double-click. Windows shows its "publisher could not be verified" warning for
a downloaded script, so choose **Run**. The installer unpacks the scripts to
`%LOCALAPPDATA%\claude-auto-start`, registers the scheduled task, and starts
the tray icon. No administrator rights are needed.

Run it from a terminal to pass options:

```
ClaudeAutoStart-1.1.1-Setup.cmd 06:30          # a different time
ClaudeAutoStart-1.1.1-Setup.cmd -WakeToRun     # also wake the PC from sleep
ClaudeAutoStart-1.1.1-Setup.cmd -NoTray        # daily job only, no icon
```

## The status icon

The icon is the whole user interface. Everything it shows is read from the
scheduler and the log, so it can never disagree with the command line.

| Icon | Meaning |
| --- | --- |
| Clock with a tick | The last run opened a session. |
| Clock with an exclamation, in red | The last run failed. Open the menu for the reason. |
| Plain clock | Scheduled, but nothing has run yet. |
| Clock with a dot | A run is in progress. |

The menu gives you the last result and its time, the reason when it failed,
then **Run Now**, **Open Log**, **Change Time**, **Remove Schedule**, and
**Open at Login**. When the failure is an expired login, the menu grows a
**Sign in to Claude** item that opens a terminal on `claude auth login`, because no
amount of retrying fixes that one.

On Windows the icon also raises a balloon notification the first time a run
fails while it is up.

## The mark

The icon is a clock reading seven o'clock: one hand straight up, one down to
the left. That angle is the app's whole purpose, and unlike a sunrise or a
wordmark it still reads at sixteen pixels. Amber hands on a slate bezel over
an ink tile, with a warm haze low in the frame for the dawn the app exists to
sit in front of.

It is drawn in code, not stored as art. `packaging/icon/make-icons.swift`
renders every size with Core Graphics and writes the macOS `.icns`, the
Windows `.ico`, and one `.ico` per notification-area state. Redraw them after
editing the source:

```sh
packaging/icon/build-icons.sh
```

The generated files are committed, so an ordinary build needs no Swift
toolchain and no design tool. PNG proof sheets land in `packaging/icon/build/`
and are not shipped.

In the notification area on Windows the same clock is knocked out of a
state-coloured disc, because at sixteen pixels a filled disc reads where a
drawn bezel does not. On macOS the menu bar keeps SF Symbols: that is the
platform convention for a template image, and system-consistent beats
brand-consistent in a strip of other people's icons.

To check the icon without looking at the screen, useful over SSH or when
diagnosing a missing icon:

```bash
"/Applications/Claude Auto Start.app/Contents/MacOS/ClaudeAutoStart" --selftest
```

```powershell
& "$env:LOCALAPPDATA\claude-auto-start\tray.ps1" -SelfTest
```

## How the scheduled run works

On both platforms a small worker script runs one headless request:

```
claude -p "Reply with exactly: session started" --output-format text
```

Around that it does the same four things:

1. **Waits for the network**, up to 3 minutes. The job often fires while the
   machine is waking up, before Wi-Fi is back.
2. **Retries** up to 5 times, 60 s apart, with a 4 minute timeout per attempt.
3. **Logs** one line per attempt, rotated at 1 MB. The icon reads this file.
4. **Runs from a deployed copy**, not from this repo, so the repo can be moved
   or deleted without breaking the schedule. Edits take effect after you
   re-run the installer.

The scheduler on each platform is configured to behave the same way:

| Behaviour | macOS (launchd) | Windows (Task Scheduler) |
| --- | --- | --- |
| Fires daily at HH:MM | `StartCalendarInterval` | Daily trigger |
| Machine asleep or off at HH:MM? Runs when it comes back | Built-in launchd behaviour | `StartWhenAvailable` |
| Runs only when you are logged in, so Claude's credentials are readable | `LimitLoadToSessionType: Aqua` | `LogonType: Interactive` |
| Status icon returns after a restart | Per-user LaunchAgent | Logon-triggered task |
| Needs admin? | No | No |
| Wake the machine for the job | `sudo pmset repeat wakeorpoweron ...` | `install.ps1 -WakeToRun` |

## Running it from the repo instead

**macOS**

```sh
cd mac
./install.sh            # 07:00 daily
./install.sh 06:30      # or any HH:MM
./status.sh             # schedule, deploy state, last run
./uninstall.sh          # removes the agent; logs are kept
menubar/build-app.sh    # build the menu bar app into dist/
```

Fire the job right now to test:

```sh
launchctl kickstart -k gui/$(id -u)/com.ominext.claude-auto-start
```

Runtime locations:

- App: `/Applications/Claude Auto Start.app`, with the scripts in its `Contents/Resources`
- Deployed worker: `~/Library/Application Support/claude-auto-start/`
- Agents: `~/Library/LaunchAgents/com.ominext.claude-auto-start*.plist`
- Logs: `~/Library/Logs/claude-auto-start/session.log`

**Why the deploy step on macOS.** TCC blocks launchd agents from reading files
under `~/Documents`, `~/Desktop` and `~/Downloads`. A job pointed straight at
this repo fails with `Operation not permitted`, exit 126, even though running
`./start-session.sh` by hand works, because your terminal has that permission
and the agent does not. The installer therefore copies the worker somewhere
unprotected.

To have the Mac wake for the job: `sudo pmset repeat wakeorpoweron MTWRFSU 06:58:00`

**Windows**

Open PowerShell, no admin needed, in the `windows` folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1              # 07:00 daily
powershell -ExecutionPolicy Bypass -File .\install.ps1 06:30        # or any HH:MM
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WakeToRun   # also wake the PC
powershell -ExecutionPolicy Bypass -File .\status.ps1               # schedule and last run
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1            # removes both tasks
```

Fire the job right now to test:

```powershell
Start-ScheduledTask -TaskName 'Claude Auto Start'
```

Runtime locations:

- Scripts: `%LOCALAPPDATA%\claude-auto-start\`
- Tasks: `Claude Auto Start` and `Claude Auto Start Tray`, in Task Scheduler
- Logs: `%LOCALAPPDATA%\claude-auto-start\logs\session.log`

The tasks run under Windows PowerShell 5.1, which every supported Windows
ships with, so PowerShell 7 is not required. The `claude` CLI is found on
PATH, then at the native installer location, then the npm location.

## Configure

Each platform folder has a `config.example.*`. Copy it, edit, and re-run the
installer to deploy the change:

```sh
cd mac && cp config.example.sh config.local.sh && $EDITOR config.local.sh && ./install.sh
```

```powershell
cd windows; Copy-Item config.example.ps1 config.local.ps1; notepad config.local.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The local config can override the prompt, model, working directory, CLI path,
timeouts and retry behaviour. See the example file for the full list.

By default the scheduled request is deliberately trivial, `Reply with exactly:
session started`. It is enough to open a session and cheap enough not to
matter. Set the prompt and extra arguments if you want it to do real work. In
headless mode any tool not listed in `--allowed-tools` is denied rather than
prompting you.

## Files

| Path | Purpose |
| --- | --- |
| `mac/start-session.sh` | The worker: waits for network, runs `claude -p`, retries, logs. |
| `mac/install.sh` | Deploys the worker and registers the launchd agent. |
| `mac/status.sh` · `mac/uninstall.sh` | Inspect and remove. |
| `mac/config.example.sh` | Template for `mac/config.local.sh`. |
| `mac/com.ominext.claude-auto-start.plist.template` | launchd plist; `install.sh` fills in paths and time. |
| `mac/menubar/main.swift` | The menu bar app. Reads the log, drives the scripts. |
| `mac/menubar/build-app.sh` | Compiles it into a universal `.app` with the scripts and icon inside. |
| `mac/menubar/AppIcon.icns` | The application icon. Generated; do not edit by hand. |
| `windows/start-session.ps1` | The worker, same behaviour and log format. |
| `windows/tray.ps1` | The notification area icon, same menu as macOS. |
| `windows/install.ps1` | Deploys the scripts, registers both tasks, starts the icon. |
| `windows/status.ps1` · `windows/uninstall.ps1` | Inspect and remove. |
| `windows/config.example.ps1` | Template for `windows/config.local.ps1`. |
| `windows/icons/` | Application and per-state icons. Generated; do not edit by hand. |
| `packaging/build.sh` | Builds both installers into `dist/`. |
| `packaging/mac/` | `postinstall`, `Distribution.xml`, welcome and conclusion text. |
| `packaging/windows/setup-header.cmd` | The batch header the Windows installer is built from. |
| `packaging/icon/make-icons.swift` | Draws every icon the project ships. |
| `packaging/icon/build-icons.sh` | Runs the drawing and packs the `.icns` and `.ico` files. |
| `VERSION` | Version stamped into both installers. |

## Building the installers

```sh
packaging/icon/build-icons.sh # only needed after changing the artwork
packaging/build.sh            # both, into dist/
packaging/build.sh mac        # only the .pkg; needs macOS and the Swift toolchain
packaging/build.sh windows    # only the Setup.cmd; builds on any OS
```

The Windows installer is a plain batch file with the six PowerShell scripts
embedded as a base64 zip. Double-clicking it extracts them and runs
`install.ps1`. No third-party packaging tool is involved, so it can be built
on a Mac.

The macOS installer is a standard flat package whose entire payload is the
app. The app carries the shell scripts in its `Resources`, so one bundle in
Applications is the whole install. Its `postinstall` runs as root, finds the
user at the console, and runs the bundled `install.sh` inside that user's GUI
session, which is the only place a launchd agent and a menu bar item can
exist.

To sign it so Gatekeeper accepts it without the right-click:

```sh
SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" packaging/build.sh mac
xcrun notarytool submit dist/ClaudeAutoStart-*.pkg --keychain-profile "notary" --wait
xcrun stapler staple dist/ClaudeAutoStart-*.pkg
```

Bump `VERSION` before building a release.

## Notes and limitations

- **The machine must be powered on.** Neither scheduler can start a job on a
  machine that is off. Both can wake it from sleep: see the wake options above.
- **You must be logged in.** The job runs inside your login session, where the
  Claude Code credentials are readable. At the login screen it waits rather
  than runs, and fires as soon as you log in.
- **Credentials expire.** If Claude Code logs you out, the morning run fails
  with `Failed to authenticate: OAuth session expired`. The icon turns red and
  offers to sign you in. Retrying cannot fix this one.
- **The sign-in command is `claude auth login`.** Not `claude login`, which is
  not a command and silently does nothing useful. Check the real state with
  `claude auth status`, which prints `loggedIn`.
- **Signing in does not by itself turn the icon green.** The icon reports the
  last run, and signing in writes no log line. The menu's sign-in item re-runs
  the job for you once you finish. If you signed in another way, choose
  **Run Now**; until then the menu says you are signed in and waiting.
- Read the log, not the scheduler, to find out what happened. The scheduler
  only ever sees exit 0 or exit 1; the log has the CLI's actual message.
- **Upgrading from 1.0.0.** That version kept the scripts in
  `/Library/Application Support/claude-auto-start`. The 1.1.0 installer
  removes that folder, unless you put a `config.local.sh` in it, in which case
  it is left alone for you to move.
