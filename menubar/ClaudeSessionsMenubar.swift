// Claude Sessions — Raycast-style floating session switcher.
// Build: swiftc -O -o claude-sessions-menubar ClaudeSessionsMenubar.swift
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
    @Published var panelVisible = false
    var moveSelection: ((Int) -> Void)?
    var arrowLR: ((Int) -> Bool)?
    var hotkeyNumber: ((Int) -> Void)?
    var messageSelected: (() -> Void)?
    var timer: Timer?

    func start() {
        refresh()
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            // panel hidden → refresh every 15s (menubar badge only)
            if self.panelVisible || tick % 3 == 0 { self.refresh() }
        }
    }

    private var prevStatuses: [String: String] = [:]
    private var firstLoad = true

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let out = runCST(["sessions-json"], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                if parsed != self.sessions { self.sessions = parsed }
                appDelegate?.updateTitle(sessions: parsed)
                // notify on transitions into states that need the user
                if !self.firstLoad {
                    for s in parsed {
                        let old = self.prevStatuses[s.session_id]
                        if old != s.status, ["waiting", "finished", "input"].contains(s.status) {
                            appDelegate?.notify(session: s)
                        }
                    }
                }
                self.firstLoad = false
                self.prevStatuses = Dictionary(uniqueKeysWithValues: parsed.map { ($0.session_id, $0.status) })
            }
        }
    }

    @Published var archive: [Session] = []
    private var archiveTask: DispatchWorkItem?

    func searchArchive(_ query: String) {
        archiveTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { archive = []; return }
        let work = DispatchWorkItem { [weak self] in
            let out = runCST(["archive-search", q], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async { self?.archive = parsed }
        }
        archiveTask = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func sendMessage(_ sid: String, _ text: String) {
        DispatchQueue.global().async { runCST(["send", sid, text]) }
    }

    func openAll(_ members: [Session]) {
        DispatchQueue.global().async {
            for s in members {
                runCST(["jump", s.session_id])
                usleep(900_000)
            }
        }
    }

    func groupMove(_ g: String, before: String) {
        DispatchQueue.global().async {
            runCST(["group-move", g, before])
            self.refresh()
        }
    }

    func setGroupColor(_ g: String, _ color: String) {
        DispatchQueue.global().async {
            runCST(["group-color", g, color])
            self.refresh()
        }
    }

    func pinInsert(_ sid: String, before: String) {
        DispatchQueue.global().async {
            runCST(["pin-insert", sid, before])
            self.refresh()
        }
    }

    func jump(_ s: Session) {
        appDelegate?.hidePanel()
        if s.status == "archived" {
            let cwd = s.cwd ?? NSHomeDirectory()
            DispatchQueue.global().async { runCST(["resume-tab", s.session_id, cwd]) }
        } else {
            DispatchQueue.global().async { runCST(["jump", s.session_id]) }
        }
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

    func togglePin(_ sid: String) {
        DispatchQueue.global().async {
            runCST(["pin", sid])
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

    func newSession(in dir: String) {
        appDelegate?.hidePanel()
        DispatchQueue.global().async { runCST(["new-session", dir]) }
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
        DispatchQueue.global().async { runCST(["run-command", name, arg, prompt]) }
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
func snappedCell(_ x: Int, _ y: Int, _ pixel: CGFloat) -> CGRect {
    let x0 = (CGFloat(x) * pixel).rounded()
    let y0 = (CGFloat(y) * pixel).rounded()
    let x1 = (CGFloat(x + 1) * pixel).rounded()
    let y1 = (CGFloat(y + 1) * pixel).rounded()
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

func drawPixelMap(_ cg: CGContext, map: [String], pixel: CGFloat,
                  colorFor: (Character) -> NSColor?) {
    cg.setShouldAntialias(false)
    for (y, row) in map.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let c = colorFor(ch) else { continue }
            cg.setFillColor(c.cgColor)
            cg.fill(snappedCell(x, y, pixel))
        }
    }
}

struct PixelMascot: View {
    var pixel: CGFloat = 3
    var body: some View {
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                drawPixelMap(cg, map: mascotMap, pixel: pixel) { $0 == "o" ? claudeOrangeNS : nil }
            }
        }
        .frame(width: pixel * 16, height: pixel * 10)
    }
}

func mascotNSImage(pixel: CGFloat) -> NSImage {
    let size = NSSize(width: pixel * 16, height: pixel * 10)
    let img = NSImage(size: size)
    img.lockFocus()
    if let cg = NSGraphicsContext.current?.cgContext {
        cg.setShouldAntialias(false)
        // template image — the menubar tints it like every other icon
        cg.setFillColor(NSColor.black.cgColor)
        for (y, row) in mascotMap.enumerated() {
            for (x, ch) in row.enumerated() where ch == "o" {
                var r = snappedCell(x, y, pixel)
                r.origin.y = size.height - r.origin.y - r.size.height
                cg.fill(r)
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

struct StatusMascot: View {
    let status: String
    var animate: Bool = true
    var pixel: CGFloat = 1.5

    var body: some View {
        let spec = mascotFrames(status)
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

    func frameView(_ frame: [String], tint: Color) -> some View {
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                drawPixelMap(cg, map: frame, pixel: pixel) { ch in
                    switch ch {
                    case "o": return NSColor(tint)
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
        .frame(width: pixel * 16, height: pixel * 11)
    }
}

@ViewBuilder
func statusGlyph(_ status: String, animate: Bool = true) -> some View {
    StatusMascot(status: status, animate: animate)
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
    var onRename: ((Session) -> Void)? = nil
    var onMessage: ((Session) -> Void)? = nil
    @State private var hovering = false

    var name: String {
        s.title ?? ((s.cwd ?? "?") as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 9) {
            if let n = hotkeyNumber {
                Text("\(n)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                    .help("⌥\(n)")
            }
            statusGlyph(s.status, animate: animate)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Text((s.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if s.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(claudeOrange.opacity(0.7))
            }
            if !ageString(s.updated_at).isEmpty {
                Text(ageString(s.updated_at))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(s.status).opacity(0.18)))
                    .foregroundStyle(statusColor(s.status))
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
                .fill(isSelected ? claudeOrange.opacity(0.25)
                    : hovering ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .onTapGesture { model.jump(s) }
        .draggable(s.session_id)
        .contextMenu {
            Button("Jump") { model.jump(s) }
            if s.status != "archived" {
                Button(s.pinned ? "Unpin" : "Pin to top") { model.togglePin(s.session_id) }
                Button("Send message…") { onMessage?(s) }
                Button("Rename session") { onRename?(s) }
            }
            Button("Copy resume command") { model.copyResume(s) }
            if s.group != nil {
                Button("Remove from group") { model.assign(s.session_id, to: nil) }
            }
        }
        .help(s.message ?? s.cwd ?? "")
    }
}

enum PanelRow: Identifiable, Equatable {
    case label(String)      // section label (PINNED / ATTENTION)
    case header(String)     // group name, or "__ungrouped__"
    case session(Session, indented: Bool)
    case command(String, String, String) // id, title, subtitle

    var id: String {
        switch self {
        case .label(let s): return "lbl-\(s)"
        case .header(let g): return "hdr-\(g)"
        case .session(let s, _): return s.session_id
        case .command(let id, _, _): return "cmd-\(id)"
        }
    }
}

struct PixelGlyph: View {
    let map: [String]
    let color: Color
    var pixel: CGFloat = 2
    var body: some View {
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                drawPixelMap(cg, map: map, pixel: pixel) { $0 == "o" ? NSColor(color) : nil }
            }
        }
        .frame(width: pixel * CGFloat(map.first?.count ?? 8),
               height: pixel * CGFloat(map.count))
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
                Text("\(n)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                    .help("⌥\(n)")
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
    @State private var messageText = ""
    @State private var dropTarget: String? = nil
    @State private var draggingGroup: String? = nil
    @State private var pendingGroups: [String] = []
    @State private var expanded: Set<String> = []
    @State private var selected = 0
    @State private var scrollTarget: String? = nil
    @FocusState private var searchFocused: Bool
    @FocusState private var msgFocused: Bool

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

    // Raycast-style command mode: query starting with ">"
    var commandQuery: String? {
        guard query.hasPrefix(">") else { return nil }
        return String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
    }

    var commandRows: [PanelRow] {
        guard let q = commandQuery else { return [] }
        var cmds: [(String, String, String)] = [
            ("hub", "Agents Hub", "에이전트 대시보드 탭 열기"),
            ("clean", "Clean Stale Sessions", "오래된 세션 정리"),
            ("quit", "Quit Claude Sessions", "앱 종료"),
        ]
        for dir in model.recentDirs {
            let name = (dir as NSString).lastPathComponent
            cmds.append(("new:\(dir)", "New Session: \(name)",
                         dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
        }
        for (name, cmd) in model.customCommands.sorted(by: { $0.key < $1.key }) {
            let silent = cmd.hasPrefix("@")
            cmds.append(("custom:\(name)", name,
                         (silent ? "⚙︎ " : "⌘ ") + String(cmd.dropFirst(silent ? 1 : 0)).prefix(40)))
        }
        let filtered = q.isEmpty ? cmds
            : cmds.filter { $0.1.lowercased().contains(q) || $0.2.lowercased().contains(q) }
        return filtered.map { .command($0.0, $0.1, $0.2) }
    }

    // "c biddersvc 광고 로직 봐줘" → folder token + trailing initial prompt
    func splitKeywordArg(_ arg: String) -> (String, String) {
        let parts = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let first = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (first, rest)
    }

    func runPanelCommand(_ id: String) {
        if id == "kw" {
            if let kw = keywordMatch {
                let (folderToken, promptRest) = splitKeywordArg(kw.arg)
                model.runCommand(kw.name, arg: folderToken, prompt: promptRest)
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
        else if id == "quit" { NSApp.terminate(nil) }
        else if id.hasPrefix("new:") { model.newSession(in: String(id.dropFirst(4))) }
        else if id.hasPrefix("custom:") { model.runCommand(String(id.dropFirst(7))) }
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
            case .label, .command: break
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
        filtered.filter { $0.pinned }.sorted { ($0.pin_order ?? 0) < ($1.pin_order ?? 0) }
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
        let derived = Set(model.sessions.compactMap { $0.group })
        var orderOf: [String: Int] = [:]
        for s in model.sessions {
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
        guard commandQuery == nil, searching else { return nil }
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
    func keywordCompletions(template: String, arg: String) -> [(String, String)] {
        guard let r = template.range(of: #"cd ([^ ]+)/\{query\}"#, options: .regularExpression) else { return [] }
        let sub = String(template[r])
        let base = String(sub.dropFirst(3).dropLast("/{query}".count))
        let baseExp = (base as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: baseExp) else { return [] }
        let q = arg.lowercased()
        let matches = items.filter { item in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: baseExp + "/" + item, isDirectory: &isDir)
            return isDir.boolValue && !item.hasPrefix(".")
                && (q.isEmpty || item.lowercased().contains(q))
        }
        // prefix matches first, then the rest, alphabetical within each
        let sorted = matches.sorted { a, b in
            let ap = a.lowercased().hasPrefix(q), bp = b.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a.lowercased() < b.lowercased()
        }
        return sorted.prefix(8).map { ($0, baseExp + "/" + $0) }
    }

    // the navigable list, in display order
    var rows: [PanelRow] {
        if commandQuery != nil { return commandRows }
        if let kw = keywordMatch {
            var out: [PanelRow] = []
            let (folderToken, promptRest) = splitKeywordArg(kw.arg)
            let comps = keywordCompletions(template: kw.template, arg: folderToken)
            if comps.isEmpty {
                out.append(.command("kw", "\(kw.name) \(kw.arg)", String(kw.preview.prefix(50))))
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
            for st in ["waiting", "input", "finished", "running", "done", "gone"] {
                out += filtered.filter { $0.status == st }.map { .session($0, indented: false) }
            }
            let liveIds = Set(model.sessions.map { $0.session_id })
            let archived = model.archive.filter { !liveIds.contains($0.session_id) }
            if !archived.isEmpty {
                out.append(.label("ARCHIVE"))
                out += archived.map { .session($0, indented: false) }
            }
            return out
        }
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
            case .label: return acc + 24
            case .header: return acc + 34
            case .session: return acc + 47
            case .command: return acc + 42
            }
        }
        return min(max(h + 16 + (draggingGroup != nil ? 34 : 0), 100), 460)
    }

    func isSelected(_ r: PanelRow) -> Bool { rows[safe: selected]?.id == r.id }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var i = min(max(selected + delta, 0), rows.count - 1)
        // section labels are not selectable — keep stepping past them
        while case .label = rows[i] {
            let next = i + (delta >= 0 ? 1 : -1)
            if next < 0 || next >= rows.count { break }
            i = next
        }
        if case .label = rows[i] { return }
        selected = i
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
        case .command(let id, _, _): runPanelCommand(id)
        case .label, nil: break
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
            highlight: dropTarget == g && draggingGroup == nil,
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

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PixelMascot(pixel: 2.2)
                TextField("Search…  (> for commands)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .rounded))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
                    .onExitCommand { appDelegate?.hidePanel() }
                    .onChange(of: query) { q in
                        selected = 0
                        model.searchArchive(q)
                    }
                let running = model.sessions.filter { $0.status == "running" }.count
                let waiting = model.sessions.filter { $0.status == "waiting" }.count
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

            Divider().padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows) { r in
                            switch r {
                            case .label(let l):
                                HStack(spacing: 5) {
                                    Text(l)
                                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                                        .foregroundStyle(l == "ATTENTION" ? claudeOrange : Color.secondary)
                                        .tracking(1.2)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.top, 4)
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
                            case .header(let g):
                                headerRow(g)
                                    .padding(.top, 5)
                            case .session(let s, let indented):
                                let base = SessionRow(s: s, model: model, isSelected: isSelected(r),
                                                      hotkeyNumber: sessionNumbers[s.session_id],
                                                      animate: model.panelVisible,
                                                      onRename: { sess in
                                                          renamingSession = sess
                                                          renameText = sess.title ?? ""
                                                      },
                                                      onMessage: { sess in
                                                          messagingSession = sess
                                                          messageText = ""
                                                      })
                                    .padding(.leading, indented ? 16 : 0)
                                    .id(r.id)
                                if s.pinned && !searching {
                                    // drop another session here to pin it in this slot
                                    base.dropDestination(for: String.self) { items, _ in
                                        if let d = items.first, d != s.session_id {
                                            model.pinInsert(d, before: s.session_id)
                                        }
                                        return true
                                    }
                                } else {
                                    base
                                }
                            }
                        }
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
                    if let t { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(t, anchor: .center) } }
                }
            }

            if let sess = messagingSession {
                HStack(spacing: 8) {
                    Text("→ \((sess.title ?? "session").prefix(16))").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("message (headless turn)", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($msgFocused)
                        .onAppear { msgFocused = true }
                        .onSubmit {
                            let text = messageText.trimmingCharacters(in: .whitespaces)
                            if !text.isEmpty { model.sendMessage(sess.session_id, text) }
                            messagingSession = nil
                            messageText = ""
                        }
                    Button("✕") { messagingSession = nil }.buttonStyle(.plain).font(.system(size: 10))
                }
                .padding(.horizontal, 14)
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
                    Menu {
                        ForEach(model.recentDirs, id: \.self) { dir in
                            Button(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                                model.newSession(in: dir)
                            }
                        }
                        Divider()
                        Button("~ (home)") { model.newSession(in: NSHomeDirectory()) }
                    } label: {
                        Label("New session", systemImage: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.secondary)
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
            draggingGroup = nil
            dropTarget = nil
        }
        .onAppear {
            model.moveSelection = { move($0) }
            model.arrowLR = { handleLR($0) }
            model.hotkeyNumber = { handleHotkey($0) }
            model.messageSelected = {
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
            appDelegate?.hidePanel()
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
        setupNotifications()

        // arrow keys never reach SwiftUI while the search field editor has
        // focus — intercept them at the event level while the panel is key
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 125: self.model.moveSelection?(1); return nil // down
            case 126: self.model.moveSelection?(-1); return nil // up
            case 123: return self.model.arrowLR?(-1) == true ? nil : event // left
            case 124: return self.model.arrowLR?(1) == true ? nil : event // right
            case 48: self.model.messageSelected?(); return nil // tab → quick prompt
            default:
                // ⌥1..9 while the panel is open — jump to the badged target
                if event.modifierFlags.contains(.option) {
                    let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                                                 22: 6, 26: 7, 28: 8, 25: 9]
                    if let n = digits[event.keyCode] {
                        self.model.hotkeyNumber?(n)
                        return nil
                    }
                }
                return event
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
        model.panelVisible = true
        model.focusTick += 1
    }

    func hidePanel() {
        panel.orderOut(nil)
        model.panelVisible = false
    }

    func windowDidResignKey(_ notification: Notification) {
        // Raycast behavior: clicking elsewhere dismisses the panel
        hidePanel()
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

        // ⌘⌥A — jump straight to the top attention session
        let attentionID = EventHotKeyID(signature: OSType(0x43535453), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | optionKey), attentionID,
                            GetEventDispatcherTarget(), 0, &attentionHotKeyRef)

        // number jumps are panel-local (handled by the key monitor while the
        // panel is key) so they never shadow typing in other apps
    }

    var attentionHotKeyRef: EventHotKeyRef?
    var digitHotKeyRefs: [EventHotKeyRef?] = []

    func jumpIndex(_ n: Int) {
        if let handler = model.hotkeyNumber {
            handler(n)
        } else {
            DispatchQueue.global().async { runCST(["jump-index", "\(n)"]) }
        }
    }

    func jumpAttention() {
        hidePanel()
        DispatchQueue.global().async { runCST(["attention"]) }
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

    func notify(session s: Session) {
        guard notificationsReady else { return }
        let body: String
        switch s.status {
        case "waiting": body = "승인이 필요해요"
        case "input": body = "답을 기다리고 있어요"
        default: body = "작업 완료 — 결과를 확인하세요"
        }
        let content = UNMutableNotificationContent()
        content.title = s.title ?? ((s.cwd ?? "session") as NSString).lastPathComponent
        content.body = body
        content.userInfo = ["sid": s.session_id]
        let req = UNNotificationRequest(identifier: s.session_id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["sid"] as? String {
            DispatchQueue.global().async { runCST(["jump", sid]) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func updateTitle(sessions: [Session]) {
        guard let button = statusItem.button else { return }
        // always the mascot; status rides in the text next to it
        button.image = mascotNSImage(pixel: 1.6)
        // only sessions blocked on an approval (permission prompt)
        let n = sessions.filter { $0.status == "waiting" }.count
        button.title = n > 0 ? " \(n)" : ""
        button.imagePosition = .imageLeading
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
