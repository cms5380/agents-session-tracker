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
    let group: String?
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

    func statusColor(_ status: String) -> NSColor {
        switch status {
        case "waiting": return .systemOrange
        case "running": return .systemGreen
        default: return .systemGray
        }
    }

    func addHeader(_ menu: NSMenu, _ title: String) {
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        h.isEnabled = false
        h.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(h)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // user-defined groups first (sessions inside keep their status dot)
        let grouped = Dictionary(grouping: sessions.filter { $0.group != nil }, by: { $0.group! })
        for name in grouped.keys.sorted() {
            addHeader(menu, "▾ \(name)")
            let order = ["waiting", "running", "done", "gone"]
            for s in grouped[name]!.sorted(by: {
                (order.firstIndex(of: $0.status) ?? 9) < (order.firstIndex(of: $1.status) ?? 9)
            }) {
                addRow(menu, s, statusColor(s.status))
            }
        }

        let ungrouped = sessions.filter { $0.group == nil }
        let statusGroups: [(String, String, NSColor)] = [
            ("waiting", "NEEDS INPUT", .systemOrange),
            ("running", "RUNNING", .systemGreen),
            ("done", "IDLE", .systemGray),
            ("gone", "ENDED — click to reopen", .systemGray),
        ]
        var empty = grouped.isEmpty
        for (status, header, color) in statusGroups {
            let rows = ungrouped.filter { $0.status == status }
            if rows.isEmpty { continue }
            empty = false
            addHeader(menu, header)
            for s in rows { addRow(menu, s, color) }
        }
        if empty {
            let it = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }

        // assignment UI: Manage groups ▸ <session> ▸ <group choices>
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage groups", action: nil, keyEquivalent: "")
        manage.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let manageMenu = NSMenu()
        let allGroups = Set(sessions.compactMap { $0.group }).sorted()
        for s in sessions {
            var label = s.title ?? ((s.cwd ?? "?") as NSString).lastPathComponent
            if label.count > 36 { label = String(label.prefix(36)) + "…" }
            let sItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let sMenu = NSMenu()
            for g in allGroups {
                let gi = NSMenuItem(title: g, action: #selector(assignGroup(_:)), keyEquivalent: "")
                gi.target = self
                gi.representedObject = ["sid": s.session_id, "group": g]
                gi.state = (s.group == g) ? .on : .off
                sMenu.addItem(gi)
            }
            if !allGroups.isEmpty { sMenu.addItem(.separator()) }
            let newG = NSMenuItem(title: "New group…", action: #selector(newGroup(_:)), keyEquivalent: "")
            newG.target = self
            newG.representedObject = ["sid": s.session_id]
            sMenu.addItem(newG)
            if s.group != nil {
                let rm = NSMenuItem(title: "Remove from group", action: #selector(assignGroup(_:)), keyEquivalent: "")
                rm.target = self
                rm.representedObject = ["sid": s.session_id, "group": "-"]
                sMenu.addItem(rm)
            }
            sItem.submenu = sMenu
            manageMenu.addItem(sItem)
        }
        manage.submenu = manageMenu
        menu.addItem(manage)
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

    @objc func assignGroup(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let sid = info["sid"], let group = info["group"] else { return }
        DispatchQueue.global().async {
            runCST(["group", sid, group])
            self.refresh()
        }
    }

    @objc func newGroup(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let sid = info["sid"] else { return }
        let alert = NSAlert()
        alert.messageText = "New group"
        alert.informativeText = "Group name for this session:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                DispatchQueue.global().async {
                    runCST(["group", sid, name])
                    self.refresh()
                }
            }
        }
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
