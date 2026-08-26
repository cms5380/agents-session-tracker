// Claude Sessions — Raycast-style floating session switcher.
// Build: swiftc -O -o claude-sessions-menubar ClaudeSessionsMenubar.swift
import AppKit
import Carbon.HIToolbox
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
    @Published var focusTick = 0
    var moveSelection: ((Int) -> Void)?
    var arrowLR: ((Int) -> Bool)?
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
        appDelegate?.hidePanel()
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

    func renameSession(_ sid: String, to name: String) {
        DispatchQueue.global().async {
            runCST(["title", sid, name.isEmpty ? "-" : name])
            self.refresh()
        }
    }

    func renameGroup(_ old: String, to new: String) {
        DispatchQueue.global().async {
            runCST(["group-rename", old, new])
            self.refresh()
        }
    }

    func dissolveGroup(_ name: String) {
        DispatchQueue.global().async {
            runCST(["group-dissolve", name])
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
        appDelegate?.hidePanel()
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

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct SessionRow: View {
    let s: Session
    let model: Model
    var isSelected: Bool = false
    var onRename: ((Session) -> Void)? = nil
    @State private var hovering = false

    var name: String {
        s.title ?? ((s.cwd ?? "?") as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(statusEmoji(s.status)).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text((s.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !ageString(s.updated_at).isEmpty {
                Text(ageString(s.updated_at))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(s.status).opacity(0.18)))
                    .foregroundStyle(statusColor(s.status))
            }
            if hovering {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.22)
                    : hovering ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .onTapGesture { model.jump(s) }
        .draggable(s.session_id)
        .contextMenu {
            Button("Jump") { model.jump(s) }
            Button("Rename session") { onRename?(s) }
            Button("Copy resume command") { model.copyResume(s) }
            if s.group != nil {
                Button("Remove from group") { model.assign(s.session_id, to: nil) }
            }
        }
        .help(s.message ?? s.cwd ?? "")
    }
}

enum PanelRow: Identifiable, Equatable {
    case header(String)     // group name, or "__ungrouped__"
    case session(Session, indented: Bool)

    var id: String {
        switch self {
        case .header(let g): return "hdr-\(g)"
        case .session(let s, _): return s.session_id
        }
    }
}

struct GroupHeaderRow: View {
    let name: String
    let count: Int
    let hasAttention: Bool
    let expanded: Bool
    let isSelected: Bool
    let highlight: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(name == "__ungrouped__" ? "🌊" : "📁").font(.system(size: 12))
            Text(name == "__ungrouped__" ? "미배정" : name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if hasAttention {
                Circle().fill(Color(nsColor: .systemOrange)).frame(width: 7, height: 7)
            }
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.09)))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.22)
                    : highlight ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(highlight ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: toggle)
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    @State private var query = ""
    @State private var newGroupName = ""
    @State private var addingGroup = false
    @State private var renaming: String? = nil
    @State private var renamingSession: Session? = nil
    @State private var renameText = ""
    @State private var dropTarget: String? = nil
    @State private var pendingGroups: [String] = []
    @State private var expanded: Set<String> = []
    @State private var selected = 0
    @State private var scrollTarget: String? = nil
    @FocusState private var searchFocused: Bool

    var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return model.sessions }
        return model.sessions.filter {
            ($0.title ?? "").lowercased().contains(q)
                || ($0.cwd ?? "").lowercased().contains(q)
                || ($0.group ?? "").lowercased().contains(q)
        }
    }

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var attention: [Session] {
        filtered.filter { $0.status == "waiting" || $0.status == "running" }
            .sorted { a, b in
                if a.status != b.status { return a.status == "waiting" }
                return (a.updated_at ?? 0) > (b.updated_at ?? 0)
            }
    }

    var groups: [String] {
        let derived = Set(model.sessions.compactMap { $0.group })
        return Array(derived.union(Set(pendingGroups))).sorted()
    }

    func restMembers(_ g: String?) -> [Session] {
        filtered.filter { $0.group == g && $0.status != "waiting" && $0.status != "running" }
    }

    // the navigable list, in display order
    var rows: [PanelRow] {
        if searching {
            var out: [PanelRow] = []
            for st in ["waiting", "running", "done", "gone"] {
                out += filtered.filter { $0.status == st }.map { .session($0, indented: false) }
            }
            return out
        }
        var out: [PanelRow] = attention.map { .session($0, indented: false) }
        for g in groups {
            out.append(.header(g))
            if expanded.contains(g) {
                out += restMembers(g).map { .session($0, indented: true) }
            }
        }
        if !restMembers(nil).isEmpty {
            out.append(.header("__ungrouped__"))
            if expanded.contains("__ungrouped__") {
                out += restMembers(nil).map { .session($0, indented: true) }
            }
        }
        return out
    }

    var listHeight: CGFloat {
        let h = rows.reduce(CGFloat(0)) { acc, r in
            switch r {
            case .header: return acc + 34
            case .session: return acc + 47
            }
        }
        return min(max(h + 16, 100), 460)
    }

    func isSelected(_ r: PanelRow) -> Bool { rows[safe: selected]?.id == r.id }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + delta, 0), rows.count - 1)
        scrollTarget = rows[safe: selected]?.id
    }

    func toggleExpand(_ g: String) {
        if expanded.contains(g) { expanded.remove(g) } else { expanded.insert(g) }
    }

    // → expands / ← collapses when a group header is selected (query empty)
    func handleLR(_ dir: Int) -> Bool {
        guard !searching, case .header(let g)? = rows[safe: selected] else { return false }
        if dir > 0 { expanded.insert(g) } else { expanded.remove(g) }
        return true
    }

    func activateSelected() {
        switch rows[safe: selected] ?? rows.first {
        case .session(let s, _): model.jump(s)
        case .header(let g): toggleExpand(g)
        case nil: break
        }
    }

    func headerRow(_ g: String) -> some View {
        let members = filtered.filter { $0.group == (g == "__ungrouped__" ? nil : g) }
        let hasAttention = members.contains { $0.status == "waiting" }
        return GroupHeaderRow(
            name: g,
            count: members.count,
            hasAttention: hasAttention,
            expanded: expanded.contains(g),
            isSelected: isSelected(.header(g)),
            highlight: dropTarget == g
        ) { toggleExpand(g) }
        .contextMenu {
            if g != "__ungrouped__" {
                Button("Rename group") { renaming = g; renameText = g }
                Button("Dissolve group") {
                    model.dissolveGroup(g)
                    pendingGroups.removeAll { $0 == g }
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            if let sid = items.first {
                model.assign(sid, to: g == "__ungrouped__" ? nil : g)
                pendingGroups.removeAll { $0 == g }
                expanded.insert(g)
            }
            dropTarget = nil
            return true
        } isTargeted: { over in
            dropTarget = over ? g : (dropTarget == g ? nil : dropTarget)
        }
        .id("hdr-\(g)")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
                    .onExitCommand { appDelegate?.hidePanel() }
                    .onChange(of: query) { _ in selected = 0 }
                Text("🐾").font(.system(size: 16))
            }
            .padding(.horizontal, 16).padding(.top, 14)

            Divider().padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        if !searching && !attention.isEmpty {
                            HStack(spacing: 5) {
                                Text("🔥 ATTENTION")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.top, 2)
                        }
                        ForEach(rows) { r in
                            switch r {
                            case .header(let g):
                                headerRow(g)
                                    .padding(.top, 5)
                            case .session(let s, let indented):
                                SessionRow(s: s, model: model, isSelected: isSelected(r),
                                           onRename: { sess in
                                               renamingSession = sess
                                               renameText = sess.title ?? ""
                                           })
                                    .padding(.leading, indented ? 16 : 0)
                                    .id(r.id)
                            }
                        }
                        if rows.isEmpty {
                            Text(searching ? "no match 🔍" : "no sessions 💤")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: listHeight)
                .onChange(of: scrollTarget) { t in
                    if let t { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(t, anchor: .center) } }
                }
            }

            if let sess = renamingSession {
                HStack(spacing: 8) {
                    Text("Rename session →").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("session name (empty = auto)", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 200)
                        .onSubmit {
                            model.renameSession(sess.session_id,
                                                to: renameText.trimmingCharacters(in: .whitespaces))
                            renamingSession = nil
                        }
                    Button("✕") { renamingSession = nil }.buttonStyle(.plain).font(.system(size: 10))
                    Spacer()
                }
                .padding(.horizontal, 14)
            }

            if let g = renaming {
                HStack(spacing: 8) {
                    Text("Rename \(g) →").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("new name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 150)
                        .onSubmit {
                            let name = renameText.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty, name != g { model.renameGroup(g, to: name) }
                            renaming = nil
                        }
                    Button("✕") { renaming = nil }.buttonStyle(.plain).font(.system(size: 10))
                    Spacer()
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 8) {
                if addingGroup {
                    TextField("group name", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 160)
                        .onSubmit {
                            let name = newGroupName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty, !groups.contains(name) {
                                pendingGroups.append(name)
                                expanded.insert(name)
                            }
                            newGroupName = ""
                            addingGroup = false
                        }
                    Button("✕") { addingGroup = false; newGroupName = "" }
                        .buttonStyle(.plain).font(.system(size: 10))
                    Spacer()
                } else {
                    Button {
                        addingGroup = true
                    } label: {
                        Label("New group", systemImage: "folder.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Text("↩ open · →← fold · drag to group")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
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
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .frame(width: 480)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onChange(of: model.focusTick) { _ in
            query = ""
            selected = 0
            searchFocused = true
        }
        .onAppear {
            model.moveSelection = { move($0) }
            model.arrowLR = { handleLR($0) }
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            appDelegate?.hidePanel()
            return
        }
        super.keyDown(with: event)
    }
}

var appDelegate: AppDelegate?

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var panel: FloatingPanel!
    let model = Model()
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appDelegate = self

        panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: PanelView(model: model))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        updateTitle(sessions: [])
        model.start()
        registerHotkey()

        // arrow keys never reach SwiftUI while the search field editor has
        // focus — intercept them at the event level while the panel is key
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 125: self.model.moveSelection?(1); return nil // down
            case 126: self.model.moveSelection?(-1); return nil // up
            case 123: return self.model.arrowLR?(-1) == true ? nil : event // left
            case 124: return self.model.arrowLR?(1) == true ? nil : event // right
            default: return event
            }
        }
    }

    var keyMonitor: Any?

    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        model.refresh()
        panel.layoutIfNeeded()
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            let x = vf.midX - size.width / 2
            let y = vf.origin.y + vf.height * 0.72
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
        model.focusTick += 1
    }

    func hidePanel() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Raycast behavior: clicking elsewhere dismisses the panel
        hidePanel()
    }

    // Global hotkey (default ⌃⌥C) via Carbon — no accessibility permission
    // needed. Override with:
    //   defaults write com.dean.claude-sessions hotkeyKeyCode -int <keycode>
    //   defaults write com.dean.claude-sessions hotkeyModifiers -int <carbon-modifier-mask>
    func registerHotkey() {
        let defaults = UserDefaults(suiteName: "com.dean.claude-sessions")
        let keyCode = defaults?.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_C
        let modifiers = defaults?.object(forKey: "hotkeyModifiers") as? Int ?? (controlKey | optionKey)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { appDelegate?.togglePanel() }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x43535453), id: 1) // 'CSTS'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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
