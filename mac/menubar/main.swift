//
//  Claude Auto Start -- menu bar status item.
//
//  A tiny accessory app (no Dock icon, no window) that shows whether the
//  scheduled 07:00 session ran, and lets you run it now, retime it, or read
//  the log without opening a terminal.
//
//  It owns no state of its own: everything it shows is read from the launchd
//  agent plist and the session log that start-session.sh writes, so the menu
//  bar and the command line can never disagree.
//

import AppKit
import Foundation

// MARK: - Locations

enum Paths {
    static let jobLabel = "com.ominext.claude-auto-start"
    static let menuLabel = "com.ominext.claude-auto-start-menubar"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var logFile: URL { home.appending(path: "Library/Logs/claude-auto-start/session.log") }
    static var jobPlist: URL { home.appending(path: "Library/LaunchAgents/\(jobLabel).plist") }
    static var menuPlist: URL { home.appending(path: "Library/LaunchAgents/\(menuLabel).plist") }

    /// The shell scripts ship inside the app bundle, so the app can install,
    /// retime and remove the schedule on its own.
    static var scripts: URL { Bundle.main.resourceURL ?? URL(filePath: ".") }
    static var installScript: URL { scripts.appending(path: "install.sh") }
    static var uninstallScript: URL { scripts.appending(path: "uninstall.sh") }

    static var domain: String { "gui/\(getuid())" }
}

// MARK: - Shell

/// Runs a tool and gives up after `seconds`, so a hung CLI cannot freeze the
/// menu bar. Returns nil on timeout.
func shell(_ tool: String, _ args: [String], timeout seconds: Double) -> (code: Int32, output: String)? {
    let task = Process()
    task.executableURL = URL(filePath: tool)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return nil }

    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global().async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        task.terminate()
        return nil
    }
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

@discardableResult
func shell(_ tool: String, _ args: [String]) -> (code: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(filePath: tool)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Status read out of the log

struct Status {
    enum Kind { case ok, failed, working, never, notScheduled }

    var kind: Kind = .never
    var date: Date?
    var detail: String = ""
    var needsSignIn = false

    var title: String {
        switch kind {
        case .notScheduled: return "Not scheduled"
        case .never:        return "No runs yet"
        case .working:      return "Running now"
        case .ok:           return "Last run succeeded"
        case .failed:       return "Last run failed"
        }
    }

    var symbol: String {
        switch kind {
        case .notScheduled: return "clock.badge.questionmark"
        case .never:        return "clock"
        case .working:      return "clock.badge"
        case .ok:           return "clock.badge.checkmark"
        case .failed:       return "clock.badge.exclamationmark"
        }
    }
}

enum LogReader {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Lines look like: `2026-09-10 07:04:24  ERROR gave up after 5 attempts`
    private static func split(_ line: String) -> (Date, String)? {
        guard line.count > 21 else { return nil }
        let stampText = String(line.prefix(19))
        guard let date = stamp.date(from: stampText) else { return nil }
        let rest = line.dropFirst(19).trimmingCharacters(in: .whitespaces)
        return (date, rest)
    }

    static func current() -> Status {
        var status = Status()

        guard FileManager.default.fileExists(atPath: Paths.jobPlist.path) else {
            status.kind = .notScheduled
            status.detail = "The daily job is not registered on this account."
            return status
        }

        guard let text = try? String(contentsOf: Paths.logFile, encoding: .utf8) else {
            status.kind = .never
            status.detail = "Nothing has been logged yet."
            return status
        }

        let entries = text.split(separator: "\n").compactMap { split(String($0)) }
        guard !entries.isEmpty else {
            status.kind = .never
            status.detail = "Nothing has been logged yet."
            return status
        }

        // The most recent line that represents an outcome wins. A `===` banner
        // newer than any outcome means an attempt is in flight right now.
        for (date, rest) in entries.reversed() {
            if rest.hasPrefix("OK") {
                status.kind = .ok
                status.date = date
                status.detail = rest
                    .replacingOccurrences(of: #"^OK\s+attempt \d+:\s*"#,
                                          with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if status.detail.isEmpty { status.detail = "Session opened." }
                return status
            }
            if rest.hasPrefix("ERROR") || rest.hasPrefix("FAIL") {
                status.kind = rest.hasPrefix("ERROR") ? .failed : .working
                status.date = date
                status.detail = reason(near: entries) ?? rest
                let lowered = status.detail.lowercased()
                status.needsSignIn = lowered.contains("authenticate")
                    || lowered.contains("oauth")
                    || lowered.contains("logged out")
                return status
            }
            if rest.hasPrefix("===") {
                status.kind = .working
                status.date = date
                status.detail = "Opening a session."
                return status
            }
        }

        status.kind = .never
        return status
    }

    /// The CLI's own message, taken from the newest FAIL line.
    private static func reason(near entries: [(Date, String)]) -> String? {
        for (_, rest) in entries.reversed() where rest.hasPrefix("FAIL") {
            guard let colon = rest.range(of: "): ") else { continue }
            let message = rest[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            return message.isEmpty ? nil : message
        }
        return nil
    }
}

// MARK: - The Claude CLI

enum Claude {
    /// A GUI app inherits almost no PATH, so the usual install locations have
    /// to be checked by hand.
    static let binary: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The authoritative answer, straight from the CLI. nil when it cannot be
    /// asked. The log only says what was true at the last run, which is why
    /// this exists: signing in does not write a log line, so without it the
    /// menu would keep asking you to sign in long after you had.
    static func isSignedIn() -> Bool? {
        guard let bin = binary,
              let result = shell(bin, ["auth", "status"], timeout: 6),
              let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["loggedIn"] as? Bool
    }
}

// MARK: - The scheduled job

enum Job {
    /// Reads the hour and minute straight out of the installed plist.
    static func scheduledTime() -> String? {
        guard let data = try? Data(contentsOf: Paths.jobPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let cal = dict["StartCalendarInterval"] as? [String: Any],
              let hour = cal["Hour"] as? Int,
              let minute = cal["Minute"] as? Int
        else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func runNow() {
        shell("/bin/launchctl", ["kickstart", "-k", "\(Paths.domain)/\(Paths.jobLabel)"])
    }

    static func install(at time: String) -> (code: Int32, output: String) {
        shell("/bin/bash", [Paths.installScript.path, time])
    }

    static func uninstall() -> (code: Int32, output: String) {
        shell("/bin/bash", [Paths.uninstallScript.path])
    }
}

// MARK: - Open at login, for this menu bar app

enum LoginItem {
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: Paths.menuPlist.path) }

    static func set(_ on: Bool) {
        let fm = FileManager.default
        if on {
            let plist: [String: Any] = [
                "Label": Paths.menuLabel,
                "ProgramArguments": [Bundle.main.executableURL?.path ?? ""],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            try? fm.createDirectory(at: Paths.menuPlist.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                              format: .xml, options: 0) {
                try? data.write(to: Paths.menuPlist)
            }
            // Deliberately not bootstrapped here: RunAtLoad would immediately
            // start a *second* copy alongside the one the user is looking at,
            // and two status items would appear. launchd picks the plist up at
            // the next login, which is exactly when it is wanted.
        } else {
            shell("/bin/launchctl", ["bootout", "\(Paths.domain)/\(Paths.menuLabel)"])
            try? fm.removeItem(at: Paths.menuPlist)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var status = Status()
    /// Only consulted while the log points at an authentication failure.
    private var signedInNow: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.isOnlyInstance() else {
            // A copy is already in the menu bar (launched at login, say).
            NSApp.terminate(nil)
            return
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .removalAllowed

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // First launch after an install: keep the icon coming back at login.
        if !LoginItem.isEnabled { LoginItem.set(true) }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// True when this process is the oldest running copy of the app. The one
    /// that started first keeps the status item; later ones bow out.
    private static func isOnlyInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .map(\.processIdentifier)
            .filter { $0 != mine }
        return others.allSatisfy { $0 > mine }
    }

    // Always show the truth at the moment the menu is opened.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        // Asking the CLI costs a process launch, so only do it when the log
        // blames authentication, and only when someone is actually looking.
        signedInNow = status.needsSignIn ? Claude.isSignedIn() : nil
        rebuild(menu)
    }

    private func refresh() {
        status = LogReader.current()
        guard let button = item.button else { return }

        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.title)
            ?? NSImage(systemSymbolName: "clock", accessibilityDescription: status.title)

        if status.kind == .failed {
            // The one state worth breaking menu bar monochrome for.
            let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = image?.withSymbolConfiguration(red)
            button.image?.isTemplate = false
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = "Claude Auto Start — \(status.title.lowercased())"
    }

    // MARK: Menu

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header(status.title))
        if let date = status.date {
            menu.addItem(caption(Self.when(date)))
        }
        if !status.detail.isEmpty {
            menu.addItem(caption(status.detail, wrap: true))
        }

        menu.addItem(.separator())

        if status.needsSignIn {
            if signedInNow == true {
                // Signed in since that run. Nothing is wrong any more; the log
                // is simply older than the sign in.
                menu.addItem(caption("You are signed in now. Run it once to clear this.", wrap: true))
            } else {
                let fix = NSMenuItem(title: "Sign in to Claude…",
                                     action: #selector(signIn), keyEquivalent: "")
                fix.target = self
                fix.image = NSImage(systemSymbolName: "person.badge.key",
                                    accessibilityDescription: nil)
                menu.addItem(fix)
                menu.addItem(caption("Runs will keep failing until you sign in.", wrap: true))
            }
            menu.addItem(.separator())
        }

        if status.kind == .notScheduled {
            add(menu, "Schedule Daily Run…", #selector(changeTime))
        } else {
            add(menu, "Run Now", #selector(runNow), key: "r")
        }
        add(menu, "Open Log", #selector(openLog), key: "l")

        menu.addItem(.separator())

        let time = Job.scheduledTime()
        menu.addItem(caption(time.map { "Scheduled daily at \($0)" } ?? "No schedule registered"))
        if status.kind != .notScheduled {
            add(menu, "Change Time…", #selector(changeTime))
            add(menu, "Remove Schedule…", #selector(removeSchedule))
        }

        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    private func header(_ text: String) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        ])
        entry.isEnabled = false
        return entry
    }

    private func caption(_ text: String, wrap: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        entry.attributedTitle = NSAttributedString(string: wrap ? wrapped(text) : text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        entry.isEnabled = false
        return entry
    }

    /// Menu items do not wrap on their own; break long CLI messages by hand.
    private func wrapped(_ text: String, width: Int = 44) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > width {
                lines.append(line)
                line = String(word)
            } else {
                line = line.isEmpty ? String(word) : line + " " + word
            }
            if lines.count == 3 { break }
        }
        if !line.isEmpty && lines.count < 3 { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Actions

    @objc private func runNow() {
        Job.runNow()
        // Give the worker a moment to write its opening line.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    @objc private func openLog() {
        if FileManager.default.fileExists(atPath: Paths.logFile.path) {
            NSWorkspace.shared.open(Paths.logFile)
        } else {
            NSWorkspace.shared.open(Paths.logFile.deletingLastPathComponent())
        }
    }

    /// Opens Terminal on a throwaway .command file. Using a file rather than
    /// AppleScript keeps this out of the Automation permission prompt.
    @objc private func signIn() {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "claude-sign-in.command")
        let bin = Claude.binary ?? "claude"
        // Re-run the job once the sign in succeeds. Otherwise the icon stays
        // red until the next 07:00, because nothing has written a log line.
        let body = """
        #!/bin/bash
        echo "Signing in to Claude Code. Finish in the browser window that opens."
        echo
        if "\(bin)" auth login; then
            echo
            echo "Signed in. Opening a session so the menu bar catches up..."
            /bin/launchctl kickstart -k "gui/$(id -u)/\(Paths.jobLabel)"
        fi
        echo
        echo "You can close this window."
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    @objc private func changeTime() {
        let alert = NSAlert()
        alert.messageText = "Daily run time"
        alert.informativeText = "When should the Claude session open each day? "
            + "If the Mac is asleep then, it runs as soon as it wakes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        field.stringValue = Job.scheduledTime() ?? "07:00"
        field.placeholderString = "07:00"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let time = field.stringValue.trimmingCharacters(in: .whitespaces)

        guard time.range(of: #"^([01]?\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else {
            report("That is not a time", "Enter it as HH:MM, for example 06:30.", .warning)
            return
        }

        let result = Job.install(at: time)
        if result.code == 0 {
            refresh()
        } else {
            report("Could not change the time", result.output, .warning)
        }
    }

    @objc private func removeSchedule() {
        let alert = NSAlert()
        alert.messageText = "Remove the daily run?"
        alert.informativeText = "The session will no longer open on its own. "
            + "The log is kept, and you can schedule it again from this menu."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = Job.uninstall()
        if result.code != 0 { report("Could not remove the schedule", result.output, .warning) }
        refresh()
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func report(_ title: String, _ body: String, _ style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = style
        alert.runModal()
    }
}

// MARK: - Self test

/// `ClaudeAutoStart --selftest` puts the status item up, reports what it
/// resolved, and exits. Useful when the menu bar is not visible to you: over
/// SSH, from a build machine, or when diagnosing a missing icon.
func selfTest() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    print("Claude Auto Start self test")
    print("---------------------------")

    let status = LogReader.current()
    print("state:        \(status.title)")
    print("when:         \(status.date.map { "\($0)" } ?? "n/a")")
    print("detail:       \(status.detail.isEmpty ? "n/a" : status.detail)")
    print("needs signin: \(status.needsSignIn)")
    print("claude cli:   \(Claude.binary ?? "NOT FOUND")")
    print("signed in:    \(Claude.isSignedIn().map { $0 ? "yes" : "no" } ?? "could not ask")")
    print("schedule:     \(Job.scheduledTime() ?? "not registered")")
    print("open at login:\(LoginItem.isEnabled ? " yes" : " no")")
    print("scripts:      \(FileManager.default.fileExists(atPath: Paths.installScript.path) ? "bundled" : "MISSING from Resources")")

    var bad = 0
    print("symbols:")
    for name in ["clock", "clock.badge", "clock.badge.checkmark",
                 "clock.badge.exclamationmark", "clock.badge.questionmark",
                 "person.badge.key"] {
        let ok = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        if !ok { bad += 1 }
        print("  \(ok ? "ok  " : "MISS") \(name)")
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let hasButton = item.button != nil
    item.button?.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
    let hasImage = item.button?.image != nil
    print("status item:  \(hasButton ? "created" : "FAILED to create")")
    print("icon drawn:   \(hasImage ? "yes (\(status.symbol))" : "NO IMAGE")")
    NSStatusBar.system.removeStatusItem(item)

    let ok = hasButton && hasImage && bad == 0
    print("---------------------------")
    print(ok ? "PASS" : "FAIL")
    exit(ok ? 0 : 1)
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") { selfTest() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
app.run()
