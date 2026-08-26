// Claude Sessions — native menubar tracker with a SwiftUI popover.
// Build: swiftc -O -o claude-sessions-menubar ClaudeSessionsMenubar.swift
import AppKit
import SwiftUI

struct Session: Decodable, Identifiable, Equatable {
    let session_id: String
    let status: String
    let cwd: String?
    let title: String?
    let message: String?
    let updated_at: Double?
    let bg: Bool?
    let kind: String?
    let group: String?
    var id: String { session_id }
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

final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    var timer: Timer?

    func start() {
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
                if parsed != self.sessions { self.sessions = parsed }
                appDelegate?.updateTitle(sessions: parsed)
            }
        }
    }

    func jump(_ s: Session) {
        DispatchQueue.global().async { runCST(["jump", s.session_id]) }
    }

    func copyResume(_ s: Session) {
        DispatchQueue.global().async { runCST(["copy-resume", s.session_id]) }
    }

    func assign(_ sid: String, to group: String?) {
        DispatchQueue.global().async {
            runCST(["group", sid, group ?? "-"])
            self.refresh()
        }
    }

    func clean() {
        DispatchQueue.global().async {
            runCST(["clean"])
            self.refresh()
        }
    }

    func hub() {
        DispatchQueue.global().async { runCST(["hub"]) }
    }
}

func statusColor(_ status: String) -> Color {
    switch status {
    case "waiting": return Color(nsColor: .systemOrange)
    case "running": return Color(nsColor: .systemGreen)
    case "gone": return Color(nsColor: .systemGray).opacity(0.5)
    default: return Color(nsColor: .systemGray)
    }
}

func statusEmoji(_ status: String) -> String {
    switch status {
    case "waiting": return "🐝"
    case "running": return "🏃"
    case "gone": return "💤"
    default: return "☕️"
    }
}

func ageString(_ updated: Double?) -> String {
    guard let updated, updated > 0 else { return "" }
    let a = Date().timeIntervalSince1970 - updated
    if a < 60 { return "now" }
    if a < 3600 { return "\(Int(a / 60))m" }
    return "\(Int(a / 3600))h"
}

struct SessionRow: View {
    let s: Session
    let model: Model
    @State private var hovering = false

    var name: String {
        s.title ?? ((s.cwd ?? "?") as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(statusEmoji(s.status)).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text((s.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !ageString(s.updated_at).isEmpty {
                Text(ageString(s.updated_at))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(s.status).opacity(0.18)))
                    .foregroundStyle(statusColor(s.status))
            }
            if hovering {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.jump(s) }
        .draggable(s.session_id)
        .contextMenu {
            Button("Jump") { model.jump(s) }
            Button("Copy resume command") { model.copyResume(s) }
            if s.group != nil {
                Button("Remove from group") { model.assign(s.session_id, to: nil) }
            }
        }
        .help(s.message ?? s.cwd ?? "")
    }
}

struct GroupCard<Content: View>: View {
    let label: String
    let emoji: String
    let highlight: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(emoji).font(.system(size: 11))
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 8)
            content
                .padding(.horizontal, 4).padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(highlight ? 0.10 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlight ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.15), value: highlight)
    }
}

struct PopoverView: View {
    @ObservedObject var model: Model
    @State private var newGroupName = ""
    @State private var addingGroup = false
    @State private var dropTarget: String? = nil
    @State private var pendingGroups: [String] = []

    var groups: [String] {
        let derived = Set(model.sessions.compactMap { $0.group })
        return Array(derived.union(pendingGroups)).sorted()
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("🐾 Claude Sessions")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button { model.hub() } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .buttonStyle(.plain).help("Open agents hub")
                Button { model.clean() } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.plain).help("Clean stale sessions")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit")
            }
            .padding(.horizontal, 12).padding(.top, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(groups, id: \.self) { g in
                        GroupCard(label: g, emoji: "📁", highlight: dropTarget == g) {
                            VStack(spacing: 1) {
                                let members = model.sessions.filter { $0.group == g }
                                if members.isEmpty {
                                    Text("drag a session here 🫳")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                }
                                ForEach(members) { s in
                                    SessionRow(s: s, model: model)
                                }
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            if let sid = items.first {
                                model.assign(sid, to: g)
                                pendingGroups.removeAll { $0 == g }
                            }
                            dropTarget = nil
                            return true
                        } isTargeted: { over in
                            dropTarget = over ? g : (dropTarget == g ? nil : dropTarget)
                        }
                    }

                    GroupCard(label: "Sessions", emoji: "🌊", highlight: dropTarget == "__ungrouped__") {
                        VStack(spacing: 1) {
                            let ungrouped = model.sessions.filter { $0.group == nil }
                            if ungrouped.isEmpty {
                                Text("all grouped ✨")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                            ForEach(["waiting", "running", "done", "gone"], id: \.self) { st in
                                ForEach(ungrouped.filter { $0.status == st }) { s in
                                    SessionRow(s: s, model: model)
                                }
                            }
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        if let sid = items.first { model.assign(sid, to: nil) }
                        dropTarget = nil
                        return true
                    } isTargeted: { over in
                        dropTarget = over ? "__ungrouped__" : (dropTarget == "__ungrouped__" ? nil : dropTarget)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 420)

            HStack(spacing: 6) {
                if addingGroup {
                    TextField("group name", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            let name = newGroupName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty, !groups.contains(name) {
                                pendingGroups.append(name)
                            }
                            newGroupName = ""
                            addingGroup = false
                        }
                    Button("✕") { addingGroup = false; newGroupName = "" }
                        .buttonStyle(.plain).font(.system(size: 10))
                } else {
                    Button {
                        addingGroup = true
                    } label: {
                        Label("New group", systemImage: "folder.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text("drag rows into groups 🖐️")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .frame(width: 330)
    }
}

var appDelegate: AppDelegate?

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let model = Model()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appDelegate = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        updateTitle(sessions: [])
        model.start()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func updateTitle(sessions: [Session]) {
        let waiting = sessions.filter { $0.status == "waiting" }.count
        let running = sessions.filter { $0.status == "running" }.count
        guard let button = statusItem.button else { return }
        if waiting > 0 {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange, .labelColor]))
            button.title = " \(waiting)"
        } else if running > 0 {
            button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
            button.title = " \(running)"
        } else {
            button.image = NSImage(systemSymbolName: "pawprint", accessibilityDescription: nil)
            button.title = ""
        }
        button.imagePosition = .imageLeading
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
