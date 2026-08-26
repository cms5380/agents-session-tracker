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
    var hotkeyNumber: ((Int) -> Void)?
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

struct PixelMascot: View {
    var pixel: CGFloat = 3
    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in mascotMap.enumerated() {
                for (x, ch) in row.enumerated() where ch == "o" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                         width: pixel, height: pixel)),
                             with: .color(claudeOrange))
                }
            }
        }
        .frame(width: pixel * 16, height: pixel * 10)
    }
}

func mascotNSImage(pixel: CGFloat) -> NSImage {
    let size = NSSize(width: pixel * 16, height: pixel * 10)
    let img = NSImage(size: size)
    img.lockFocus()
    claudeOrangeNS.setFill()
    for (y, row) in mascotMap.enumerated() {
        for (x, ch) in row.enumerated() where ch == "o" {
            NSRect(x: CGFloat(x) * pixel,
                   y: size.height - CGFloat(y + 1) * pixel,
                   width: pixel, height: pixel).fill()
        }
    }
    img.unlockFocus()
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
        return ([f], 1, claudeOrange.opacity(0.3))
    default: // idle — sleepy eyes, drifting z
        let z1 = "..............z."
        let z2 = ".............z.."
        let f1 = [z1] + mascotBody(eyes: "sleepy", legs: "a")
        let f2 = [z2] + mascotBody(eyes: "sleepy", legs: "a")
        return ([f1, f2], 1.0, claudeOrange.opacity(0.55))
    }
}

struct StatusMascot: View {
    let status: String
    var pixel: CGFloat = 1.5

    var body: some View {
        let spec = mascotFrames(status)
        TimelineView(.periodic(from: .now, by: spec.interval)) { timeline in
            let idx = spec.frames.count > 1
                ? Int(timeline.date.timeIntervalSince1970 / spec.interval) % spec.frames.count
                : 0
            Canvas { ctx, _ in
                for (y, row) in spec.frames[idx].enumerated() {
                    for (x, ch) in row.enumerated() {
                        let rect = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                          width: pixel, height: pixel)
                        switch ch {
                        case "o": ctx.fill(Path(rect), with: .color(spec.tint))
                        case "g": ctx.fill(Path(rect), with: .color(Color(nsColor: .systemGreen)))
                        case "?": ctx.fill(Path(rect), with: .color(Color(nsColor: .systemBlue)))
                        case "!": ctx.fill(Path(rect), with: .color(Color(nsColor: .systemOrange)))
                        case "z": ctx.fill(Path(rect), with: .color(Color(nsColor: .systemGray)))
                        case "-": ctx.fill(Path(rect), with: .color(Color(red: 0.45, green: 0.2, blue: 0.13)))
                        default: break
                        }
                    }
                }
            }
            .frame(width: pixel * 16, height: pixel * 11)
        }
    }
}

@ViewBuilder
func statusGlyph(_ status: String) -> some View {
    StatusMascot(status: status)
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
    var onRename: ((Session) -> Void)? = nil
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
                    .help("⌃⌥\(n)")
            }
            statusGlyph(s.status)
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
                .fill(isSelected ? claudeOrange.opacity(0.25)
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
    var hotkeyNumber: Int? = nil
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if let n = hotkeyNumber {
                Text("\(n)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                    .help("⌃⌥\(n)")
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(name == "__ungrouped__" ? "🌊" : "📁").font(.system(size: 12))
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

    static let attentionOrder = ["waiting": 0, "input": 1, "finished": 2, "running": 3]

    // ⌃⌥N targets follow the visible structure: attention sessions and
    // expanded members get numbers; a collapsed group gets one number itself
    enum HotkeyTarget {
        case session(Session)
        case group(String)
    }

    var hotkeyTargets: [HotkeyTarget] {
        var out: [HotkeyTarget] = []
        for r in rows {
            switch r {
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

    var attention: [Session] {
        filtered.filter { Self.attentionOrder[$0.status] != nil }
            .sorted { a, b in
                let pa = Self.attentionOrder[a.status] ?? 9
                let pb = Self.attentionOrder[b.status] ?? 9
                if pa != pb { return pa < pb }
                return (a.updated_at ?? 0) > (b.updated_at ?? 0)
            }
    }

    var groups: [String] {
        let derived = Set(model.sessions.compactMap { $0.group })
        return Array(derived.union(Set(pendingGroups))).sorted()
    }

    func restMembers(_ g: String?) -> [Session] {
        filtered.filter { $0.group == g && Self.attentionOrder[$0.status] == nil }
    }

    // the navigable list, in display order
    var rows: [PanelRow] {
        if searching {
            var out: [PanelRow] = []
            for st in ["waiting", "input", "finished", "running", "done", "gone"] {
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
        let hasAttention = members.contains { ["waiting", "input", "finished"].contains($0.status) }
        return GroupHeaderRow(
            name: g,
            count: members.count,
            hasAttention: hasAttention,
            expanded: expanded.contains(g),
            isSelected: isSelected(.header(g)),
            highlight: dropTarget == g,
            hotkeyNumber: groupNumbers[g]
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
            HStack(spacing: 10) {
                PixelMascot(pixel: 2.2)
                TextField("Search sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .rounded))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
                    .onExitCommand { appDelegate?.hidePanel() }
                    .onChange(of: query) { _ in selected = 0 }
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
                        if !searching && !attention.isEmpty {
                            HStack(spacing: 5) {
                                Text("ATTENTION")
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .foregroundStyle(claudeOrange)
                                    .tracking(1.2)
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
                                           hotkeyNumber: sessionNumbers[s.session_id],
                                           onRename: { sess in
                                               renamingSession = sess
                                               renameText = sess.title ?? ""
                                           })
                                    .padding(.leading, indented ? 16 : 0)
                                    .id(r.id)
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
            model.hotkeyNumber = { handleHotkey($0) }
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
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
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
                            GetApplicationEventTarget(), 0, &hotKeyRef)

        // ⌃⌥A — jump straight to the top attention session
        let attentionID = EventHotKeyID(signature: OSType(0x43535453), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey), attentionID,
                            GetApplicationEventTarget(), 0, &attentionHotKeyRef)

        // ⌃⌥1..9 — jump to the Nth session (canonical order, matches badges)
        let digitCodes: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                 kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digitCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x43535453), id: UInt32(10 + i))
            RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), id,
                                GetApplicationEventTarget(), 0, &ref)
            digitHotKeyRefs.append(ref)
        }
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

    func updateTitle(sessions: [Session]) {
        let waiting = sessions.filter { $0.status == "waiting" }.count
        let running = sessions.filter { $0.status == "running" }.count
        guard let button = statusItem.button else { return }
        if waiting > 0 {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange, .labelColor]))
            button.title = " \(waiting)"
        } else if sessions.contains(where: { $0.status == "input" }) {
            let n = sessions.filter { $0.status == "input" }.count
            button.image = mascotNSImage(pixel: 1.6)
            button.title = " ?\(n)"
        } else if sessions.contains(where: { $0.status == "finished" }) {
            let n = sessions.filter { $0.status == "finished" }.count
            button.image = mascotNSImage(pixel: 1.6)
            button.title = " ✓\(n)"
        } else if running > 0 {
            button.image = mascotNSImage(pixel: 1.6)
            button.title = " \(running)"
        } else {
            button.image = mascotNSImage(pixel: 1.6)
            button.title = ""
        }
        button.imagePosition = .imageLeading
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
