// Claude Sessions — Raycast-style floating session switcher.
// Build: swiftc -O -o AgentsSessionTracker AgentsSessionTracker.swift
import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

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
    let pin_order: Int?
    let group_color: String?
    let group_order: Int?
    let sort_order: Int?
    let agent: String?
    let model: String?
    let parent: String?
    let continuation: Bool?
    var id: String { session_id }
    var pinned: Bool { pin_order != nil }
}

func namedColor(_ name: String?) -> Color {
    switch name {
    case "blue": return Color(nsColor: .systemBlue)
    case "green": return Color(nsColor: .systemGreen)
    case "purple": return Color(nsColor: .systemPurple)
    case "pink": return Color(nsColor: .systemPink)
    case "gray": return Color(nsColor: .systemGray)
    default: return Color(red: 0.85, green: 0.47, blue: 0.34)
    }
}

let astPath = ("~/.claude/session-tracker/ast" as NSString).expandingTildeInPath

let homeDirPath = NSHomeDirectory()

// opt-in panel tracer — defaults write com.dean.agents-session-tracker
// panelDebug -bool true; log lands next to the state files
let panelDebugOn = UserDefaults.standard.bool(forKey: "panelDebug")
func dbg(_ msg: @autoclosure () -> String) {
    guard panelDebugOn else { return }
    let line = "\(Date().timeIntervalSince1970) \(msg())\n"
    let path = homeDirPath + "/.local/state/claude-session-tracker/panel-debug.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@discardableResult
func runAST(_ args: [String], capture: Bool = false) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: astPath)
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
    // transient in-panel feedback for commands whose CLI output would
    // otherwise be swallowed (tidy, …)
    @Published var toast: String? = nil
    private var toastGen = 0
    func showToast(_ s: String) {
        DispatchQueue.main.async {
            self.toast = s
            self.toastGen += 1
            let gen = self.toastGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.toastGen == gen { self.toast = nil }
            }
        }
    }
    @Published var focusTick = 0
    @Published var panelVisible = false
    @Published var refreshing = false
    var moveSelection: ((Int) -> Void)?
    var arrowLR: ((Int) -> Bool)?
    var hotkeyNumber: ((Int) -> Void)?
    var enterKey: ((Bool) -> Void)?  // arg: ⌘ held (alternate agent)
    var isTextEditing: (() -> Bool)?  // an inline editor owns the keyboard
    var cmdEnterInEditor: (() -> Bool)?  // ⌘↩ inside the quick-prompt bar
    var messageSelected: (() -> Void)?
    var actionKey: ((String) -> Bool)?
    var cycleSort: (() -> Void)?
    var timer: Timer?

    func start() {
        refresh()
        loadSkills()
        startDirWatch()
        startAttentionWatch()
        // hooks push changes through the kqueue watcher, so the timer is only
        // a fallback for what leaves no file event: process death, decay
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.displayAsleep else { return }
            tick += 1
            if (self.panelVisible && tick % 3 == 0) || tick % 12 == 0 { self.refresh() }
        }
        // a sleeping display has nobody to show anything to: stop the poll and
        // the menubar animation until it comes back
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.displayAsleep = true
            appDelegate?.suspendMenubarAnimation()
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.displayAsleep = false
            self?.refresh()
        }
    }

    // kqueue watch on the sessions dir — every record update lands via
    // tmp+mv (a rename), which raises a directory write event
    private var dirWatchFD: Int32 = -1
    private var dirWatchSource: DispatchSourceFileSystemObject?
    private var watchDebounce: DispatchWorkItem?
    private var lastWatchRefresh = Date.distantPast
    // one small append-only file, read directly — no subprocess, no list
    private var attnFD: Int32 = -1
    private var attnSource: DispatchSourceFileSystemObject?
    private var attnOffset: UInt64 = 0
    private var attnPath: String {
        homeDirPath + "/.local/state/claude-session-tracker/attention.jsonl"
    }
    struct AttnEvent: Decodable { let sid: String; let status: String; let title: String }
    private func startAttentionWatch() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: attnPath) { fm.createFile(atPath: attnPath, contents: nil) }
        attnOffset = (try? fm.attributesOfItem(atPath: attnPath)[.size] as? UInt64) as? UInt64 ?? 0
        attnFD = open(attnPath, O_EVTONLY)
        guard attnFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: attnFD, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.drainAttention() }
        let fd = attnFD
        src.setCancelHandler { close(fd) }
        src.resume()
        attnSource = src
    }
    private func drainAttention() {
        guard let h = FileHandle(forReadingAtPath: attnPath) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < attnOffset { attnOffset = 0 }   // truncated
        guard size > attnOffset else { return }
        try? h.seek(toOffset: attnOffset)
        let data = (try? h.readToEnd()) ?? Data()
        attnOffset = size
        // the log grows forever otherwise; it is only ever read forward
        if size > 64_000 {
            try? Data().write(to: URL(fileURLWithPath: attnPath))
            attnOffset = 0
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let e = try? JSONDecoder().decode(AttnEvent.self, from: Data(line.utf8))
            else { continue }
            appDelegate?.notify(sid: e.sid, status: e.status, title: e.title)
        }
    }

    private func startDirWatch() {
        let dir = NSHomeDirectory() + "/.local/state/claude-session-tracker/sessions"
        dirWatchFD = open(dir, O_EVTONLY)
        guard dirWatchFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirWatchFD, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // hook bursts (one write per tool call) collapse into one refresh.
            // With the panel hidden only the menubar badge depends on this, so
            // events coalesce into a much wider window — an agent working
            // through a task writes a record every couple of seconds and each
            // refresh costs a subprocess.
            guard self.panelVisible else { return }
            self.watchDebounce?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.refresh() }
            self.watchDebounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
        let fd = dirWatchFD
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatchSource = src
    }

    var displayAsleep = false
    private var prevStatuses: [String: String] = [:]
    private var firstLoad = true

    func refresh() {
        DispatchQueue.main.async { self.refreshing = true }
        DispatchQueue.global(qos: .utility).async {
            let out = runAST(["sessions-json"], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                self.refreshing = false
                for s in parsed {
                    if let p = self.pendingTitles[s.session_id], p == s.title {
                        self.pendingTitles.removeValue(forKey: s.session_id)
                    }
                    if let p = self.pendingGroups[s.session_id], p == s.group {
                        self.pendingGroups.removeValue(forKey: s.session_id)
                    }
                }
                let merged = self.pendingTitles.isEmpty && self.pendingGroups.isEmpty
                    ? parsed : parsed.map { s -> Session in
                        let t = self.pendingTitles[s.session_id] ?? s.title
                        let g = self.pendingGroups[s.session_id] ?? s.group
                        guard t != s.title || g != s.group else { return s }
                        return Session(
                            session_id: s.session_id, status: s.status, cwd: s.cwd,
                            title: t, message: s.message, updated_at: s.updated_at,
                            bg: s.bg, kind: s.kind, group: g, pin_order: s.pin_order,
                            group_color: s.group_color, group_order: s.group_order,
                            sort_order: s.sort_order, agent: s.agent, model: s.model,
                            parent: s.parent, continuation: s.continuation)
                    }
                let parsed = merged
                if parsed != self.sessions { self.sessions = parsed }
                appDelegate?.updateTitle(sessions: parsed)
                // turn starts still come from here; the banners themselves are
                // driven by the hook's attention log (see startAttentionWatch)
                if !self.firstLoad {
                    for s in parsed where self.prevStatuses[s.session_id] != s.status
                        && s.status == "running" {
                        appDelegate?.runStart[s.session_id] = Date()
                    }
                }
                self.firstLoad = false
                self.prevStatuses = Dictionary(uniqueKeysWithValues: parsed.map { ($0.session_id, $0.status) })
                // drop turn-start timestamps for sessions that no longer exist
                let liveSids = Set(parsed.map { $0.session_id })
                appDelegate?.runStart = appDelegate?.runStart.filter { liveSids.contains($0.key) } ?? [:]
                // once a session leaves an attention state (user answered in
                // the terminal, turn resumed, …) its banner is stale — sweep
                // it out of Notification Center
                let seen = parsed.filter { !["waiting", "finished", "input"].contains($0.status) }
                    .map { $0.session_id }
                if !seen.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: seen)
                }
            }
        }
    }

    struct Skill: Decodable, Equatable {
        let name: String
        let description: String
    }

    @Published var skills: [Skill] = []

    func loadSkills() {
        DispatchQueue.global(qos: .utility).async {
            let out = runAST(["skills-json"], capture: true)
            let parsed = (try? JSONDecoder().decode([Skill].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                if parsed != self.skills { self.skills = parsed }
            }
        }
    }

    @Published var archive: [Session] = []
    @Published var archiveSearching = false
    private var archiveTask: DispatchWorkItem?

    func searchArchive(_ query: String) {
        archiveTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !q.hasPrefix("/") else {
            archive = []
            archiveSearching = false
            return
        }
        archiveSearching = true
        let work = DispatchWorkItem { [weak self] in
            let out = runAST(["archive-search", q], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                self?.archive = parsed
                self?.archiveSearching = false
            }
        }
        archiveTask = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func sendMessage(_ sid: String, _ text: String, viaTerminal: Bool = false) {
        DispatchQueue.global().async { runAST([viaTerminal ? "type-into" : "send", sid, text]) }
    }

    func openAll(_ members: [Session]) {
        DispatchQueue.global().async {
            for s in members {
                runAST(["jump", s.session_id])
                usleep(900_000)
            }
        }
    }

    func groupMove(_ g: String, before: String) {
        DispatchQueue.global().async {
            runAST(["group-move", g, before])
            self.refresh()
        }
    }

    func setGroupColor(_ g: String, _ color: String) {
        DispatchQueue.global().async {
            runAST(["group-color", g, color])
            self.refresh()
        }
    }

    func pinInsert(_ sid: String, before: String) {
        DispatchQueue.global().async {
            runAST(["pin-insert", sid, before])
            self.refresh()
        }
    }

    func orderInsert(_ sid: String, before: String) {
        DispatchQueue.global().async {
            runAST(["order-insert", sid, before])
            self.refresh()
        }
    }

    func jump(_ s: Session) {
        appDelegate?.hidePanel()
        // jumping = the user saw it — clear its alert from Notification Center
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [s.session_id])
        if s.status == "archived" {
            let cwd = s.cwd ?? NSHomeDirectory()
            DispatchQueue.global().async { runAST(["resume-tab", s.session_id, cwd]) }
        } else {
            DispatchQueue.global().async { runAST(["jump", s.session_id]) }
        }
    }

    // name a session from its own transcript — no terminal involved
    func retitle(_ s: Session) {
        showToast("이름 짓는 중…")
        DispatchQueue.global().async {
            let out = runAST(["retitle", s.session_id], capture: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.refresh()
            self.showToast(out.isEmpty ? "이름을 짓지 못함" : "이름: \(out)")
        }
    }

    func copyResume(_ s: Session) {
        DispatchQueue.global().async { runAST(["copy-resume", s.session_id]) }
    }

    // these three all persist through a subprocess and only then refresh, so
    // the row used to sit in its old place for the whole round trip. Patch the
    // published copy first; the refresh that follows corrects anything else.
    // a refresh that started before the edit lands after it and would put the
    // old value back for one beat — keep the local answer until the data
    // catches up
    @Published var pendingTitles: [String: String?] = [:]
    @Published var pendingGroups: [String: String?] = [:]

    private func patchLocal(_ sid: String, group: String?? = nil,
                            title: String?? = nil, pinOrder: Int?? = nil) {
        if let t = title { pendingTitles[sid] = t }
        if let g = group { pendingGroups[sid] = g }
        guard let i = sessions.firstIndex(where: { $0.session_id == sid }) else { return }
        let s = sessions[i]
        sessions[i] = Session(
            session_id: s.session_id, status: s.status, cwd: s.cwd,
            title: title ?? s.title, message: s.message, updated_at: s.updated_at,
            bg: s.bg, kind: s.kind, group: group ?? s.group,
            pin_order: pinOrder ?? s.pin_order, group_color: s.group_color,
            group_order: s.group_order, sort_order: s.sort_order, agent: s.agent,
            model: s.model, parent: s.parent, continuation: s.continuation)
    }

    func assign(_ sid: String, to group: String?) {
        patchLocal(sid, group: .some(group))
        DispatchQueue.global().async {
            runAST(["group", sid, group ?? "-"])
            self.refresh()
        }
    }

    func togglePin(_ sid: String) {
        let pinned = sessions.first { $0.session_id == sid }?.pin_order != nil
        patchLocal(sid, pinOrder: .some(pinned ? nil : 0))
        DispatchQueue.global().async {
            runAST(["pin", sid])
            self.refresh()
        }
    }

    func renameSession(_ sid: String, to name: String) {
        patchLocal(sid, title: .some(name.isEmpty ? nil : name))
        let panelWasUp = panelVisible
        DispatchQueue.global().async {
            runAST(["title", sid, name.isEmpty ? "-" : name])
            self.refresh()
            // the /rename injection can pull the terminal forward; if the user
            // was still in the panel, take focus back here rather than having
            // the shell launch apps to fix it
            if panelWasUp {
                DispatchQueue.main.async {
                    guard self.panelVisible else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    appDelegate?.panel.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    func renameGroup(_ old: String, to new: String) {
        DispatchQueue.global().async {
            runAST(["group-rename", old, new])
            self.refresh()
        }
    }

    func dissolveGroup(_ name: String) {
        DispatchQueue.global().async {
            runAST(["group-dissolve", name])
            self.refresh()
        }
    }

    func stopSession(_ sid: String) {
        DispatchQueue.global().async {
            runAST(["stop-session", sid])
            self.refresh()
        }
    }

    func endSession(_ sid: String) {
        DispatchQueue.global().async {
            runAST(["end", sid])
            self.refresh()
        }
    }

    func clean() {
        DispatchQueue.global().async {
            runAST(["clean"])
            self.refresh()
        }
    }

    // Arc Tidy — auto-group ungrouped sessions. The ai pass calls claude -p,
    // which can take a few seconds; both run off the main thread.
    func tidy(ai: Bool, all: Bool = false) {
        if ai { showToast("AI가 세션 분류 중…") }
        DispatchQueue.global().async {
            var args = ["tidy"]
            if ai { args.append("ai") }
            if all { args.append("all") }
            let out = runAST(args, capture: true)
            self.refresh()
            if out.hasPrefix("no ungrouped") {
                self.showToast("미분류 세션 없음 — 이미 다 정리됨")
            } else if let n = out.split(separator: " ").dropFirst().first {
                self.showToast("세션 \(n)개 그룹화 완료")
            }
        }
    }

    func hub() {
        appDelegate?.hidePanel()
        DispatchQueue.global().async { runAST(["hub"]) }
    }

    // which agent a plain "New Session" opens; the other stays one row away
    @Published var mainAgent: String = UserDefaults.standard.string(forKey: "mainAgent") ?? "claude" {
        didSet { UserDefaults.standard.set(mainAgent, forKey: "mainAgent") }
    }
    var otherAgent: String { mainAgent == "claude" ? "codex" : "claude" }

    // which pixel character fronts the app (menubar + search field)
    @Published var iconChoiceKey = UserDefaults.standard.string(forKey: "menubarAgent") ?? "claude"

    // folder completion used to hit the filesystem from inside a view body:
    // on the first touch of a protected directory macOS raises its consent
    // dialog on the main thread, mid-render, and the panel came apart. The
    // listing now happens off-thread and the view reads this cache.
    @Published var folderDirs: [String: [String]] = [:]
    private var folderLoading: Set<String> = []
    func dirs(under baseExp: String) -> [String] {
        if let cached = folderDirs[baseExp] { return cached }
        guard !folderLoading.contains(baseExp) else { return [] }
        folderLoading.insert(baseExp)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(atPath: baseExp)) ?? []
            let dirs = items.filter { item in
                guard !item.hasPrefix(".") else { return false }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: baseExp + "/" + item, isDirectory: &isDir)
                return isDir.boolValue
            }
            DispatchQueue.main.async {
                self.folderDirs[baseExp] = dirs
                self.folderLoading.remove(baseExp)
            }
        }
        return []
    }
    func invalidateFolderCache() { folderDirs.removeAll() }

    func newSession(in dir: String, agent: String? = nil, prompt: String? = nil) {
        appDelegate?.hidePanel()
        let a = agent ?? mainAgent
        var args = ["new-session", dir, a]
        if let p = prompt, !p.isEmpty { args.append(p) }
        DispatchQueue.global().async { runAST(args) }
    }

    func saveCommand(name: String, command: String) {
        let path = ("~/.local/state/claude-session-tracker/commands.json" as NSString).expandingTildeInPath
        var map = customCommands
        map[name] = command
        if let data = try? JSONSerialization.data(withJSONObject: map,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        objectWillChange.send()
    }

    // user commands from commands.json (name → shell; '@' prefix = silent)
    var customCommands: [String: String] {
        let path = ("~/.local/state/claude-session-tracker/commands.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    func runCommand(_ name: String, arg: String = "", prompt: String = "") {
        appDelegate?.hidePanel()
        DispatchQueue.global().async { runAST(["run-command", name, arg, prompt]) }
    }

    // recent project directories, most recently active first
    var recentDirs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in sessions.sorted(by: { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }) {
            if let c = s.cwd, !c.isEmpty, !seen.contains(c) {
                seen.insert(c)
                out.append(c)
            }
        }
        return Array(out.prefix(8))
    }
}

// Anthropic terracotta
let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
let claudeOrangeNS = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)

// official Claude Code pixel icon (thesvg.org/icon/claude-code, #D97757),
// 24x24 path quantized to a 16x10 dot grid: eye cutouts, side arms, four legs
let mascotMap: [String] = [
    "..oooooooooooo..",
    "..oooooooooooo..",
    "..oo.oooooo.oo..",
    "..oo.oooooo.oo..",
    "oooooooooooooooo",
    "oooooooooooooooo",
    "..oooooooooooo..",
    "..oooooooooooo..",
    "...o.o....o.o...",
    "...o.o....o.o...",
]

// Cells snapped to shared integer edges + antialiasing off — fractional
// cell sizes otherwise leave hairline seams on non-retina/scaled displays.
// quantize a cell size to whole device pixels so every cell is identical —
// per-cell rounding made eyes/legs differ by a pixel
func quantizedPixel(_ pixel: CGFloat, scale: CGFloat) -> CGFloat {
    max(1 / scale, (pixel * scale).rounded() / scale)
}

func drawPixelMap(_ cg: CGContext, map: [String], pixel: CGFloat,
                  colorFor: (Character) -> NSColor?) {
    cg.setShouldAntialias(false)
    for (y, row) in map.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let c = colorFor(ch) else { continue }
            cg.setFillColor(c.cgColor)
            cg.fill(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                           width: pixel, height: pixel))
        }
    }
}

// agent-neutral app icon: a terminal window outline with a >_ prompt —
// the menubar and search field use this; session rows keep agent mascots
let appIconMap: [String] = [
    ".oooooooooooooo.",
    "o..............o",
    "o..............o",
    "o..o...........o",
    "o...o..........o",
    "o..o...........o",
    "o......oooo....o",
    "o..............o",
    "o..............o",
    ".oooooooooooooo.",
]

// icon registry: key → (map, panel tint). claude/codex use their mascots.
// computed, not stored: top-level globals init in source order, and this
// references maps declared later in the file (codexMap segfaulted as let)
var iconChoices: [(key: String, label: String, map: [String], tint: NSColor)] { [
    ("claude", "Claude", mascotMap, claudeOrangeNS),
    ("codex", "Codex", codexMap, NSColor(codexBlue)),
] }
func iconChoice(_ key: String) -> (key: String, label: String, map: [String], tint: NSColor) {
    iconChoices.first { $0.key == key } ?? iconChoices[0]
}

// drop a PNG (static, gets a bounce) or GIF (frame animation) here — the
// "이미지" card appears in the picker when either exists
let customIconPath = ("~/.local/state/claude-session-tracker/icon.png" as NSString).expandingTildeInPath
let customIconGIFPath = ("~/.local/state/claude-session-tracker/icon.gif" as NSString).expandingTildeInPath
var customIconExists: Bool {
    FileManager.default.fileExists(atPath: customIconGIFPath)
        || FileManager.default.fileExists(atPath: customIconPath)
}
// keyed by path+mtime+height: the menubar and the panel ask for different
// sizes, and a single slot made them evict each other — re-decoding every
// frame of the gif on each alternation
var _customIconCache: [String: [NSImage]] = [:]

func resizedIcon(_ img: NSImage, height: CGFloat) -> NSImage {
    let w = img.size.height > 0 ? img.size.width * height / img.size.height : height
    let out = NSImage(size: NSSize(width: w, height: height))
    out.lockFocus()
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: height),
             from: .zero, operation: .sourceOver, fraction: 1)
    out.unlockFocus()
    return out
}

// all frames at the given height: n frames for a GIF, 1 for a PNG, [] if none
func customIconFrames(height: CGFloat) -> [NSImage] {
    let fm = FileManager.default
    let path = fm.fileExists(atPath: customIconGIFPath) ? customIconGIFPath : customIconPath
    guard fm.fileExists(atPath: path) else { return [] }
    let mtime = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
        .timeIntervalSince1970 ?? 0
    let key = "\(path):\(mtime):\(height)"
    if let cached = _customIconCache[key] { return cached }
    var frames: [NSImage] = []
    if let img = NSImage(contentsOfFile: path) {
        if let rep = img.representations.first as? NSBitmapImageRep,
           let n = rep.value(forProperty: .frameCount) as? Int, n > 1 {
            for i in 0..<min(n, 12) {
                rep.setProperty(.currentFrame, withValue: i)
                if let data = rep.representation(using: .png, properties: [:]),
                   let f = NSImage(data: data) {
                    frames.append(resizedIcon(f, height: height))
                }
            }
        } else {
            frames = [resizedIcon(img, height: height)]
        }
    }
    if _customIconCache.count > 6 { _customIconCache.removeAll() }
    _customIconCache[key] = frames
    return frames
}

func customIconImage(height: CGFloat) -> NSImage? { customIconFrames(height: height).first }

// any emoji as the icon — rendered into an NSImage for the menubar
var savedEmojiIcon: String {
    UserDefaults.standard.string(forKey: "menubarEmoji") ?? ""
}
func emojiNSImage(_ emoji: String, height: CGFloat) -> NSImage {
    let size = NSSize(width: height + 2, height: height + 2)
    let out = NSImage(size: size)
    out.lockFocus()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: height * 0.86)]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let b = str.size()
    str.draw(at: NSPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2))
    out.unlockFocus()
    return out
}

// card-grid icon picker shown under the status item on right-click
struct IconPickerView: View {
    let current: String
    let onPick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("아이콘")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.4)
            let choices = iconChoices
                + (customIconExists ? [("custom", "이미지", appIconMap, NSColor.clear)] : [])
                + (savedEmojiIcon.isEmpty ? [] : [("emoji", "이모지", appIconMap, NSColor.clear)])
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(66), spacing: 8), count: 4),
                      spacing: 8) {
                ForEach(choices, id: \.key) { c in
                    let selected = current == c.key
                    VStack(spacing: 5) {
                        PixelAppIcon(choice: c.key, pixel: 2.4)
                        Text(c.label)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .frame(width: 66, height: 58)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? claudeOrange.opacity(0.22) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? claudeOrange.opacity(0.8) : Color.clear, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                    .onTapGesture { onPick(c.key) }
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                Spacer()
                Button {
                    appDelegate?.showSettings()
                } label: {
                    Label("설정…", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12)))
    }
}

// dedicated settings window: hotkeys + general toggles
struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var panelHK = appDelegate?.currentHotkeyLabel() ?? "⌥Space"
    @State private var attnHK = appDelegate?.currentAttentionLabel() ?? "⌘⌥A"
    @State private var recording: String? = nil  // "panel" | "attn"
    @AppStorage("defaultTerminal") private var defaultTerminal = ""
    @AppStorage("notifyWaiting") private var notifyWaiting = true
    @AppStorage("notifyInput") private var notifyInput = true
    @AppStorage("notifyFinished") private var notifyFinished = true
    @AppStorage("notifySound") private var notifySound = true
    @AppStorage("menubarAnimation") private var menubarAnimation = "attention"

    @State private var panelKeyLabels: [String: String] = [:]

    func hotkeyButton(_ id: String, _ label: String, apply: @escaping (Int, Int) -> Void,
                      refresh: @escaping () -> String) -> some View {
        Button {
            recording = id
            appDelegate?.beginKeyCapture { k, m in
                if k >= 0 { apply(k, m) }
                switch id {
                case "panel": panelHK = refresh()
                case "attn": attnHK = refresh()
                default: panelKeyLabels[id] = refresh()
                }
                recording = nil
            }
        } label: {
            Text(recording == id ? "새 조합을 누르세요… (Esc 취소)" : label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(recording == id ? claudeOrange.opacity(0.25) : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    @State private var tab = "general"

    private let tabs: [(id: String, label: String, icon: String)] = [
        ("general", "일반", "gearshape.fill"),
        ("hotkeys", "단축키", "command"),
        ("notifications", "알림", "bell.badge.fill"),
        ("about", "정보", "info.circle.fill"),
    ]

    // System Settings-style toolbar tab: icon over label, tinted when active
    private func tabButton(_ t: (id: String, label: String, icon: String)) -> some View {
        let active = tab == t.id
        return Button {
            tab = t.id
        } label: {
            VStack(spacing: 3) {
                Image(systemName: t.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 17)
                Text(t.label)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
            }
            .frame(width: 58, height: 44)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.accentColor.opacity(0.13) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.id) { tabButton($0) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            Group {
                switch tab {
                case "hotkeys":
                    Form {
                        Section("전역 단축키") {
                            LabeledContent("패널 열기/닫기") {
                                hotkeyButton("panel", panelHK,
                                             apply: { appDelegate?.setHotkey(keyCode: $0, carbonMods: $1) },
                                             refresh: { appDelegate?.currentHotkeyLabel() ?? "" })
                            }
                            LabeledContent("어텐션 세션으로 점프") {
                                hotkeyButton("attn", attnHK,
                                             apply: { appDelegate?.setAttentionHotkey(keyCode: $0, carbonMods: $1) },
                                             refresh: { appDelegate?.currentAttentionLabel() ?? "" })
                            }
                        }
                        Section("패널 안 — 변경 가능") {
                            ForEach(AppDelegate.panelActions, id: \.id) { a in
                                LabeledContent(a.label) {
                                    hotkeyButton(a.id,
                                                 panelKeyLabels[a.id]
                                                     ?? appDelegate?.panelBindingLabel(a.id) ?? "",
                                                 apply: { appDelegate?.setPanelBinding(a.id, keyCode: $0, carbonMods: $1) },
                                                 refresh: { appDelegate?.panelBindingLabel(a.id) ?? "" })
                                }
                            }
                        }
                        Section("패널 안 — 고정") {
                            keyRow("↩ / ⌘1–9", "세션 점프 · ⌘↩ 대체 동작")
                            keyRow("↑↓ / ←→", "이동 · 그룹 칩 전환")
                            keyRow("Tab", "퀵 프롬프트 · 커맨드 자동완성")
                            keyRow("/ · Esc", "스킬 팔레트 · 닫기")
                        }
                    }
                    .formStyle(.grouped)
                case "notifications":
                    Form {
                        Section {
                            Toggle("승인 필요 (Needs approval)", isOn: $notifyWaiting)
                            Toggle("답변 대기 (Waiting for reply)", isOn: $notifyInput)
                            Toggle("작업 완료 (Finished)", isOn: $notifyFinished)
                            Toggle("알림 소리", isOn: $notifySound)
                        } footer: {
                            Text("알림을 클릭하면 해당 세션의 터미널로 점프합니다. 세션을 확인하면 남은 배너는 자동으로 지워집니다.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                case "about":
                    VStack(spacing: 10) {
                        Spacer()
                        if let icon = NSApp.applicationIconImage {
                            Image(nsImage: icon)
                                .resizable().frame(width: 76, height: 76)
                        }
                        Text("Agents Session Tracker")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("v\(appVersion) · Claude Code & Codex 세션 트래커")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Link("GitHub", destination:
                                URL(string: "https://github.com/cms5380/agents-session-tracker")!)
                            Text("·").foregroundStyle(.secondary)
                            Text("brew install cms5380/tap/agents-session-tracker")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11.5))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                default:
                    Form {
                        Section("새 세션") {
                            Picker("기본 에이전트", selection: $model.mainAgent) {
                                Text("claude").tag("claude")
                                Text("codex").tag("codex")
                            }
                            .pickerStyle(.segmented)
                            Picker("메뉴바 애니메이션", selection: $menubarAnimation) {
                                Text("어텐션만").tag("attention")
                                Text("항상").tag("always")
                                Text("끄기").tag("off")
                            }
                            .pickerStyle(.segmented)
                            Picker("기본 터미널", selection: $defaultTerminal) {
                                Text("자동").tag("")
                                Text("iTerm2").tag("iterm")
                                Text("Terminal").tag("terminal")
                                Text("Ghostty").tag("ghostty")
                            }
                            .pickerStyle(.segmented)
                        }
                        Section {
                            LabeledContent("메뉴바 아이콘") {
                                Text("메뉴바 아이콘 우클릭으로 변경")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 440, height: 360)
    }

    private func keyRow(_ keys: String, _ desc: String) -> some View {
        LabeledContent {
            Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
        } label: {
            Text(keys)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
    }
}

struct PixelAppIcon: View {
    var choice: String = "claude"
    var pixel: CGFloat = 3
    // a ticking TimelineView in an ordered-out window still lays the whole
    // view tree out every frame — hold a still image while the panel is hidden
    var animate: Bool = true
    @Environment(\.displayScale) private var scale
    var body: some View {
        let px = quantizedPixel(pixel, scale: scale)
        if choice == "codex" {
            CodexLogoIcon().frame(width: px * 10, height: px * 10)
        } else if choice == "emoji", !savedEmojiIcon.isEmpty {
            Text(savedEmojiIcon)
                .font(.system(size: px * 9))
                .frame(height: px * 10)
        } else if choice == "custom", !customIconFrames(height: px * 10).isEmpty {
            let frames = customIconFrames(height: px * 10)
            if frames.count > 1, animate {
                TimelineView(.periodic(from: .now, by: 0.12)) { tl in
                    let i = Int(tl.date.timeIntervalSince1970 / 0.12) % frames.count
                    Image(nsImage: frames[i])
                }
                .frame(height: px * 10)
            } else {
                Image(nsImage: frames[0]).frame(height: px * 10)
            }
        } else {
            let c = iconChoice(choice)
            Canvas { ctx, _ in
                ctx.withCGContext { cg in
                    drawPixelMap(cg, map: c.map, pixel: px) {
                        $0 == "o" ? c.tint : ($0 == "w" ? .white : nil)
                    }
                }
            }
            .frame(width: px * 16, height: px * 10)
        }
    }
}

struct PixelMascot: View {
    var pixel: CGFloat = 3
    @Environment(\.displayScale) private var scale
    var body: some View {
        let px = quantizedPixel(pixel, scale: scale)
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                drawPixelMap(cg, map: mascotMap, pixel: px) { $0 == "o" ? claudeOrangeNS : nil }
            }
        }
        .frame(width: px * 16, height: px * 10)
    }
}

func mascotNSImage(map: [String], pixel: CGFloat) -> NSImage {
    let px = quantizedPixel(pixel, scale: 2)
    let size = NSSize(width: px * 16, height: px * CGFloat(map.count))
    let img = NSImage(size: size)
    img.lockFocus()
    if let cg = NSGraphicsContext.current?.cgContext {
        cg.setShouldAntialias(false)
        // template image — the menubar tints it like every other icon
        cg.setFillColor(NSColor.black.cgColor)
        // "w" cells are knocked out (transparent) — a monochrome template
        // can't show the white >_ any other way
        for (y, row) in map.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." && ch != "w" {
                cg.fill(CGRect(x: CGFloat(x) * px,
                               y: size.height - CGFloat(y + 1) * px,
                               width: px, height: px))
            }
        }
    }
    img.unlockFocus()
    img.isTemplate = true
    return img
}

// ── animated status mascots ──────────────────────────────────────
// Each status is the mascot itself doing a motion, as 11-row pixel
// frames (row 0 = effect/headroom row, rows 1-10 = body).
// chars: o=body  != orange alert  z=gray z  -=closed eye

func mascotBody(eyes: String, legs: String, armsUp: Bool = false) -> [String] {
    // eyes: "open" | "sleepy" | "closed", legs: "a" | "b" | "tuck"
    let eyeRowOpen = "..oo.oooooo.oo.."
    let eyeRowSolid = "..oooooooooooo.."
    let eyeRowClosed = "..oo-oooooo-oo.."
    let (e1, e2): (String, String)
    switch eyes {
    case "sleepy": (e1, e2) = (eyeRowSolid, eyeRowOpen)
    case "closed": (e1, e2) = (eyeRowSolid, eyeRowClosed)
    default: (e1, e2) = (eyeRowOpen, eyeRowOpen)
    }
    let legRow: String
    switch legs {
    case "b": legRow = "..o...o..o...o.."
    case "tuck": legRow = "....o.o..o.o...."
    default: legRow = "...o.o....o.o..."
    }
    if armsUp {
        return [
            "oooooooooooooooo",
            "oooooooooooooooo",
            e1,
            e2,
            "..oooooooooooo..",
            "..oooooooooooo..",
            "..oooooooooooo..",
            "..oooooooooooo..",
            legRow,
            legRow,
        ]
    }
    return [
        "..oooooooooooo..",
        "..oooooooooooo..",
        e1,
        e2,
        "oooooooooooooooo",
        "oooooooooooooooo",
        "..oooooooooooo..",
        "..oooooooooooo..",
        legRow,
        legRow,
    ]
}

func mascotFrames(_ status: String) -> (frames: [[String]], interval: Double, tint: Color) {
    let empty = String(repeating: ".", count: 16)
    switch status {
    case "running":
        // bounce: body alternates one row up/down while legs alternate
        let f1 = [empty] + mascotBody(eyes: "open", legs: "a")
        let f2 = mascotBody(eyes: "open", legs: "b") + [empty]
        return ([f1, f2], 0.22, claudeOrange)
    case "waiting":
        // blinking !! overhead, feet fidgeting
        let alert = ".......!!......."
        let f1 = [alert] + mascotBody(eyes: "open", legs: "a")
        let f2 = [empty] + mascotBody(eyes: "open", legs: "tuck")
        return ([f1, f2], 0.4, claudeOrange)
    case "input":
        // blue ?? blink — Claude replied and awaits your answer
        let q = ".......??......."
        let f1 = [q] + mascotBody(eyes: "open", legs: "a")
        let f2 = [empty] + mascotBody(eyes: "open", legs: "a")
        return ([f1, f2], 0.6, claudeOrange)
    case "finished":
        // arms-up cheer with green sparks — result ready for review
        let sparks = ".g............g."
        let f1 = [sparks] + mascotBody(eyes: "open", legs: "tuck", armsUp: true)
        let f2 = [empty] + mascotBody(eyes: "open", legs: "a")
        return ([f1, f2], 0.45, claudeOrange)
    case "gone":
        let f = [empty] + mascotBody(eyes: "closed", legs: "tuck")
        return ([f], 1, claudeOrange.opacity(0.55))
    default: // idle — sleepy eyes, drifting z
        let z1 = "..............z."
        let z2 = ".............z.."
        let f1 = [z1] + mascotBody(eyes: "sleepy", legs: "a")
        let f2 = [z2] + mascotBody(eyes: "sleepy", legs: "a")
        return ([f1, f2], 1.0, claudeOrange.opacity(0.85))
    }
}

// ── codex mascot ─────────────────────────────────────────────────
// the Codex logo as a pixel circle with a white >_ prompt inside
let codexBlue = Color(red: 0.42, green: 0.42, blue: 0.93)
let codexMap: [String] = [
    "......oooo......",
    ".....oooooo.....",
    "....oooooooo....",
    "...owwooooooo...",
    "...oowwoooooo...",
    "...owwooooooo...",
    "...oooowwwwoo...",
    "....oooooooo....",
    ".....oooooo.....",
    "......oooo......",
]

// vector rendition of the Codex logo: gradient flower blob + white >_
// (crisp at any size, transparent background)
struct CodexLogoIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var blob = Path()
            let R = s * 0.30
            blob.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let px = c.x + cos(a) * s * 0.22
                let py = c.y + sin(a) * s * 0.22
                let r = s * 0.21
                blob.addEllipse(in: CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r))
            }
            ctx.fill(blob, with: .linearGradient(
                Gradient(colors: [Color(red: 0.57, green: 0.55, blue: 0.98),
                                  Color(red: 0.22, green: 0.22, blue: 0.94)]),
                startPoint: CGPoint(x: c.x, y: c.y - s * 0.5),
                endPoint: CGPoint(x: c.x, y: c.y + s * 0.5)))
            let stroke = StrokeStyle(lineWidth: s * 0.08, lineCap: .round, lineJoin: .round)
            var ch = Path()
            ch.move(to: CGPoint(x: c.x - s * 0.17, y: c.y - s * 0.13))
            ch.addLine(to: CGPoint(x: c.x - s * 0.05, y: c.y))
            ch.addLine(to: CGPoint(x: c.x - s * 0.17, y: c.y + s * 0.13))
            ctx.stroke(ch, with: .color(.white), style: stroke)
            var us = Path()
            us.move(to: CGPoint(x: c.x + 0.03 * s, y: c.y + s * 0.13))
            us.addLine(to: CGPoint(x: c.x + 0.19 * s, y: c.y + s * 0.13))
            ctx.stroke(us, with: .color(.white), style: stroke)
        }
    }
}

// AppKit twin of CodexLogoIcon for menubar NSImages (no SwiftUI renderer —
// ImageRenderer is main-actor-isolated and this must stay callable anywhere)
func codexLogoNSImage(size s: CGFloat) -> NSImage {
    let out = NSImage(size: NSSize(width: s, height: s))
    out.lockFocus()
    if let cg = NSGraphicsContext.current?.cgContext {
        let c = CGPoint(x: s / 2, y: s / 2)
        let path = CGMutablePath()
        let R = s * 0.30
        path.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let r = s * 0.21
            path.addEllipse(in: CGRect(x: c.x + cos(a) * s * 0.22 - r,
                                       y: c.y + sin(a) * s * 0.22 - r,
                                       width: 2 * r, height: 2 * r))
        }
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let colors = [NSColor(red: 0.22, green: 0.22, blue: 0.94, alpha: 1).cgColor,
                      NSColor(red: 0.57, green: 0.55, blue: 0.98, alpha: 1).cgColor]
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
            cg.drawLinearGradient(grad, start: CGPoint(x: c.x, y: 0),
                                  end: CGPoint(x: c.x, y: s), options: [])
        }
        cg.restoreGState()
        cg.setStrokeColor(.white)
        cg.setLineWidth(s * 0.08)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.beginPath()
        cg.move(to: CGPoint(x: c.x - s * 0.17, y: c.y + s * 0.13))
        cg.addLine(to: CGPoint(x: c.x - s * 0.05, y: c.y))
        cg.addLine(to: CGPoint(x: c.x - s * 0.17, y: c.y - s * 0.13))
        cg.strokePath()
        cg.beginPath()
        cg.move(to: CGPoint(x: c.x + 0.03 * s, y: c.y - s * 0.13))
        cg.addLine(to: CGPoint(x: c.x + 0.19 * s, y: c.y - s * 0.13))
        cg.strokePath()
    }
    out.unlockFocus()
    return out
}

// image-based codex row mascot: bounce while running, badges for asks
struct CodexMascot: View {
    let status: String
    var animate: Bool = true
    var body: some View {
        let dim: Double = status == "gone" ? 0.45 : status == "done" ? 0.8 : 1
        ZStack(alignment: .topTrailing) {
            Group {
                if animate && status == "running" {
                    TimelineView(.periodic(from: .now, by: 0.35)) { tl in
                        let up = Int(tl.date.timeIntervalSince1970 / 0.35) % 2 == 0
                        CodexLogoIcon().frame(width: 17, height: 17)
                            .offset(y: up ? -1.5 : 1.5)
                    }
                } else {
                    CodexLogoIcon().frame(width: 17, height: 17)
                }
            }
            .opacity(dim)
            switch status {
            case "waiting": mascotBadge("!!", .orange)
            case "input": mascotBadge("??", .blue)
            case "finished": mascotBadge("✓", .green)
            default: EmptyView()
            }
        }
        .frame(width: 24, height: 18)
    }

    func mascotBadge(_ t: String, _ c: Color) -> some View {
        Text(t)
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(c)
            .offset(x: 2, y: -3)
    }
}

func codexFrames(_ status: String) -> (frames: [[String]], interval: Double, tint: Color) {
    let empty = String(repeating: ".", count: 16)
    let body = codexMap
    switch status {
    case "running": // the blob bounces like the claude mascot does
        return ([[empty] + body, body + [empty]], 0.35, codexBlue)
    case "waiting":
        let alert = ".......!!......."
        return ([[alert] + body, [empty] + body], 0.4, codexBlue)
    case "input":
        let q = ".......??......."
        return ([[q] + body, [empty] + body], 0.6, codexBlue)
    case "finished":
        let sparks = ".g............g."
        return ([[sparks] + body, [empty] + body], 0.45, codexBlue)
    case "gone":
        return ([[empty] + body], 1, codexBlue.opacity(0.55))
    default:
        return ([[empty] + body], 1, codexBlue.opacity(0.85))
    }
}

struct StatusMascot: View {
    let status: String
    var agent: String = "claude"
    var animate: Bool = true
    var pixel: CGFloat = 1.5

    var body: some View {
        let spec = agent == "codex" ? codexFrames(status) : mascotFrames(status)
        // panel hidden → render a static frame; a ticking TimelineView in an
        // ordered-out window still burns CPU
        if !animate {
            frameView(spec.frames[0], tint: spec.tint)
        } else {
            TimelineView(.periodic(from: .now, by: spec.interval)) { timeline in
                let idx = spec.frames.count > 1
                    ? Int(timeline.date.timeIntervalSince1970 / spec.interval) % spec.frames.count
                    : 0
                frameView(spec.frames[idx], tint: spec.tint)
            }
        }
    }

    @Environment(\.displayScale) private var scale

    func frameView(_ frame: [String], tint: Color) -> some View {
        let px = quantizedPixel(pixel, scale: scale)
        return Canvas { ctx, _ in
            ctx.withCGContext { cg in
                drawPixelMap(cg, map: frame, pixel: px) { ch in
                    switch ch {
                    case "o": return NSColor(tint)
                    case "w": return .white
                    case "g": return .systemGreen
                    case "?": return .systemBlue
                    case "!": return .systemOrange
                    case "z": return .systemGray
                    case "-": return NSColor(red: 0.45, green: 0.2, blue: 0.13, alpha: 1)
                    default: return nil
                    }
                }
            }
        }
        .frame(width: px * 16, height: px * 11)
    }
}

@ViewBuilder
func statusGlyph(_ status: String, agent: String = "claude", animate: Bool = true) -> some View {
    if agent == "codex" {
        CodexMascot(status: status, animate: animate)
    } else {
        StatusMascot(status: status, agent: agent, animate: animate)
    }
}

func statusColor(_ status: String) -> Color {
    switch status {
    case "waiting": return Color(nsColor: .systemOrange)
    case "input": return Color(nsColor: .systemBlue)
    case "running": return Color(nsColor: .systemGreen)
    case "finished": return Color(nsColor: .systemTeal)
    case "gone": return Color(nsColor: .systemGray).opacity(0.5)
    default: return Color(nsColor: .systemGray)
    }
}

// the age capsule sits on the row's own grey background, so the grey status
// colours washed out — idle and ended rows borrow the label colour instead
func ageTint(_ status: String) -> (fg: Color, bg: Color) {
    switch status {
    case "waiting", "input", "running", "finished":
        return (statusColor(status).opacity(0.9), statusColor(status).opacity(0.13))
    default:
        return (Color.secondary, Color.primary.opacity(0.09))
    }
}

// "claude-opus-5" → "opus 5", "gpt-5.6-sol" → "gpt-5.6", "claude-haiku-4-5-…" → "haiku 4.5"
func shortModel(_ model: String?) -> String {
    guard var m = model, !m.isEmpty, !m.hasPrefix("<") else { return "" }
    if m.hasPrefix("claude-") { m = String(m.dropFirst(7)) }
    let parts = m.split(separator: "-").map(String.init)
    guard let name = parts.first else { return m }
    let nums = parts.dropFirst().prefix(while: { $0.allSatisfy { $0.isNumber || $0 == "." } })
    if name.hasPrefix("gpt") { return nums.isEmpty ? name : "\(name)-\(nums.first!)" }
    return nums.isEmpty ? name : "\(name) \(nums.joined(separator: "."))"
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
    var hotkeyNumber: Int? = nil
    var animate: Bool = true
    var isRenaming: Bool = false
    var isStopping: Bool = false
    var insertLine: Bool = false
    var dropHighlight: Bool = false
    var onDragBegin: (() -> Void)? = nil
    var onRename: ((Session) -> Void)? = nil
    var onMessage: ((Session) -> Void)? = nil
    var renameCommit: ((String) -> Void)? = nil
    var renameCancel: (() -> Void)? = nil
    @State private var hovering = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var name: String {
        s.title ?? ((s.cwd ?? "?") as NSString).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
        // insertion indicator while another session is dragged over this row
        Rectangle()
            .fill(insertLine ? claudeOrange : Color.clear)
            .frame(height: 2)
            .cornerRadius(1)
            .padding(.horizontal, 6)
            .padding(.bottom, insertLine ? 3 : 0)
        HStack(spacing: 9) {
            if let n = hotkeyNumber {
                Text("⌘\(n)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .frame(width: 24, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                    .help("⌘\(n)")
            }
            statusGlyph(isStopping ? "done" : s.status, agent: s.agent ?? "claude", animate: animate)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("session name (empty = auto)", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .focused($renameFocused)
                        .onAppear {
                            renameDraft = s.title ?? ""
                            renameFocused = true
                        }
                        .onSubmit { renameCommit?(renameDraft.trimmingCharacters(in: .whitespaces)) }
                        .onExitCommand { renameCancel?() }
                        .onChange(of: renameFocused) { focused in
                            // clicking away commits instead of leaving the
                            // field stuck open
                            if !focused && isRenaming {
                                renameCommit?(renameDraft.trimmingCharacters(in: .whitespaces))
                            }
                        }
                } else {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    let modelTag = shortModel(s.model)
                    if !modelTag.isEmpty {
                        Text(modelTag)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
                    }
                    // fork lineage rides in the meta line instead of nesting
                    if let p = s.parent,
                       let pt = model.sessions.first(where: { $0.session_id == p }) {
                        Text("⑂ \((pt.title ?? "부모").prefix(12))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text((s.cwd ?? "").replacingOccurrences(of: homeDirPath, with: "~"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if s.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(claudeOrange.opacity(0.7))
            }
            if isStopping {
                Text("중지됨 · ⌃X 한번 더 = 종료")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .systemGray).opacity(0.18)))
                    .foregroundStyle(.secondary)
            } else if s.status != "running", !ageString(s.updated_at).isEmpty {
                // running rows skip the age capsule — it reflects the last
                // hook event, which reads oddly mid-turn ("running · 41m")
                let tint = ageTint(s.status)
                Text(ageString(s.updated_at))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(tint.bg))
                    .foregroundStyle(tint.fg)
            }
            if hovering {
                if s.status != "archived", onMessage != nil {
                    Button {
                        onMessage?(s)
                    } label: {
                        Image(systemName: "paperplane")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Send message (Tab)")
                }
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(dropHighlight ? claudeOrange.opacity(0.16)
                    : isSelected ? claudeOrange.opacity(0.25)
                    : hovering ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .onDrag {
            onDragBegin?()
            return NSItemProvider(object: s.session_id as NSString)
        }
        .onTapGesture { model.jump(s) }
        .contextMenu {
            Button("Jump  ↩") { model.jump(s) }
            if s.status != "archived" {
                Button("\(s.pinned ? "Unpin" : "Pin to top")  ⌃P") { model.togglePin(s.session_id) }
                Button("Send message…  ⇥") { onMessage?(s) }
                Button("Rename session  ⌃R") { onRename?(s) }
            }
            Button("Copy resume command  ⌃C") { model.copyResume(s) }
            if s.group != nil {
                Button("Remove from group  ⌃⌫") { model.assign(s.session_id, to: nil) }
            }
            if s.status == "gone" {
                Divider()
                Button("Remove from list  ⌃X") { model.endSession(s.session_id) }
            } else if s.kind == "background" || s.kind == "interactive" {
                Divider()
                Button("Stop  ⌃X") { model.stopSession(s.session_id) }
            }
        }
        .help(s.message ?? s.cwd ?? "")
        }
    }
}

enum PanelRow: Identifiable, Equatable {
    case label(String)      // section label (PINNED / ATTENTION)
    case header(String)     // group name, or "__ungrouped__"
    case session(Session, indented: Bool)
    case command(String, String, String) // id, title, subtitle
    case dropzone(String)   // transient drop target (e.g. pin-to-end)

    var id: String {
        switch self {
        case .label(let s): return "lbl-\(s)"
        case .header(let g): return "hdr-\(g)"
        case .session(let s, _): return s.session_id
        case .command(let id, _, _): return "cmd-\(id)"
        case .dropzone(let s): return "dz-\(s)"
        }
    }

    var selectable: Bool {
        switch self {
        case .label, .dropzone: return false
        default: return true
        }
    }
}

struct PixelGlyph: View {
    let map: [String]
    let color: Color
    var pixel: CGFloat = 2
    @Environment(\.displayScale) private var scale
    var body: some View {
        let px = quantizedPixel(pixel, scale: scale)
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                drawPixelMap(cg, map: map, pixel: px) { $0 == "o" ? NSColor(color) : nil }
            }
        }
        .frame(width: px * CGFloat(map.first?.count ?? 8),
               height: px * CGFloat(map.count))
    }
}

// group icons: a duo of mini mascots; ungrouped gets a lone one
let duoMap: [String] = [
    ".oooooo..oooooo.",
    ".o.oo.o..o.oo.o.",
    ".oooooo..oooooo.",
    "..o..o....o..o..",
]
let soloMap: [String] = [
    ".....oooooo.....",
    ".....o.oo.o.....",
    ".....oooooo.....",
    "......o..o......",
]

struct GroupHeaderRow: View {
    let name: String
    let count: Int
    let hasAttention: Bool
    let expanded: Bool
    let isSelected: Bool
    let highlight: Bool
    var insertLine: Bool = false
    var hotkeyNumber: Int? = nil
    var tint: Color = claudeOrange
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
        // insertion indicator while a group card is being dragged
        Rectangle()
            .fill(insertLine ? claudeOrange : Color.clear)
            .frame(height: 2)
            .cornerRadius(1)
            .padding(.horizontal, 6)
            .padding(.bottom, insertLine ? 3 : 0)
        HStack(spacing: 7) {
            if let n = hotkeyNumber {
                Text("⌘\(n)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .frame(width: 24, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                    .help("⌘\(n)")
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            PixelGlyph(map: name == "__ungrouped__" ? soloMap : duoMap,
                       color: name == "__ungrouped__" ? tint.opacity(0.8) : tint,
                       pixel: 1.5)
            Text(name == "__ungrouped__" ? "미배정" : name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                .fill(isSelected ? claudeOrange.opacity(0.25)
                    : highlight ? claudeOrange.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(highlight ? claudeOrange.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: toggle)
        }
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
    @State private var messagingSession: Session? = nil
    @State private var editingCommand = false
    @State private var cmdDraftName = ""
    @State private var cmdDraftBody = ""
    @FocusState private var cmdNameFocused: Bool
    @State private var messageText = ""
    @State private var dropTarget: String? = nil
    @State private var draggingGroup: String? = nil
    @State private var stoppingSids: Set<String> = []
    @State private var endingSids: Set<String> = []
    @State private var followSid: String? = nil
    @State private var lastSessionSid: String? = nil
    @State private var sessionDropTarget: String? = nil
    @State private var draggingSessionSid: String? = nil
    private let groupLayout = "chips" // chips is the one true layout

    // temporary sort axis (⌘S cycles, resets when the panel closes) — the
    // stable default is what the list is designed around; the others are for
    // a quick "show me by …" glance
    enum SortMode: String, CaseIterable {
        case standard, recent, status, folder, name
        var label: String {
            switch self {
            case .standard: return "기본"
            case .recent: return "최근순"
            case .status: return "상태별"
            case .folder: return "폴더별"
            case .name: return "이름순"
            }
        }
        var next: SortMode {
            let all = SortMode.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }
    // the chosen axis sticks across panel opens and restarts
    @AppStorage("panelSortMode") private var sortModeRaw = SortMode.standard.rawValue
    var sortMode: SortMode {
        get { SortMode(rawValue: sortModeRaw) ?? .standard }
        nonmutating set { sortModeRaw = newValue.rawValue }
    }

    // a running session is active now, whatever its last recorded event says —
    // the daemon can report busy long after the last hook fired
    func recencyTime(_ s: Session) -> Double {
        s.status == "running" ? Date().timeIntervalSince1970 : Double(s.updated_at ?? 0)
    }

    // section heading for the active sort axis (nil = no sections)
    func sortSectionKey(_ s: Session) -> String? {
        switch sortMode {
        case .standard, .name: return nil
        case .recent:
            // day buckets read better than a flat stream of timestamps
            let cal = Calendar.current
            let d = Date(timeIntervalSince1970: TimeInterval(recencyTime(s)))
            if cal.isDateInToday(d) { return "오늘" }
            if cal.isDateInYesterday(d) { return "어제" }
            let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 99
            return days <= 7 ? "지난 7일" : "그 이전"
        case .status:
            switch s.status {
            case "running": return "실행 중"
            case "gone": return "종료됨"
            default: return "유휴"
            }
        case .folder:
            let f = ((s.cwd ?? "") as NSString).lastPathComponent
            return f.isEmpty ? "기타" : f
        }
    }
    @State private var selectedChip: String? = nil
    @State private var pendingGroups: [String] = []
    @State private var expanded: Set<String> = []
    @State private var selected = 0
    @State private var scrollTarget: String? = nil
    @FocusState private var searchFocused: Bool
    @FocusState private var msgFocused: Bool

    // sessions with an optimistic idle override for in-flight stops, so a
    // stopped row moves to its final place (pin/group) immediately
    var viewSessions: [Session] {
        model.sessions.filter { !endingSids.contains($0.session_id) }.map { s in
            guard stoppingSids.contains(s.session_id), s.status == "running" else { return s }
            return Session(session_id: s.session_id, status: "done", cwd: s.cwd,
                           title: s.title, message: s.message, updated_at: s.updated_at,
                           bg: s.bg, kind: s.kind, group: s.group, pin_order: s.pin_order,
                           group_color: s.group_color, group_order: s.group_order,
                           sort_order: s.sort_order, agent: s.agent, model: s.model,
                           parent: s.parent, continuation: s.continuation)
        }
    }

    // the trimmed/lowercased query is read several times per render — trim once
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var filtered: [Session] {
        let q = trimmedQuery.lowercased()
        if q.isEmpty { return viewSessions }
        return viewSessions.filter {
            ($0.title ?? "").lowercased().contains(q)
                || ($0.cwd ?? "").lowercased().contains(q)
                || ($0.group ?? "").lowercased().contains(q)
        }
    }

    var searching: Bool { !trimmedQuery.isEmpty }

    // "/" mode: list Claude skills, pick one → pre-filled quick prompt
    var skillQuery: String? {
        guard query.hasPrefix("/") else { return nil }
        let body = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        return body.split(separator: " ", maxSplits: 1,
                          omittingEmptySubsequences: false).first.map {
            String($0).lowercased()
        } ?? ""
    }

    // everything typed after the skill name — "/review 이 PR 봐줘" carries
    // "이 PR 봐줘" into the new session along with the command
    var skillArg: String {
        guard query.hasPrefix("/") else { return "" }
        let body = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    }

    var skillRows: [PanelRow] {
        guard let q = skillQuery else { return [] }
        let list = q.isEmpty ? model.skills
            : model.skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        let near = viewSessions.first(where: { $0.session_id == lastSessionSid })
            ?? attention.first ?? viewSessions.first
        let dir = (near?.cwd ?? model.recentDirs.first ?? NSHomeDirectory())
            .replacingOccurrences(of: homeDirPath, with: "~")
        let arg = skillArg
        return list.prefix(12).map {
            .command("skill:\($0.name)",
                     arg.isEmpty ? "/\($0.name)" : "/\($0.name) \(arg)",
                     "새 세션 · \(dir)" + ($0.description.isEmpty ? "" : " — \($0.description)"))
        }
    }

    // Raycast-style: typing matches commands right alongside sessions
    var commandRows: [PanelRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard searching, !q.isEmpty, !query.hasPrefix("/") else { return [] }
        var cmds: [(String, String, String)] = [
            ("clean", "Clean Stale Sessions", "오래된 세션 정리"),
            ("tidy", "Tidy: Group by Repo", "미분류를 저장소/폴더별 그룹 · ⌘↩ 전체 재그룹"),
            ("tidy-ai", "Tidy: Group by Topic (AI)", "claude가 주제별 그룹명 생성 · ⌘↩ 전체 재그룹"),
            ("quit", "Quit Claude Sessions", "앱 종료"),
            ("agent-toggle", "Main Agent: \(model.mainAgent) → \(model.otherAgent)",
             "새 세션 기본 에이전트 전환"),
        ]
        for dir in model.recentDirs {
            let name = (dir as NSString).lastPathComponent
            let path = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            cmds.append(("new:\(dir)", "New Session: \(name)",
                         "↩ \(model.mainAgent) · ⌘↩ \(model.otherAgent) · \(path)"))
        }
        for (name, cmd) in model.customCommands.sorted(by: { $0.key < $1.key }) {
            let silent = cmd.hasPrefix("@")
            cmds.append(("custom:\(name)", name,
                         (silent ? "⚙︎ " : "⌘ ") + String(cmd.dropFirst(silent ? 1 : 0)).prefix(40)))
        }
        cmds.append(("cmd-new", "New Command",
                     "커스텀 커맨드 만들기 — {query}/{prompt} 치환, @=백그라운드"))
        return cmds.filter { $0.1.lowercased().contains(q) || $0.2.lowercased().contains(q) }
            .prefix(8).map { .command($0.0, $0.1, $0.2) }
    }

    // "c biddersvc 광고 로직 봐줘" → folder token + trailing initial prompt
    func splitKeywordArg(_ arg: String) -> (String, String) {
        let parts = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let first = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (first, rest)
    }

    func runPanelCommand(_ id: String, alt: Bool = false) {
        if id.hasPrefix("skill:") {
            // a skill is its own piece of work: run it in a fresh session
            // rather than pushing it into a conversation that is mid-thought
            // (typing "/" inside that session is the direct route anyway).
            // The folder comes from the selected session, else the last used.
            let name = String(id.dropFirst(6))
            let near = viewSessions.first(where: { $0.session_id == lastSessionSid })
                ?? attention.first ?? viewSessions.first
            let dir = near?.cwd ?? model.recentDirs.first ?? NSHomeDirectory()
            let arg = skillArg
            model.newSession(in: dir, agent: alt ? model.otherAgent : model.mainAgent,
                             prompt: arg.isEmpty ? "/\(name)" : "/\(name) \(arg)")
            query = ""
            return
        }
        if id == "kw" {
            if let kw = keywordMatch {
                let (folderToken, promptRest) = splitKeywordArg(kw.arg)
                model.runCommand(kw.name, arg: folderToken, prompt: promptRest)
            }
            return
        }
        if id == "kwbase" {
            // open at the template's base path; the whole typed arg is the prompt
            if let kw = keywordMatch {
                model.runCommand(kw.name, arg: "", prompt: kw.arg)
            }
            return
        }
        if id.hasPrefix("kwc|") {
            let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count == 3 {
                let promptRest = keywordMatch.map { splitKeywordArg($0.arg).1 } ?? ""
                model.runCommand(parts[1], arg: parts[2], prompt: promptRest)
            }
            return
        }
        if id == "hub" { model.hub() }
        else if id == "clean" { model.clean(); query = "" }
        else if id == "tidy" { model.tidy(ai: false, all: alt); query = "" }
        else if id == "tidy-ai" { model.tidy(ai: true, all: alt); query = "" }
        else if id == "quit" { NSApp.terminate(nil) }
        else if id == "agent-toggle" { model.mainAgent = model.otherAgent }
        else if id == "cmd-new" {
            editingCommand = true
            cmdDraftName = ""
            cmdDraftBody = ""
        }
        else if id.hasPrefix("cmd-edit:") {
            editingCommand = true
            cmdDraftName = String(id.dropFirst(9))
            cmdDraftBody = model.customCommands[cmdDraftName] ?? ""
        }
        else if id.hasPrefix("new:") {
            // ⌘↩ (or ⌘click) starts the non-main agent
            let cmdClick = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            model.newSession(in: String(id.dropFirst(4)),
                             agent: (alt || cmdClick) ? model.otherAgent : model.mainAgent)
        }
        else if id.hasPrefix("custom:") {
            // ⌘↩ / ⌘click on a custom command opens it in the editor
            let name = String(id.dropFirst(7))
            if alt || NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                editingCommand = true
                cmdDraftName = name
                cmdDraftBody = model.customCommands[name] ?? ""
            } else {
                model.runCommand(name)
            }
        }
    }

    static let attentionOrder = ["waiting": 0, "input": 1, "finished": 2, "running": 3]

    // ⌘⌥N targets follow the visible structure: attention sessions and
    // expanded members get numbers; a collapsed group gets one number itself
    enum HotkeyTarget {
        case session(Session)
        case group(String)
    }

    var hotkeyTargets: [HotkeyTarget] {
        var out: [HotkeyTarget] = []
        for r in rows {
            switch r {
            case .label, .command, .dropzone: break
            case .session(let s, _): out.append(.session(s))
            case .header(let g):
                if !searching && !expanded.contains(g) { out.append(.group(g)) }
            }
        }
        return Array(out.prefix(9))
    }

    var sessionNumbers: [String: Int] {
        var m: [String: Int] = [:]
        for (i, t) in hotkeyTargets.enumerated() {
            if case .session(let s) = t { m[s.session_id] = i + 1 }
        }
        return m
    }

    var groupNumbers: [String: Int] {
        var m: [String: Int] = [:]
        for (i, t) in hotkeyTargets.enumerated() {
            if case .group(let g) = t { m[g] = i + 1 }
        }
        return m
    }

    func handleHotkey(_ n: Int) {
        guard let target = hotkeyTargets[safe: n - 1] else { return }
        switch target {
        case .session(let s):
            model.jump(s)
        case .group(let g):
            expanded.insert(g)
            appDelegate?.showPanel()
            if let idx = rows.firstIndex(where: { $0.id == "hdr-\(g)" }) {
                selected = idx
                scrollTarget = "hdr-\(g)"
            }
        }
    }

    var pinnedSessions: [Session] {
        // pins are scoped to the active group chip; the all-chip shows every pin
        filtered.filter { $0.pinned }
            .filter { selectedChip == nil || $0.group == selectedChip }
            .sorted { ($0.pin_order ?? 0) < ($1.pin_order ?? 0) }
    }

    var attention: [Session] {
        filtered.filter { Self.attentionOrder[$0.status] != nil && !$0.pinned }
            .sorted { a, b in
                let pa = Self.attentionOrder[a.status] ?? 9
                let pb = Self.attentionOrder[b.status] ?? 9
                if pa != pb { return pa < pb }
                return (a.updated_at ?? 0) > (b.updated_at ?? 0)
            }
    }

    var groups: [String] {
        let derived = Set(viewSessions.compactMap { $0.group })
        var orderOf: [String: Int] = [:]
        for s in viewSessions {
            if let g = s.group, let o = s.group_order { orderOf[g] = o }
        }
        return Array(derived.union(Set(pendingGroups))).sorted { a, b in
            let oa = orderOf[a] ?? Int.max
            let ob = orderOf[b] ?? Int.max
            if oa != ob { return oa < ob }
            return a < b
        }
    }

    func restMembers(_ g: String?) -> [Session] {
        filtered.filter { $0.group == g && Self.attentionOrder[$0.status] == nil && !$0.pinned }
    }

    // Raycast keyword: first word matches a commands.json name → run with
    // the rest of the query as {query}
    var keywordMatch: (name: String, arg: String, preview: String, template: String)? {
        guard searching else { return nil }
        let parts = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let name = String(first)
        guard let cmd = model.customCommands[name] else { return nil }
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        let silent = cmd.hasPrefix("@")
        let preview = String(cmd.dropFirst(silent ? 1 : 0))
            .replacingOccurrences(of: "{query}", with: arg.isEmpty ? "…" : arg)
        return (name, arg, preview, cmd)
    }

    // templates shaped like "cd <base>/{query}" autocomplete folder names
    // under <base> as you type the argument
    func folderBase(template: String) -> String? {
        guard let r = template.range(of: #"cd ([^ ]+)/\{query\}"#, options: .regularExpression) else { return nil }
        let sub = String(template[r])
        return String(sub.dropFirst(3).dropLast("/{query}".count))
    }

    func keywordCompletions(template: String, arg: String) -> [(String, String)] {
        guard let base = folderBase(template: template) else { return [] }
        let baseExp = (base as NSString).expandingTildeInPath
        let q = arg.lowercased()
        let matches = model.dirs(under: baseExp).filter {
            q.isEmpty || $0.lowercased().contains(q)
        }
        // prefix matches first, then the rest, alphabetical within each
        let sorted = matches.sorted { a, b in
            let ap = a.lowercased().hasPrefix(q), bp = b.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a.lowercased() < b.lowercased()
        }
        return sorted.prefix(8).map { ($0, baseExp + "/" + $0) }
    }

    static let statusOrderAll = ["waiting", "running", "input", "finished", "done", "gone"]

    func statusSorted(_ list: [Session]) -> [Session] {
        list.sorted { a, b in
            let pa = Self.statusOrderAll.firstIndex(of: a.status) ?? 9
            let pb = Self.statusOrderAll.firstIndex(of: b.status) ?? 9
            if pa != pb { return pa < pb }
            return (a.updated_at ?? 0) > (b.updated_at ?? 0)
        }
    }

    // chips layout: pinned, then the chip-filtered pool in status sections
    var chipRows: [PanelRow] {
        var out: [PanelRow] = []
        let pool = filtered.filter { !$0.pinned }
            .filter { selectedChip == nil || $0.group == selectedChip }
        // hybrid layout: only attention-worthy sessions get pulled to the
        // top; everything else stays in one stable list (manual order, then
        // recency, ended sunk to the bottom) — status reads off the mascot
        let attnOrder = ["waiting", "input", "finished"]
        let attn = pool.filter { attnOrder.contains($0.status) }
            .sorted { a, b in
                let ua = attnOrder.firstIndex(of: a.status) ?? 9
                let ub = attnOrder.firstIndex(of: b.status) ?? 9
                if ua != ub { return ua < ub }
                let oa = a.sort_order ?? Int.max
                let ob = b.sort_order ?? Int.max
                if oa != ob { return oa < ob }
                return (a.updated_at ?? 0) > (b.updated_at ?? 0)
            }
        let rest = pool.filter { !attnOrder.contains($0.status) }
            .sorted { a, b in
                switch sortMode {
                case .recent:
                    let ra = recencyTime(a), rb = recencyTime(b)
                    if ra != rb { return ra > rb }
                case .status:
                    let order = ["running", "done", "gone"]
                    let ia = order.firstIndex(of: a.status) ?? 9
                    let ib = order.firstIndex(of: b.status) ?? 9
                    if ia != ib { return ia < ib }
                case .folder:
                    let fa = ((a.cwd ?? "") as NSString).lastPathComponent
                    let fb = ((b.cwd ?? "") as NSString).lastPathComponent
                    if fa != fb { return fa.localizedCaseInsensitiveCompare(fb) == .orderedAscending }
                case .name:
                    let na = a.title ?? "", nb = b.title ?? ""
                    if na != nb { return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending }
                case .standard:
                    if (a.status == "gone") != (b.status == "gone") { return b.status == "gone" }
                    let oa = a.sort_order ?? Int.max
                    let ob = b.sort_order ?? Int.max
                    if oa != ob { return oa < ob }
                }
                return (a.updated_at ?? 0) > (b.updated_at ?? 0)
            }
        // purely visual nesting: a child renders indented under its parent —
        // the parent can be pinned or in the stable list. Status/ack stay
        // independent (a child in ATTENTION stays in ATTENTION)
        let parentIds = Set(rest.map { $0.session_id })
            .union(pinnedSessions.map { $0.session_id })
        // a hidden parent (dead original) is represented by its live
        // continuation — nest siblings under that row instead
        func displayParent(_ s: Session) -> String? {
            guard let p = s.parent else { return nil }
            if parentIds.contains(p) { return p }
            if let proxy = (rest + pinnedSessions).first(where: {
                $0.session_id != s.session_id && $0.parent == p && ($0.continuation ?? false)
            }) {
                return proxy.session_id
            }
            return nil
        }
        // a visible parent always claims its child — a drag slot only orders
        // top-level rows, it no longer knocks the child out of the nest
        let children = Dictionary(grouping: rest.filter {
            displayParent($0) != nil
        }, by: { displayParent($0)! })
        let nestedIds = Set(children.values.flatMap { $0 }.map { $0.session_id })
        func appendWithChildren(_ s: Session) {
            out.append(.session(s, indented: false))
            for c in (children[s.session_id] ?? [])
                .sorted(by: { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }) {
                out.append(.session(c, indented: true))
            }
        }
        if !pinnedSessions.isEmpty {
            out.append(.label("PINNED"))
            pinnedSessions.forEach(appendWithChildren)
        }
        if !attn.isEmpty {
            out.append(.label("ATTENTION"))
            out += attn.map { .session($0, indented: false) }
        }
        if !rest.isEmpty {
            if !attn.isEmpty || !pinnedSessions.isEmpty { out.append(.label("SESSIONS")) }
            // while a temporary sort is active the list is already ordered by
            // that key — label each run so the boundaries are visible
            var lastKey: String? = nil
            for m in rest where !nestedIds.contains(m.session_id) {
                if let key = sortSectionKey(m), key != lastKey {
                    out.append(.label(key))
                    lastKey = key
                }
                appendWithChildren(m)
            }
        }
        return out
    }

    // the navigable list, in display order
    var rows: [PanelRow] {
        if skillQuery != nil { return skillRows }
        if let kw = keywordMatch {
            var out: [PanelRow] = []
            let (folderToken, promptRest) = splitKeywordArg(kw.arg)
            let comps = keywordCompletions(template: kw.template, arg: folderToken)
            if comps.isEmpty {
                if let base = folderBase(template: kw.template) {
                    // no matching folder — open at the base path, with the
                    // typed text as the initial prompt
                    let sub = kw.arg.isEmpty ? "기본 경로에서 세션 시작"
                        : "기본 경로에서 시작 — \"\(kw.arg.prefix(30))\""
                    out.append(.command("kwbase", "\(kw.name) → \(base)", sub))
                } else {
                    out.append(.command("kw", "\(kw.name) \(kw.arg)", String(kw.preview.prefix(50))))
                }
            } else {
                for (folder, path) in comps {
                    let title = promptRest.isEmpty
                        ? "\(kw.name) \(folder)"
                        : "\(kw.name) \(folder) — \"\(promptRest.prefix(24))\""
                    out.append(.command("kwc|\(kw.name)|\(folder)", title,
                               path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                }
            }
            out += filtered.map { .session($0, indented: false) }
            return out
        }
        if searching {
            var out: [PanelRow] = []
            for st in ["waiting", "running", "input", "finished", "done", "gone"] {
                out += filtered.filter { $0.status == st }.map { .session($0, indented: false) }
            }
            out += commandRows
            let liveIds = Set(model.sessions.map { $0.session_id })
            // transcript-content matches on live sessions the title filter missed
            let titleMatched = Set(filtered.map { $0.session_id })
            let contentMatches = model.archive.compactMap { a in
                liveIds.contains(a.session_id) && !titleMatched.contains(a.session_id)
                    ? viewSessions.first { $0.session_id == a.session_id } : nil
            }
            if !contentMatches.isEmpty {
                out.append(.label("내용 일치"))
                out += contentMatches.map { .session($0, indented: false) }
            }
            let archived = model.archive.filter { !liveIds.contains($0.session_id) }
            if model.archiveSearching {
                out.append(.label("ARCHIVE — 검색 중…"))
            } else if !archived.isEmpty {
                out.append(.label("ARCHIVE"))
                out += archived.map { .session($0, indented: false) }
            }
            return out
        }
        if groupLayout == "chips" { return chipRows }
        var out: [PanelRow] = []
        if !pinnedSessions.isEmpty {
            out.append(.label("PINNED"))
            out += pinnedSessions.map { .session($0, indented: false) }
        }
        if !attention.isEmpty {
            out.append(.label("ATTENTION"))
            out += attention.map { .session($0, indented: false) }
        }
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
            case .label: return acc + 28
            case .header: return acc + 34
            case .session: return acc + 47
            case .command: return acc + 42
            case .dropzone: return acc + 10
            }
        }
        var extra: CGFloat = 0
        if !searching {
            if groupLayout == "chips" { extra += 42 }
        }
        return min(max(h + extra + 16 + (draggingGroup != nil ? 34 : 0), 100), 460)
    }

    func isSelected(_ r: PanelRow) -> Bool { rows[safe: selected]?.id == r.id }

    // index of the first actionable row (labels/dropzones are not selectable)
    func firstSelectable() -> Int {
        for (i, r) in rows.enumerated() where r.selectable {
            return i
        }
        return 0
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let n = rows.count
        var i = selected
        // wrap around at both ends, skipping non-selectable rows
        for _ in 0..<n {
            i = (i + delta % n + n) % n
            if !rows[i].selectable { continue }
            selected = i
            scrollTarget = rows[safe: selected]?.id
            if case .session(let s, _)? = rows[safe: selected] { lastSessionSid = s.session_id }
            return
        }
    }

    func toggleExpand(_ g: String) {
        if expanded.contains(g) { expanded.remove(g) } else { expanded.insert(g) }
    }

    // → expands / ← collapses when a group header is selected (query empty);
    // in chips layout the arrows cycle the selected chip instead
    func handleLR(_ dir: Int) -> Bool {
        guard !searching else { return false }
        if groupLayout == "chips" {
            let chips: [String?] = [nil] + groups.map { Optional($0) }
            let cur = chips.firstIndex(where: { $0 == selectedChip }) ?? 0
            let next = (cur + dir + chips.count) % chips.count
            selectedChip = chips[next]
            selected = firstSelectable()
            return true
        }
        guard case .header(let g)? = rows[safe: selected] else { return false }
        if dir > 0 { expanded.insert(g) } else { expanded.remove(g) }
        return true
    }

    func activateSelected(alt: Bool = false) {
        if case .label? = rows[safe: selected] { selected = firstSelectable() }
        switch rows[safe: selected] ?? rows.first {
        case .session(let s, _): model.jump(s)
        case .header(let g): toggleExpand(g)
        case .command(let id, _, _): runPanelCommand(id, alt: alt)
        case .label, .dropzone, nil: break
        }
    }

    func headerRow(_ g: String) -> some View {
        let members = filtered.filter { $0.group == (g == "__ungrouped__" ? nil : g) }
        let hasAttention = members.contains { ["waiting", "input", "finished"].contains($0.status) }
        return GroupHeaderRow(
            name: g,
            count: members.count,
            hasAttention: hasAttention,
            expanded: expanded.contains(g),
            isSelected: isSelected(.header(g)),
            highlight: (dropTarget == g && draggingGroup == nil) || sessionDropGroup == g,
            insertLine: dropTarget == g && draggingGroup != nil,
            hotkeyNumber: groupNumbers[g],
            tint: namedColor(members.first?.group_color)
        ) { toggleExpand(g) }
        .contextMenu {
            Button("Open all sessions") { model.openAll(members) }
            if g != "__ungrouped__" {
                Button("Rename group") { renaming = g; renameText = g }
                Menu("Color") {
                    ForEach(["orange", "blue", "green", "purple", "pink", "gray"], id: \.self) { c in
                        Button(c) { model.setGroupColor(g, c) }
                    }
                }
                Button("Dissolve group") {
                    model.dissolveGroup(g)
                    pendingGroups.removeAll { $0 == g }
                }
            }
        }
        .onDrag {
            // group reorder drag — flag it so targets show an insertion line
            DispatchQueue.main.async { draggingGroup = g }
            return NSItemProvider(object: "group:\(g)" as NSString)
        }
        .onDrop(of: [.plainText, .utf8PlainText], isTargeted: Binding(
            get: { dropTarget == g },
            set: { over in dropTarget = over ? g : (dropTarget == g ? nil : dropTarget) }
        )) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let item = obj as? String else { return }
                DispatchQueue.main.async {
                    if item.hasPrefix("group:") {
                        let dragged = String(item.dropFirst(6))
                        if dragged != g {
                            model.groupMove(dragged, before: g == "__ungrouped__" ? "end" : g)
                        }
                    } else {
                        model.assign(item, to: g == "__ungrouped__" ? nil : g)
                        pendingGroups.removeAll { $0 == g }
                        expanded.insert(g)
                    }
                    draggingGroup = nil
                    dropTarget = nil
                }
            }
            return true
        }
        .id("hdr-\(g)")
    }

    @ViewBuilder
    func rowView(_ r: PanelRow) -> some View {
        switch r {
        case .label(let l):
            HStack(spacing: 5) {
                Text(l)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(l == "ATTENTION" || l == "NEEDS INPUT"
                                     ? claudeOrange.opacity(0.9) : Color.secondary.opacity(0.8))
                    .tracking(1.4)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)
        case .command(let id, let title, let sub):
            HStack(spacing: 9) {
                Text(">")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(claudeOrange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected(r) ? claudeOrange.opacity(0.25) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture { runPanelCommand(id) }
            .id(r.id)
        case .dropzone(let z):
            // silent drop strip — shows a line only while hovered
            Rectangle()
                .fill(sessionDropTarget == "dz-\(z)" ? claudeOrange : Color.clear)
                .frame(height: 2)
                .cornerRadius(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                if let d = items.first, !d.hasPrefix("group:") {
                    model.pinInsert(d, before: "end")
                }
                sessionDropTarget = nil
                draggingSessionSid = nil
                return true
            } isTargeted: { over in
                sessionDropTarget = over ? "dz-\(z)"
                    : (sessionDropTarget == "dz-\(z)" ? nil : sessionDropTarget)
            }
        case .header(let g):
            headerRow(g)
                .padding(.top, 5)
        case .session(let s, let indented):
            let base = SessionRow(s: s, model: model, isSelected: isSelected(r),
                                  hotkeyNumber: sessionNumbers[s.session_id],
                                  animate: model.panelVisible,
                                  isRenaming: renamingSession?.session_id == s.session_id,
                                  isStopping: stoppingSids.contains(s.session_id),
                                  insertLine: sessionDropTarget == s.session_id
                                      && (s.pinned || draggedSameStatus(as: s)),
                                  dropHighlight: !s.pinned && sessionDropTarget == s.session_id
                                      && !draggedSameStatus(as: s),
                                  onDragBegin: { draggingSessionSid = s.session_id },
                                  onRename: { sess in
                                      renamingSession = sess
                                  },
                                  onMessage: { sess in
                                      messagingSession = sess
                                      messageText = ""
                                  },
                                  renameCommit: { newName in
                                      model.renameSession(s.session_id, to: newName)
                                      renamingSession = nil
                                      // hand the keyboard back so ↩ jumps again
                                      searchFocused = true
                                  },
                                  renameCancel: {
                                      renamingSession = nil
                                      searchFocused = true
                                  })
                .padding(.leading, indented ? 16 : 0)
                .id(r.id)
            if s.pinned && !searching {
                base.dropDestination(for: String.self) { items, location in
                    if let d = items.first, d != s.session_id, !d.hasPrefix("group:") {
                        // dropping on the bottom half of the last pin = append
                        let isLast = pinnedSessions.last?.session_id == s.session_id
                        if isLast && location.y > 24 {
                            model.pinInsert(d, before: "end")
                        } else {
                            model.pinInsert(d, before: s.session_id)
                        }
                    }
                    sessionDropTarget = nil
                    draggingSessionSid = nil
                    return true
                } isTargeted: { over in
                    sessionDropTarget = over ? s.session_id
                        : (sessionDropTarget == s.session_id ? nil : sessionDropTarget)
                }
            } else {
                // same-status drop = reorder within the section; otherwise the
                // dragged session joins this session's group
                base.dropDestination(for: String.self) { items, location in
                    if let d = items.first, d != s.session_id, !d.hasPrefix("group:") {
                        let draggedStatus = viewSessions.first(where: { $0.session_id == d })?.status
                        if let ds = draggedStatus, dragZone(ds) == dragZone(s.status) {
                            if isLastInSection(s) && location.y > 24 {
                                model.orderInsert(d, before: "end")
                            } else {
                                model.orderInsert(d, before: s.session_id)
                            }
                        } else {
                            model.assign(d, to: s.group)
                        }
                    }
                    sessionDropTarget = nil
                    draggingSessionSid = nil
                    return true
                } isTargeted: { over in
                    sessionDropTarget = over ? s.session_id
                        : (sessionDropTarget == s.session_id ? nil : sessionDropTarget)
                }
            }
        }
    }

    func manualThenRecent(_ a: Session, _ b: Session) -> Bool {
        let oa = a.sort_order ?? Int.max
        let ob = b.sort_order ?? Int.max
        if oa != ob { return oa < ob }
        return (a.updated_at ?? 0) > (b.updated_at ?? 0)
    }

    func isLastInSection(_ s: Session) -> Bool {
        let zone = dragZone(s.status)
        let pool = filtered.filter { !$0.pinned && dragZone($0.status) == zone }
            .filter { selectedChip == nil || $0.group == selectedChip }
            .sorted(by: manualThenRecent)
        return pool.last?.session_id == s.session_id
    }

    // hybrid layout has two drag zones: ATTENTION and the stable SESSIONS
    // list — reorder applies within a zone, cross-zone drops assign groups
    func dragZone(_ status: String) -> String {
        ["waiting", "input", "finished"].contains(status) ? "attn" : "rest"
    }
    func draggedSameStatus(as s: Session) -> Bool {
        guard let d = draggingSessionSid,
              let dragged = viewSessions.first(where: { $0.session_id == d }) else { return false }
        return dragZone(dragged.status) == dragZone(s.status)
    }

    // the group a session-onto-session drop would land in — used to co-
    // highlight that group's header while hovering
    var sessionDropGroup: String? {
        guard let t = sessionDropTarget, !t.hasPrefix("dz-") else { return nil }
        guard let target = viewSessions.first(where: { $0.session_id == t }), !target.pinned else { return nil }
        return target.group ?? "__ungrouped__"
    }

    func chipColor(_ g: String) -> Color {
        namedColor(viewSessions.first(where: { $0.group == g })?.group_color)
    }

    var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chipView(nil, "전체", viewSessions.count)
                ForEach(groups, id: \.self) { g in
                    chipView(g, g, viewSessions.filter { $0.group == g }.count)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func chipView(_ g: String?, _ label: String, _ count: Int) -> some View {
        let selectedNow = selectedChip == g
        let tint = g.map(chipColor) ?? claudeOrange
        let chipId = g ?? "__all__"
        let targeted = dropTarget == "chip-\(chipId)"
        let body = VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint.opacity(selectedNow ? 1 : 0.75)).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(selectedNow ? Color.primary : Color.secondary)
                Text("\(count)").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(targeted ? tint.opacity(0.3) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(targeted ? tint.opacity(0.7) : Color.clear, lineWidth: 1))
            // selection = an underline indicator instead of a filled chip
            Capsule().fill(selectedNow ? tint : Color.clear)
                .frame(width: 22, height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedChip = g }
        .dropDestination(for: String.self) { items, _ in
            if let item = items.first {
                if item.hasPrefix("group:") {
                    // chip reorder: drop a group chip before this one
                    let dragged = String(item.dropFirst(6))
                    if let g, dragged != g {
                        model.groupMove(dragged, before: g)
                    } else if g == nil, let first = groups.first, dragged != first {
                        model.groupMove(dragged, before: first)
                    }
                } else {
                    model.assign(item, to: g)
                }
            }
            dropTarget = nil
            draggingGroup = nil
            draggingSessionSid = nil
            return true
        } isTargeted: { over in
            dropTarget = over ? "chip-\(chipId)"
                : (dropTarget == "chip-\(chipId)" ? nil : dropTarget)
        }
        if let g {
            body.onDrag {
                DispatchQueue.main.async { draggingGroup = g }
                return NSItemProvider(object: "group:\(g)" as NSString)
            }
        } else {
            body
        }
    }


    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PixelAppIcon(choice: model.iconChoiceKey, pixel: 2.2,
                             animate: model.panelVisible)
                TextField("Search…  (/ skills)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .rounded))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
                    .onExitCommand { appDelegate?.hidePanel(restoreFocus: true) }
                    .onChange(of: query) { q in
                        selected = 0
                        model.searchArchive(q)
                    }
                let counts = model.sessions.reduce(into: (running: 0, waiting: 0)) { acc, s in
                    if s.status == "running" { acc.running += 1 }
                    else if s.status == "waiting" { acc.waiting += 1 }
                }
                let running = counts.running
                let waiting = counts.waiting
                if waiting > 0 {
                    Text("\(waiting) waiting")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .systemOrange).opacity(0.2)))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                } else if running > 0 {
                    Text("\(running) running")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .systemGreen).opacity(0.16)))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
            }
            .padding(.horizontal, 16).padding(.top, 14)

            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }

            Divider().padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        if !searching, groupLayout == "chips" { chipBar }
                        ForEach(rows) { rowView($0) }
                        if draggingGroup != nil {
                            // end-of-list drop zone, visible only while
                            // dragging a group card
                            VStack(spacing: 3) {
                                Rectangle()
                                    .fill(dropTarget == "__end__" ? claudeOrange : Color.primary.opacity(0.12))
                                    .frame(height: 2)
                                    .cornerRadius(1)
                                    .padding(.horizontal, 6)
                                Text("맨 아래로")
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onDrop(of: [.plainText, .utf8PlainText], isTargeted: Binding(
                                get: { dropTarget == "__end__" },
                                set: { over in dropTarget = over ? "__end__" : (dropTarget == "__end__" ? nil : dropTarget) }
                            )) { providers in
                                guard let p = providers.first else { return false }
                                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                                    guard let item = obj as? String, item.hasPrefix("group:") else { return }
                                    DispatchQueue.main.async {
                                        model.groupMove(String(item.dropFirst(6)), before: "end")
                                        draggingGroup = nil
                                        dropTarget = nil
                                    }
                                }
                                return true
                            }
                        }
                        if rows.isEmpty {
                            VStack(spacing: 8) {
                                PixelMascot(pixel: 4).opacity(0.55)
                                Text(searching ? "no match" : "no sessions — go start one!")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: listHeight)
                .onChange(of: scrollTarget) { t in
                    guard let t else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(t, anchor: .center) }
                    // reset so setting the same target again still scrolls
                    DispatchQueue.main.async { scrollTarget = nil }
                }
            }

            if let sess = messagingSession {
                HStack(spacing: 8) {
                    Text("→ \((sess.title ?? "session").prefix(16))").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("message (↩ 헤드리스 · ⌘↩ 터미널에 입력)", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($msgFocused)
                        .onAppear { msgFocused = true }
                        .onSubmit {
                            let text = messageText.trimmingCharacters(in: .whitespaces)
                            let viaTerminal = NSEvent.modifierFlags.contains(.command)
                            if !text.isEmpty {
                                model.sendMessage(sess.session_id, text, viaTerminal: viaTerminal)
                                if viaTerminal { appDelegate?.hidePanel() }
                            }
                            messagingSession = nil
                            messageText = ""
                        }
                        .onExitCommand {
                            messagingSession = nil
                            messageText = ""
                            searchFocused = true
                        }
                    Button("✕") { messagingSession = nil }.buttonStyle(.plain).font(.system(size: 10))
                }
                .padding(.horizontal, 14)
            }

            if editingCommand {
                HStack(spacing: 8) {
                    TextField("이름", text: $cmdDraftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 110)
                        .focused($cmdNameFocused)
                        .onAppear { cmdNameFocused = true }
                    TextField("명령 ({query}/{prompt} 치환, @=백그라운드 실행)", text: $cmdDraftBody)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            let n = cmdDraftName.trimmingCharacters(in: .whitespaces)
                            let c = cmdDraftBody.trimmingCharacters(in: .whitespaces)
                            if !n.isEmpty, !c.isEmpty {
                                model.saveCommand(name: n, command: c)
                                editingCommand = false
                                query = ""
                            }
                        }
                    Button("✕") { editingCommand = false }.buttonStyle(.plain).font(.system(size: 10))
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
                    Text(sortMode == .standard
                         ? "↩ 열기 · ⌘1-9 점프 · ⌃X 중지 · ⌘S 정렬 · / 스킬"
                         : "정렬: \(sortMode.label) · ⌘S 전환")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if model.refreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                } else {
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).help("Refresh (⌘R)")
                    .frame(width: 16, height: 16)
                }
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
        .onChange(of: model.sessions) { _ in
            // clear the stopping indicator once the session left running state
            stoppingSids = stoppingSids.filter { sid in
                model.sessions.first(where: { $0.session_id == sid })?.status == "running"
            }
            // keep hiding ended sessions until the record actually drops out
            endingSids = endingSids.filter { sid in
                model.sessions.contains { $0.session_id == sid }
            }
            // follow a session whose row moved between sections (e.g. stopped)
            if let sid = followSid {
                if let s = model.sessions.first(where: { $0.session_id == sid }) {
                    expanded.insert(s.group ?? "__ungrouped__")
                    if let idx = rows.firstIndex(where: { $0.id == sid }) {
                        selected = idx
                        scrollTarget = sid
                    }
                }
                followSid = nil
            }
            if selected >= rows.count { selected = max(0, rows.count - 1) }
        }
        .onChange(of: model.focusTick) { _ in
            query = ""
            selected = firstSelectable()
            searchFocused = true
            draggingGroup = nil
            dropTarget = nil
            renamingSession = nil
            messagingSession = nil
            messageText = ""
            draggingSessionSid = nil
            sessionDropTarget = nil
            // transient editors don't survive the panel losing focus
            editingCommand = false
            cmdDraftName = ""
            cmdDraftBody = ""
            renaming = nil
            renameText = ""
            addingGroup = false
            newGroupName = ""
        }
        .onAppear {
            model.moveSelection = { move($0) }
            model.arrowLR = { handleLR($0) }
            model.hotkeyNumber = { handleHotkey($0) }
            model.cycleSort = {
                sortMode = sortMode.next
                selected = firstSelectable()
                model.showToast("정렬: \(sortMode.label)")
            }
            model.enterKey = { activateSelected(alt: $0) }
            model.isTextEditing = {
                renamingSession != nil || editingCommand || messagingSession != nil
                    || renaming != nil || addingGroup
            }
            model.cmdEnterInEditor = {
                guard let sess = messagingSession else { return false }
                let text = messageText.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return false }
                model.sendMessage(sess.session_id, text, viaTerminal: true)
                messagingSession = nil
                messageText = ""
                appDelegate?.hidePanel()
                return true
            }
            model.actionKey = { action in
                if case .label? = rows[safe: selected] { selected = firstSelectable() }
                // on a group header: expand it and step into the first member,
                // so a second press acts on an actual session
                if case .header(let g)? = rows[safe: selected] {
                    expanded.insert(g)
                    if let hIdx = rows.firstIndex(where: { $0.id == "hdr-\(g)" }),
                       case .session(let m, _)? = rows[safe: hIdx + 1] {
                        selected = hIdx + 1
                        scrollTarget = m.session_id
                    }
                    return true
                }
                guard case .session(let s, _)? = rows[safe: selected], s.status != "archived" else {
                    return false
                }
                switch action {
                case "pin": model.togglePin(s.session_id)
                case "rename": renamingSession = s
                case "copyresume": model.copyResume(s)
                case "retitle": model.retitle(s)
                case "ungroup":
                    guard s.group != nil else { return false }
                    model.assign(s.session_id, to: nil)
                case "end":
                    // first Ctrl+X stops the session (stays as 💤, resumable);
                    // Ctrl+X on a stopped/gone session removes it from view
                    if stoppingSids.contains(s.session_id) {
                        // second press while the "^X again = end" capsule is
                        // up: end right away and drop the row immediately
                        stoppingSids.remove(s.session_id)
                        endingSids.insert(s.session_id)
                        model.endSession(s.session_id)
                    } else if s.status == "gone" {
                        endingSids.insert(s.session_id)
                        model.endSession(s.session_id)
                    } else {
                        // any tracked session (claude interactive/background,
                        // codex — which has no daemon kind) — cst drives it
                        // from the record. The row relocates immediately;
                        // selection and scroll follow it there
                        let sid = s.session_id
                        stoppingSids.insert(sid)
                        followSid = sid
                        if !s.pinned { expanded.insert(s.group ?? "__ungrouped__") }
                        model.stopSession(sid)
                        DispatchQueue.main.async {
                            if let idx = rows.firstIndex(where: { $0.id == sid }) {
                                selected = idx
                                scrollTarget = sid
                            }
                        }
                        // safety net: never leave the indicator stuck
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            stoppingSids.remove(sid)
                        }
                    }
                default: return false
                }
                return true
            }
            model.messageSelected = {
                if renamingSession != nil { return }
                // keyword mode: Tab completes the folder name into the field
                // so a prompt can be typed after it
                if let kw = keywordMatch {
                    var folder: String? = nil
                    if case .command(let id, _, _)? = rows[safe: selected], id.hasPrefix("kwc|") {
                        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
                        if parts.count == 3 { folder = parts[2] }
                    }
                    if folder == nil {
                        for r in rows {
                            if case .command(let id, _, _) = r, id.hasPrefix("kwc|") {
                                let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
                                if parts.count == 3 { folder = parts[2]; break }
                            }
                        }
                    }
                    if let folder {
                        query = "\(kw.name) \(folder) "
                        selected = 0
                    }
                    return
                }
                // a command row selected: Tab types it into the field
                // (custom commands land in keyword mode so arguments follow)
                if case .command(let id, let title, _)? = rows[safe: selected] {
                    if id.hasPrefix("custom:") {
                        query = "\(String(id.dropFirst(7))) "
                    } else if id.hasPrefix("skill:") {
                        query = "/\(String(id.dropFirst(6))) "
                    } else {
                        query = title
                    }
                    selected = 0
                    return
                }
                if case .session(let s, _)? = rows[safe: selected], s.status != "archived" {
                    messagingSession = s
                    messageText = ""
                }
            }
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            if self === appDelegate?.iconPanel {
                orderOut(nil)
            } else {
                appDelegate?.hidePanel(restoreFocus: true)
            }
            return
        }
        super.keyDown(with: event)
    }
}

var appDelegate: AppDelegate?

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var panel: FloatingPanel!
    let model = Model()
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appDelegate = self

        // menubar-only apps have no main menu, so Cmd+C/V/X/A/Z never reach
        // text fields — install a hidden Edit menu to route them
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

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
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buildMenubarImages()
        updateTitle(sessions: [])
        model.start()
        registerHotkey()
        setupNotifications()

        // arrow keys never reach SwiftUI while the search field editor has
        // focus — intercept them at the event level while the panel is key
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // an inline editor (rename, command editor, quick prompt…) owns
            // arrows and tab — don't steal them for list navigation. ⌘↩ is
            // ours though: send-to-terminal from the quick prompt.
            if self.model.isTextEditing?() == true {
                if event.keyCode == 36, event.modifierFlags.contains(.command),
                   self.model.cmdEnterInEditor?() == true {
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 125: self.model.moveSelection?(1); return nil // down
            case 126: self.model.moveSelection?(-1); return nil // up
            case 123: return self.model.arrowLR?(-1) == true ? nil : event // left
            case 124: return self.model.arrowLR?(1) == true ? nil : event // right
            case 48: self.model.messageSelected?(); return nil // tab → quick prompt
            default:
                // user-remappable session actions first — an explicit custom
                // binding beats the fixed chords below
                var carbon = 0
                if event.modifierFlags.contains(.command) { carbon |= cmdKey }
                if event.modifierFlags.contains(.option) { carbon |= optionKey }
                if event.modifierFlags.contains(.control) { carbon |= controlKey }
                if event.modifierFlags.contains(.shift) { carbon |= shiftKey }
                if carbon != 0 {
                    for a in Self.panelActions {
                        let b = self.panelBinding(a.id)
                        guard Int(event.keyCode) == b.code, carbon == b.mods else { continue }
                        switch a.id {
                        case "refresh": self.model.refresh(); return nil
                        case "sort": self.model.cycleSort?(); return nil
                        default:
                            if self.model.actionKey?(a.id) == true { return nil }
                        }
                    }
                }
                if event.modifierFlags.contains(.command) {
                    // ⌘1..9 — jump to the badged target
                    let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                                                 22: 6, 26: 7, 28: 8, 25: 9]
                    if let n = digits[event.keyCode] {
                        self.model.hotkeyNumber?(n)
                        return nil
                    }
                    if event.keyCode == 36 { // ⌘↩ — activate with the alt agent
                        self.model.enterKey?(true)
                        return nil
                    }
                }
                return event
            }
        }
    }

    var keyMonitor: Any?

    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenubarMenu(); return }
        if panel.isVisible { hidePanel(restoreFocus: true) } else { showPanel() }
    }

    // whoever had focus before the panel opened — Esc/⌥Space return it
    var previousApp: NSRunningApplication?

    // panel state on disk: lets `ast` (and a human debugging battery use)
    // tell which regime the app is in without asking the UI
    func notePanelState(_ visible: Bool) {
        let p = homeDirPath + "/.local/state/claude-session-tracker/panel-visible"
        try? (visible ? "1" : "0").write(toFile: p, atomically: true, encoding: .utf8)
    }

    func showPanel() {
        notePanelState(true)
        model.invalidateFolderCache()
        previousApp = NSWorkspace.shared.frontmostApplication
        model.refresh()
        panel.layoutIfNeeded()
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            let x = vf.midX - size.width / 2
            let y = vf.origin.y + vf.height * 0.72
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
        // Korean/CJK IME composition needs the app active — a nonactivating
        // panel alone leaves the input method attached to the previous app
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.panelVisible = true
        model.focusTick += 1
    }

    func hidePanel(restoreFocus: Bool = false,
                   caller: String = #function, line: Int = #line) {
        notePanelState(false)
        dbg("hidePanel from \(caller):\(line) restoreFocus=\(restoreFocus)")
        panel.orderOut(nil)
        model.panelVisible = false
        // dismissals (Esc / ⌥Space) hand focus back to where it was; action
        // paths (jump, new session…) pick their own target instead
        if restoreFocus, let p = previousApp,
           p.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            p.activate(options: [])
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // returning from a system dialog leaves the search field unfocused
        guard (notification.object as? NSWindow) === panel else { return }
        model.focusTick += 1
    }

    func windowDidResignKey(_ notification: Notification) {
        dbg("resignKey window=\((notification.object as? NSWindow)?.title ?? "?") "
            + "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") "
            + "modal=\(NSApp.modalWindow != nil) appActive=\(NSApp.isActive)")
        // Raycast behavior: clicking elsewhere dismisses the panel — but a
        // macOS permission/security dialog stealing focus must not
        if (notification.object as? NSWindow) === iconPanel {
            iconPanel?.orderOut(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            // a modal system sheet (file-access consent, keychain, …) is not
            // the user clicking away
            if NSApp.modalWindow != nil { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            // TCC consent prompts are attributed to the app that triggered
            // them, so "we are still frontmost but the panel lost key" means a
            // system dialog is up — not a click elsewhere. Any Apple-owned
            // agent (SecurityAgent, UserNotificationCenter, …) counts too.
            dbg("resignKey delayed check front=\(front) visible=\(self.panel.isVisible) key=\(self.panel.isKeyWindow)")
            if front.isEmpty || front.hasPrefix("com.apple.")
                || front == Bundle.main.bundleIdentifier { dbg("kept open"); return }
            self.hidePanel()
        }
    }

    // Global hotkeys via Carbon — no accessibility permission needed.
    // Panel toggle default: ⌥Space — override with:
    //   defaults write com.dean.claude-sessions hotkeyKeyCode -int <keycode>
    //   defaults write com.dean.claude-sessions hotkeyModifiers -int <carbon-modifier-mask>
    func registerHotkey() {
        let defaults = UserDefaults(suiteName: "com.dean.claude-sessions")
        let keyCode = defaults?.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_Space
        let modifiers = defaults?.object(forKey: "hotkeyModifiers") as? Int ?? optionKey

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                if hkID.id == 2 {
                    appDelegate?.jumpAttention()
                } else if hkID.id >= 10 {
                    appDelegate?.jumpIndex(Int(hkID.id) - 9)
                } else {
                    appDelegate?.togglePanel()
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x43535453), id: 1) // 'CSTS'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                            GetEventDispatcherTarget(), 0, &hotKeyRef)

        // attention jump — default ⌘⌥A, user-configurable in settings
        let aKey = defaults?.object(forKey: "attentionKeyCode") as? Int ?? kVK_ANSI_A
        let aMods = defaults?.object(forKey: "attentionModifiers") as? Int ?? (cmdKey | optionKey)
        let attentionID = EventHotKeyID(signature: OSType(0x43535453), id: 2)
        RegisterEventHotKey(UInt32(aKey), UInt32(aMods), attentionID,
                            GetEventDispatcherTarget(), 0, &attentionHotKeyRef)

        // number jumps are panel-local (handled by the key monitor while the
        // panel is key) so they never shadow typing in other apps
    }

    var attentionHotKeyRef: EventHotKeyRef?
    var digitHotKeyRefs: [EventHotKeyRef?] = []

    // ── settings window ──────────────────────────────────────────
    var settingsWindow: NSWindow?
    func showSettings() {
        iconPanel?.orderOut(nil)
        hidePanel()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "설정"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // ── user-configurable panel hotkey ───────────────────────────
    static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",",
        kVK_ANSI_Semicolon: ";", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    ]

    // ── remappable in-panel action keys (modifier+key, stored like the
    // global hotkeys; defaults are the classic ⌃ set) ───────────────
    static let panelActions: [(id: String, label: String, defCode: Int, defMods: Int)] = [
        ("end", "세션 중지 → 종료", kVK_ANSI_X, controlKey),
        ("rename", "이름 변경", kVK_ANSI_R, controlKey),
        ("pin", "핀 토글", kVK_ANSI_P, controlKey),
        ("copyresume", "resume 명령 복사", kVK_ANSI_C, controlKey),
        ("retitle", "AI로 이름 짓기", kVK_ANSI_R, controlKey | cmdKey),
        ("refresh", "새로고침", kVK_ANSI_R, cmdKey),
        ("sort", "정렬 전환", kVK_ANSI_S, cmdKey),
        ("ungroup", "그룹 해제", kVK_Delete, controlKey),
    ]

    func panelBinding(_ id: String) -> (code: Int, mods: Int) {
        guard let def = Self.panelActions.first(where: { $0.id == id }) else { return (0, 0) }
        let d = UserDefaults.standard
        let k = d.object(forKey: "panelKey.\(id)") as? Int ?? def.defCode
        let m = d.object(forKey: "panelMods.\(id)") as? Int ?? def.defMods
        return (k, m)
    }

    func setPanelBinding(_ id: String, keyCode: Int, carbonMods: Int) {
        UserDefaults.standard.set(keyCode, forKey: "panelKey.\(id)")
        UserDefaults.standard.set(carbonMods, forKey: "panelMods.\(id)")
    }

    func panelBindingLabel(_ id: String) -> String {
        let b = panelBinding(id)
        return comboLabel(keyCode: b.code, carbonMods: b.mods)
    }

    func currentHotkeyLabel() -> String {
        let d = UserDefaults(suiteName: "com.dean.claude-sessions")
        let key = d?.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_Space
        let mods = d?.object(forKey: "hotkeyModifiers") as? Int ?? optionKey
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + (Self.keyNames[key] ?? "key\(key)")
    }

    func setHotkey(keyCode: Int, carbonMods: Int) {
        let d = UserDefaults(suiteName: "com.dean.claude-sessions")
        d?.set(keyCode, forKey: "hotkeyKeyCode")
        d?.set(carbonMods, forKey: "hotkeyModifiers")
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x43535453), id: 1)
        RegisterEventHotKey(UInt32(keyCode), UInt32(carbonMods), hotKeyID,
                            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    var recordMonitor: Any?
    // capture one modifier+key combo; esc → (-1, 0)
    func beginKeyCapture(_ done: @escaping (Int, Int) -> Void) {
        if let m = recordMonitor { NSEvent.removeMonitor(m); recordMonitor = nil }
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            func finish(_ k: Int, _ m: Int) {
                if let mon = self.recordMonitor { NSEvent.removeMonitor(mon); self.recordMonitor = nil }
                done(k, m)
            }
            if ev.keyCode == 53 { finish(-1, 0); return nil } // esc = cancel
            var carbon = 0
            if ev.modifierFlags.contains(.command) { carbon |= cmdKey }
            if ev.modifierFlags.contains(.option) { carbon |= optionKey }
            if ev.modifierFlags.contains(.control) { carbon |= controlKey }
            if ev.modifierFlags.contains(.shift) { carbon |= shiftKey }
            guard carbon != 0 else { return ev } // a bare key can't be global
            finish(Int(ev.keyCode), carbon)
            return nil
        }
    }

    func beginHotkeyCapture(_ done: @escaping (String) -> Void) {
        beginKeyCapture { [weak self] k, m in
            guard let self else { return }
            if k >= 0 { self.setHotkey(keyCode: k, carbonMods: m) }
            done(self.currentHotkeyLabel())
        }
    }

    // ── attention-jump hotkey (default ⌘⌥A) ─────────────────────
    func comboLabel(keyCode: Int, carbonMods: Int) -> String {
        var s = ""
        if carbonMods & controlKey != 0 { s += "⌃" }
        if carbonMods & optionKey != 0 { s += "⌥" }
        if carbonMods & shiftKey != 0 { s += "⇧" }
        if carbonMods & cmdKey != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "key\(keyCode)")
    }

    func currentAttentionLabel() -> String {
        let d = UserDefaults(suiteName: "com.dean.claude-sessions")
        let key = d?.object(forKey: "attentionKeyCode") as? Int ?? kVK_ANSI_A
        let mods = d?.object(forKey: "attentionModifiers") as? Int ?? (cmdKey | optionKey)
        return comboLabel(keyCode: key, carbonMods: mods)
    }

    func setAttentionHotkey(keyCode: Int, carbonMods: Int) {
        let d = UserDefaults(suiteName: "com.dean.claude-sessions")
        d?.set(keyCode, forKey: "attentionKeyCode")
        d?.set(carbonMods, forKey: "attentionModifiers")
        if let r = attentionHotKeyRef { UnregisterEventHotKey(r); attentionHotKeyRef = nil }
        let id = EventHotKeyID(signature: OSType(0x43535453), id: 2)
        RegisterEventHotKey(UInt32(keyCode), UInt32(carbonMods), id,
                            GetEventDispatcherTarget(), 0, &attentionHotKeyRef)
    }

    func jumpIndex(_ n: Int) {
        if let handler = model.hotkeyNumber {
            handler(n)
        } else {
            DispatchQueue.global().async { runAST(["jump-index", "\(n)"]) }
        }
    }

    func jumpAttention() {
        hidePanel()
        DispatchQueue.global().async { runAST(["attention"]) }
    }

    // notifications require a real bundle — skipped when run as a bare binary
    var notificationsReady = false

    func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.notificationsReady = granted
        }
    }

    // start-of-turn timestamps, for the "(4m 32s)" tag on completion
    var runStart: [String: Date] = [:]

    func notify(sid: String, status: String, title rawTitle: String) {
        guard notificationsReady else { return }
        let d = UserDefaults.standard
        switch status {
        case "waiting": guard d.object(forKey: "notifyWaiting") as? Bool ?? true else { return }
        case "input": guard d.object(forKey: "notifyInput") as? Bool ?? true else { return }
        default: guard d.object(forKey: "notifyFinished") as? Bool ?? true else { return }
        }
        var title = rawTitle.isEmpty ? "session" : rawTitle
        if status == "finished", let start = runStart[sid] {
            let e = Int(Date().timeIntervalSince(start))
            title += e >= 60 ? " (\(e / 60)m \(e % 60)s)" : " (\(e)s)"
        }
        // body = the session state, plain English. "input" is refined by
        // what the session actually asked for (question / plan / reply)
        DispatchQueue.global().async {
            // the idle ping ("waiting for your reply") is redundant when the
            // session's own tab is already on screen. Approvals and finished
            // turns always ring — those are worth interrupting for.
            if status == "input" {
                let focused = runAST(["focused-sid"], capture: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if focused == sid { return }
            }
            let body: String
            switch status {
            case "waiting": body = "Needs approval"
            case "input":
                let kind = runAST(["input-kind", sid], capture: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch kind {
                case "question": body = "Question — pick an option"
                case "plan": body = "Plan approval needed"
                default: body = "Waiting for your reply"
                }
            default: body = "Finished"
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true {
                content.sound = .default
            }
            content.userInfo = ["sid": sid]
            let req = UNNotificationRequest(identifier: sid, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["sid"] as? String {
            DispatchQueue.global().async { runAST(["jump", sid]) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // menubar mascot frames: static idle pose + the running bounce, all
    // 11 rows tall so swapping frames never shifts the icon's baseline.
    // The mascot itself is user-selectable (right-click → Claude / Codex).
    var menubarAgent = UserDefaults.standard.string(forKey: "menubarAgent") ?? "claude"
    var menubarStaticImage = NSImage()
    var menubarStatusFrames: [String: [NSImage]] = [:]
    var menubarStatus: String?
    var menubarTimer: Timer?
    var menubarFrameIdx = 0
    var lastSessions: [Session] = []

    func buildMenubarImages() {
        let empty = String(repeating: ".", count: 16)
        // emoji icon: bounce between two vertical offsets like the mascots
        if menubarAgent == "emoji", !savedEmojiIcon.isEmpty {
            let img = emojiNSImage(savedEmojiIcon, height: 16)
            func offsetFrame(_ dy: CGFloat) -> NSImage {
                let out = NSImage(size: NSSize(width: img.size.width, height: 20))
                out.lockFocus()
                img.draw(in: NSRect(x: 0, y: dy, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
                out.unlockFocus()
                return out
            }
            menubarStaticImage = offsetFrame(1)
            menubarStatusFrames = [
                "running": [offsetFrame(2), offsetFrame(0)],
                "waiting": [offsetFrame(2), offsetFrame(0)],
            ]
            return
        }
        // custom image: a GIF animates with its own frames, a PNG bounces
        if menubarAgent == "custom" {
            let frames = customIconFrames(height: 16)
            if frames.count > 1 {
                menubarStaticImage = frames[0]
                menubarStatusFrames = ["running": frames, "waiting": frames]
                return
            }
            if let img = frames.first {
                func offsetFrame(_ dy: CGFloat) -> NSImage {
                    let out = NSImage(size: NSSize(width: img.size.width, height: 18))
                    out.lockFocus()
                    img.draw(in: NSRect(x: 0, y: dy, width: img.size.width, height: 16),
                             from: .zero, operation: .sourceOver, fraction: 1)
                    out.unlockFocus()
                    return out
                }
                menubarStaticImage = offsetFrame(1)
                menubarStatusFrames = [
                    "running": [offsetFrame(2), offsetFrame(0)],
                    "waiting": [offsetFrame(2), offsetFrame(0)],
                ]
                return
            }
        }
        // codex: render the vector logo (colored) with a bounce
        if menubarAgent == "codex" {
            if let img = Optional(codexLogoNSImage(size: 17)) {
                func offsetFrame(_ dy: CGFloat) -> NSImage {
                    let out = NSImage(size: NSSize(width: 17, height: 19))
                    out.lockFocus()
                    img.draw(in: NSRect(x: 0, y: dy, width: 17, height: 17),
                             from: .zero, operation: .sourceOver, fraction: 1)
                    out.unlockFocus()
                    return out
                }
                menubarStaticImage = offsetFrame(1)
                menubarStatusFrames = [
                    "running": [offsetFrame(2), offsetFrame(0)],
                    "waiting": [offsetFrame(2), offsetFrame(0)],
                ]
                return
            }
        }
        let body = iconChoice(menubarAgent).map
        menubarStaticImage = mascotNSImage(map: [empty] + body, pixel: 1.2)
        menubarStatusFrames = [:]
        for st in ["running", "waiting"] {
            let frames: [[String]]
            switch menubarAgent {
            case "claude": frames = mascotFrames(st).frames
            case "codex": frames = codexFrames(st).frames
            default: // any character: bounce while running, !! while waiting
                if st == "running" {
                    frames = [[empty] + body, body + [empty]]
                } else {
                    frames = [[".......!!......."] + body, [empty] + body]
                }
            }
            menubarStatusFrames[st] = frames.map { mascotNSImage(map: $0, pixel: 1.2) }
        }
    }

    func setMenubarAgent(_ agent: String) {
        menubarAgent = agent
        UserDefaults.standard.set(agent, forKey: "menubarAgent")
        buildMenubarImages()
        menubarStatus = "__rebuild__" // force the timer + image to reset
        updateTitle(sessions: lastSessions)
        model.iconChoiceKey = agent  // the search-field icon follows
    }

    // right-click: a card grid of the pixel characters, under the status item
    var iconPanel: FloatingPanel?
    func showMenubarMenu() {
        if let p = iconPanel, p.isVisible { p.orderOut(nil); return }
        let p = iconPanel ?? {
            let p = FloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.delegate = self
            iconPanel = p
            return p
        }()
        p.contentViewController = NSHostingController(rootView:
            IconPickerView(current: menubarAgent) { [weak self] key in
                self?.setMenubarAgent(key)
                self?.iconPanel?.orderOut(nil)
            })
        if let v = p.contentViewController?.view {
            p.setContentSize(v.fittingSize)
        }
        p.layoutIfNeeded()
        if let btn = statusItem.button, let win = btn.window {
            let f = win.frame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - p.frame.width / 2,
                                           y: f.minY - 4))
        }
        p.makeKeyAndOrderFront(nil)
    }

    func suspendMenubarAnimation() {
        menubarTimer?.invalidate()
        menubarTimer = nil
        menubarStatus = nil
        statusItem.button?.image = menubarStaticImage
    }

    func updateTitle(sessions: [Session]) {
        if model.displayAsleep { return }
        lastSessions = sessions
        guard let button = statusItem.button else { return }
        // most attention-worthy state wins: approval ask > running
        let statuses = Set(sessions.map(\.status))
        var active: String? = ["waiting", "running"].first { statuses.contains($0) }
        // 항상 / 어텐션만 / 끄기 — a running turn can last minutes, so animating
        // it is the expensive default; approvals are brief and worth noticing
        let policy = UserDefaults.standard.string(forKey: "menubarAnimation") ?? "attention"
        if policy == "off" || (policy == "attention" && active == "running") { active = nil }
        if active != menubarStatus {
            menubarStatus = active
            menubarFrameIdx = 0
            menubarTimer?.invalidate()
            menubarTimer = nil
            if let st = active, let frames = menubarStatusFrames[st], frames.count > 1 {
                // a status-item redraw per frame is the whole cost of this
                // animation (~3% of a core), so it stays slow and, by default,
                // only runs for states that actually want the user
                let interval = frames.count > 2 ? 0.35
                    : ["running": 0.6, "waiting": 0.5, "input": 0.6][st] ?? 0.5
                menubarTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    guard let self, let st = self.menubarStatus,
                          let fr = self.menubarStatusFrames[st] else { return }
                    self.menubarFrameIdx = (self.menubarFrameIdx + 1) % fr.count
                    self.statusItem.button?.image = fr[self.menubarFrameIdx]
                }
            }
                }
            }
        }
        if let st = active, let fr = menubarStatusFrames[st] {
            button.image = fr[menubarFrameIdx % fr.count]
        } else {
            button.image = menubarStaticImage
        }
        button.title = ""
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
