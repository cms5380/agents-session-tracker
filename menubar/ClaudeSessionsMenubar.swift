// Claude Sessions — native menubar tracker.
// Build: swiftc -O -o claude-sessions-menubar ClaudeSessionsMenubar.swift
import AppKit
import Foundation

struct Session: Decodable {
    let session_id: String
    let status: String
    let cwd: String?
    let title: String?
    let message: String?
    let updated_at: Double?
    let bg: Bool?
    let kind: String?
}

let cstPath = ("~/.claude/session-tracker/cst" as NSString).expandingTildeInPath

@discardableResult
func runCST(_ args: [String], capture: Bool = false) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cstPath)
    p.arguments = args
    let pipe = Pipe()
    if capture { p.standardOutput = pipe }
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    if capture {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
    return ""
}

func dot(_ color: NSColor) -> NSImage? {
    let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
    return img?.withSymbolConfiguration(.init(paletteColors: [color]))
}

func dottedDot(_ color: NSColor) -> NSImage? {
    let img = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)
    return img?.withSymbolConfiguration(.init(paletteColors: [color]))
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var sessions: [Session] = []
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let out = runCST(["sessions-json"], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                self.sessions = parsed
                self.updateTitle()
            }
        }
    }

    func updateTitle() {
        let waiting = sessions.filter { $0.status == "waiting" }.count
        let running = sessions.filter { $0.status == "running" }.count
        let button = statusItem.button!
        if waiting > 0 {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange, .labelColor]))
            button.title = " \(waiting)"
        } else if running > 0 {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
            button.title = " \(running)"
        } else {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            button.title = ""
        }
        button.imagePosition = .imageLeading
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let groups: [(String, String, NSColor)] = [
            ("waiting", "NEEDS INPUT", .systemOrange),
            ("running", "RUNNING", .systemGreen),
            ("done", "IDLE", .systemGray),
            ("gone", "ENDED — click to reopen", .systemGray),
        ]
        var empty = true
        for (status, header, color) in groups {
            let rows = sessions.filter { $0.status == status }
            if rows.isEmpty { continue }
            empty = false
            let h = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            h.isEnabled = false
            h.attributedTitle = NSAttributedString(string: header, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(h)
            for s in rows { addRow(menu, s, color) }
        }
        if empty {
            let it = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let hub = NSMenuItem(title: "Open agents hub", action: #selector(openHub), keyEquivalent: "")
        hub.target = self
        hub.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        menu.addItem(hub)
        let clean = NSMenuItem(title: "Clean stale sessions", action: #selector(cleanStale), keyEquivalent: "")
        clean.target = self
        clean.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(clean)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func addRow(_ menu: NSMenu, _ s: Session, _ color: NSColor) {
        let cwd = s.cwd ?? "?"
        let home = NSHomeDirectory()
        let shortCwd = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        var name = s.title ?? (cwd as NSString).lastPathComponent
        if name.count > 46 { name = String(name.prefix(46)) + "…" }
        let isBG = s.bg ?? false
        let isDaemon = s.kind == "background"
        let badge: String
        if isBG {
            badge = s.kind == "interactive" ? "term" : "bg"
        } else if isDaemon {
            badge = "\(age(s.updated_at ?? 0)) · bg"
        } else {
            badge = age(s.updated_at ?? 0)
        }

        let item = NSMenuItem(title: "\(name)  ·  \(badge)", action: #selector(rowClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s
        item.image = isDaemon ? dottedDot(color) : dot(color)
        var tip = shortCwd
        if let m = s.message, !m.isEmpty { tip = "\(m) — \(shortCwd)" }
        item.toolTip = tip
        menu.addItem(item)

        if !isBG {
            let alt = NSMenuItem(title: "\(shortCwd)  ·  copy resume", action: #selector(copyResume(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = s
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.option]
            alt.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(alt)
        }
    }

    func age(_ updated: Double) -> String {
        let a = Date().timeIntervalSince1970 - updated
        if a < 60 { return "now" }
        if a < 3600 { return "\(Int(a / 60))m" }
        return "\(Int(a / 3600))h"
    }

    @objc func rowClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        DispatchQueue.global().async { runCST(["jump", s.session_id]) }
    }

    @objc func copyResume(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        DispatchQueue.global().async { runCST(["copy-resume", s.session_id]) }
    }

    @objc func openHub() {
        DispatchQueue.global().async { runCST(["hub"]) }
    }

    @objc func cleanStale() {
        DispatchQueue.global().async {
            runCST(["clean"])
            self.refresh()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
