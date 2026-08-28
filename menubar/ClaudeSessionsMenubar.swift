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
    let sort_order: Int?
    let agent: String?
    let model: String?
    let parent: String?
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
    @Published var refreshing = false
    var moveSelection: ((Int) -> Void)?
    var arrowLR: ((Int) -> Bool)?
    var hotkeyNumber: ((Int) -> Void)?
    var enterKey: ((Bool) -> Void)?  // arg: ⌘ held (alternate agent)
    var isTextEditing: (() -> Bool)?  // an inline editor owns the keyboard
    var messageSelected: (() -> Void)?
    var actionKey: ((String) -> Bool)?
    var timer: Timer?

    func start() {
        refresh()
        loadSkills()
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
        DispatchQueue.main.async { self.refreshing = true }
        fetchUsage()
        DispatchQueue.global(qos: .utility).async {
            let out = runCST(["sessions-json"], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                self.refreshing = false
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

    struct Skill: Decodable, Equatable {
        let name: String
        let description: String
    }

    @Published var skills: [Skill] = []

    func loadSkills() {
        DispatchQueue.global(qos: .utility).async {
            let out = runCST(["skills-json"], capture: true)
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
            let out = runCST(["archive-search", q], capture: true)
            let parsed = (try? JSONDecoder().decode([Session].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async {
                self?.archive = parsed
                self?.archiveSearching = false
            }
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

    func orderInsert(_ sid: String, before: String) {
        DispatchQueue.global().async {
            runCST(["order-insert", sid, before])
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

    func stopSession(_ sid: String) {
        DispatchQueue.global().async {
            runCST(["stop-session", sid])
            self.refresh()
        }
    }

    func endSession(_ sid: String) {
        DispatchQueue.global().async {
            runCST(["end", sid])
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

    // which agent a plain "New Session" opens; the other stays one row away
    @Published var mainAgent: String = UserDefaults.standard.string(forKey: "mainAgent") ?? "claude" {
        didSet { UserDefaults.standard.set(mainAgent, forKey: "mainAgent") }
    }
    var otherAgent: String { mainAgent == "claude" ? "codex" : "claude" }

    // which pixel character fronts the app (menubar + search field)
    @Published var iconChoiceKey = UserDefaults.standard.string(forKey: "menubarAgent") ?? "generic"

    // fun usage stats (cst stats-json, cached 1h on disk)
    struct DailyStat: Decodable, Equatable { let date: String; let count: Int }
    struct Stats: Decodable, Equatable {
        let claude_total: Int
        let codex_total: Int
        let daily: [DailyStat]
    }
    @Published var stats: Stats? = nil
    func fetchStats() {
        DispatchQueue.global().async {
            let out = runCST(["stats-json"], capture: true)
            let parsed = try? JSONDecoder().decode(Stats.self, from: Data(out.utf8))
            DispatchQueue.main.async { self.stats = parsed }
        }
    }

    // quota snapshot — official percentages where available (CodexBar-style)
    struct Gauge: Identifiable, Equatable {
        let id: String       // "claude-5h" …
        let provider: String // CLAUDE / CODEX
        let window: String   // 5h / 7d
        let pct: Double      // 0-100
        let reset: String    // "↺ 3h" / ""
    }
    struct ModelUsage: Identifiable, Equatable {
        let model: String
        let tokens: Int
        var id: String { model }
    }
    @Published var gauges: [Gauge] = []
    @Published var modelUsage: [ModelUsage] = []
    @Published var usageText = ""

    func fetchUsage() {
        DispatchQueue.global().async {
            let out = runCST(["usage-json"], capture: true)
            guard let data = out.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            func resetText(secondsLeft d: Double) -> String {
                guard d > 0 else { return "" }
                if d >= 86400 { return "↺ \(Int(d / 86400))d" }
                if d >= 3600 { return "↺ \(Int(d / 3600))h" }
                return "↺ \(Int(d / 60))m"
            }
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso = ISO8601DateFormatter()
            func resetFromISO(_ s: Any?) -> String {
                guard let s = s as? String,
                      let d = isoFrac.date(from: s) ?? iso.date(from: s) else { return "" }
                return resetText(secondsLeft: d.timeIntervalSinceNow)
            }
            var g: [Gauge] = []
            if let off = obj["claude_official"] as? [String: Any] {
                if let w = off["five_hour"] as? [String: Any], let p = w["utilization"] as? Double {
                    g.append(Gauge(id: "claude-5h", provider: "CLAUDE", window: "5h",
                                   pct: p, reset: resetFromISO(w["resets_at"])))
                }
                if let w = off["seven_day"] as? [String: Any], let p = w["utilization"] as? Double {
                    g.append(Gauge(id: "claude-7d", provider: "CLAUDE", window: "7d",
                                   pct: p, reset: resetFromISO(w["resets_at"])))
                }
            }
            if let x = obj["codex"] as? [String: Any] {
                for (key, name) in [("secondary", "5h"), ("primary", "7d")] {
                    if let w = x[key] as? [String: Any], let p = w["used_percent"] as? Double {
                        var reset = ""
                        if let r = w["resets_at"] as? Double {
                            reset = resetText(secondsLeft: r - Date().timeIntervalSince1970)
                        }
                        // window_minutes tells the truth better than our label guess
                        let win = (w["window_minutes"] as? Double).map {
                            $0 >= 10080 ? "7d" : $0 >= 240 ? "5h" : "\(Int($0))m"
                        } ?? name
                        g.append(Gauge(id: "codex-\(key)", provider: "CODEX", window: win,
                                       pct: p, reset: reset))
                    }
                }
            }
            // footer summary + local-estimate fallback when no official data
            var parts: [String] = []
            for gg in g where gg.window != "5h" || gg.pct > 0 {
                if !parts.contains(where: { $0.hasPrefix(gg.provider.lowercased()) }) {
                    parts.append("\(gg.provider.lowercased()) \(Int(gg.pct.rounded()))%/\(gg.window)")
                }
            }
            if g.isEmpty, let c = obj["claude"] as? [String: Any] {
                let tok = (c["input"] as? Int ?? 0) + (c["output"] as? Int ?? 0)
                func fmtTok(_ n: Int) -> String {
                    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
                        : n >= 1_000 ? "\(n / 1_000)k" : "\(n)"
                }
                if tok > 0 { parts.append("claude \(fmtTok(tok))/5h") }
            }
            var models: [ModelUsage] = []
            if let c = obj["claude"] as? [String: Any],
               let bym = c["by_model"] as? [[String: Any]] {
                models = bym.compactMap { m in
                    guard let name = m["model"] as? String else { return nil }
                    let tok = (m["input"] as? Int ?? 0) + (m["output"] as? Int ?? 0)
                    return tok > 0 ? ModelUsage(model: name, tokens: tok) : nil
                }
            }
            let text = parts.joined(separator: "  ")
            DispatchQueue.main.async {
                self.gauges = g
                self.modelUsage = models
                self.usageText = text
            }
        }
    }

    func newSession(in dir: String, agent: String? = nil) {
        appDelegate?.hidePanel()
        let a = agent ?? mainAgent
        DispatchQueue.global().async { runCST(["new-session", dir, a]) }
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

// ── selectable icon set (original pixel characters) ──────────────
let catMap: [String] = [
    "..oo........oo..",
    "..ooo......ooo..",
    "..oooooooooooo..",
    ".oooooooooooooo.",
    ".ooo.oooooo.ooo.",
    ".oooooooooooooo.",
    ".oooooooooooooo.",
    ".oooooooooooooo.",
    "..oooooooooooo..",
    "...o.o....o.o...",
]
let ghostMap: [String] = [
    "....oooooooo....",
    "..oooooooooooo..",
    ".oooooooooooooo.",
    ".oo..oooooo..oo.",
    ".oo..oooooo..oo.",
    ".oooooooooooooo.",
    ".oooooooooooooo.",
    ".oooooooooooooo.",
    ".oooooooooooooo.",
    ".oo..oo..oo..oo.",
]
let robotMap: [String] = [
    ".......oo.......",
    "....oooooooo....",
    "...oooooooooo...",
    "...o.oooooo.o...",
    "...oooooooooo...",
    "....oooooooo....",
    "..oooooooooooo..",
    "..oooooooooooo..",
    "...oo......oo...",
    "...oo......oo...",
]
let slimeMap: [String] = [
    "................",
    ".....oooooo.....",
    "...oooooooooo...",
    "..oooooooooooo..",
    ".ooo.oooooo.ooo.",
    ".oooooooooooooo.",
    "oooooooooooooooo",
    "oooooooooooooooo",
    ".oooooooooooooo.",
    "..oooooooooooo..",
]
let starMap: [String] = [
    ".......oo.......",
    ".......oo.......",
    "......oooo......",
    "oooooooooooooooo",
    ".oooooooooooooo.",
    "...oooooooooo...",
    "....oooooooo....",
    "...oooo..oooo...",
    "..ooo......ooo..",
    "..oo........oo..",
]

// icon registry: key → (map, panel tint). claude/codex use their mascots.
// computed, not stored: top-level globals init in source order, and this
// references maps declared later in the file (codexMap segfaulted as let)
var iconChoices: [(key: String, label: String, map: [String], tint: NSColor)] { [
    ("generic", "터미널", appIconMap, NSColor.textColor.withAlphaComponent(0.75)),
    ("claude", "Claude", mascotMap, claudeOrangeNS),
    ("codex", "Codex", codexMap, NSColor(codexBlue)),
    ("cat", "고양이", catMap, NSColor.systemBrown),
    ("ghost", "고스트", ghostMap, NSColor.systemPurple),
    ("robot", "로봇", robotMap, NSColor.systemGray),
    ("slime", "슬라임", slimeMap, NSColor.systemGreen),
    ("star", "별", starMap, NSColor.systemYellow),
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
var _customIconCache: (key: String, frames: [NSImage])? = nil

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
    if let c = _customIconCache, c.key == key { return c.frames }
    var frames: [NSImage] = []
    if let img = NSImage(contentsOfFile: path) {
        if let rep = img.representations.first as? NSBitmapImageRep,
           let n = rep.value(forProperty: .frameCount) as? Int, n > 1 {
            for i in 0..<min(n, 24) {
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
    _customIconCache = (key, frames)
    return frames
}

func customIconImage(height: CGFloat) -> NSImage? { customIconFrames(height: height).first }

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
        }
        .padding(12)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12)))
    }
}

struct PixelAppIcon: View {
    var choice: String = "generic"
    var pixel: CGFloat = 3
    @Environment(\.displayScale) private var scale
    var body: some View {
        let px = quantizedPixel(pixel, scale: scale)
        if choice == "codex" {
            CodexLogoIcon().frame(width: px * 10, height: px * 10)
        } else if choice == "custom", !customIconFrames(height: px * 10).isEmpty {
            let frames = customIconFrames(height: px * 10)
            if frames.count > 1 {
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
                    if !shortModel(s.model).isEmpty {
                        Text(shortModel(s.model))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
                    }
                    Text((s.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
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
                Text(ageString(s.updated_at))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(s.status).opacity(0.13)))
                    .foregroundStyle(statusColor(s.status).opacity(0.85))
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
    case stats              // usage statistics card

    var id: String {
        switch self {
        case .label(let s): return "lbl-\(s)"
        case .header(let g): return "hdr-\(g)"
        case .session(let s, _): return s.session_id
        case .command(let id, _, _): return "cmd-\(id)"
        case .dropzone(let s): return "dz-\(s)"
        case .stats: return "stats-card"
        }
    }

    var selectable: Bool {
        switch self {
        case .label, .dropzone, .stats: return false
        default: return true
        }
    }
}

// CodexBar-style quota gauge: [provider window ███████░░░ 37% ↺4d]
struct QuotaGauge: View {
    let g: Model.Gauge
    var body: some View {
        HStack(spacing: 8) {
            Text(g.provider)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(g.provider == "CLAUDE" ? claudeOrange : codexBlue)
                .frame(width: 46, alignment: .leading)
            Text(g.window)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(g.pct >= 85 ? Color(nsColor: .systemRed)
                                   : g.pct >= 60 ? Color(nsColor: .systemOrange)
                                   : Color(nsColor: .systemGreen))
                        .frame(width: max(4, geo.size.width * min(1, g.pct / 100)))
                }
            }
            .frame(height: 7)
            Text("\(Int(g.pct.rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
            Text(g.reset)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
        }
    }
}

// pixel-flavored 14-day activity card for the "stats" command
struct StatsCard: View {
    let stats: Model.Stats
    let gauges: [Model.Gauge]
    let modelUsage: [Model.ModelUsage]
    let usageText: String

    func fmtTok(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1_000 ? "\(n / 1_000)k" : "\(n)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statBlock("\(stats.claude_total + stats.codex_total)", "총 세션")
                statBlock("\(stats.claude_total)", "claude")
                statBlock("\(stats.codex_total)", "codex")
                statBlock("\(stats.daily.last?.count ?? 0)", "오늘")
                statBlock("\(stats.daily.suffix(7).reduce(0) { $0 + $1.count })", "7일")
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("최근 14일 활동")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                let maxN = max(1, stats.daily.map { $0.count }.max() ?? 1)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(stats.daily, id: \.date) { d in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(claudeOrange.opacity(d.count == 0 ? 0.15
                                    : 0.35 + 0.65 * Double(d.count) / Double(maxN)))
                                .frame(width: 14, height: max(3, 42 * CGFloat(d.count) / CGFloat(maxN)))
                            Text(String(d.date.suffix(2)))
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .help("\(d.date): \(d.count) 세션")
                    }
                }
            }
            if !gauges.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("사용량")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                    ForEach(gauges) { QuotaGauge(g: $0) }
                }
                if !modelUsage.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("모델별 · 최근 5시간")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(1.2)
                        let maxTok = max(1, modelUsage.map { $0.tokens }.max() ?? 1)
                        ForEach(modelUsage) { m in
                            HStack(spacing: 8) {
                                Text(shortModel(m.model))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .frame(width: 66, alignment: .leading)
                                GeometryReader { geo in
                                    Capsule().fill(claudeOrange.opacity(0.75))
                                        .frame(width: max(4, geo.size.width
                                            * CGFloat(m.tokens) / CGFloat(maxTok)))
                                }
                                .frame(height: 6)
                                Text(fmtTok(m.tokens))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
            } else if !usageText.isEmpty {
                Text("⚡ \(usageText)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 2)
    }

    func statBlock(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
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
    @State private var showStats = false
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
                           parent: s.parent)
        }
    }

    var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return viewSessions }
        return viewSessions.filter {
            ($0.title ?? "").lowercased().contains(q)
                || ($0.cwd ?? "").lowercased().contains(q)
                || ($0.group ?? "").lowercased().contains(q)
        }
    }

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    // "/" mode: list Claude skills, pick one → pre-filled quick prompt
    var skillQuery: String? {
        guard query.hasPrefix("/") else { return nil }
        return String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
    }

    var skillRows: [PanelRow] {
        guard let q = skillQuery else { return [] }
        let list = q.isEmpty ? model.skills
            : model.skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        return list.prefix(12).map { .command("skill:\($0.name)", "/\($0.name)",
                                              $0.description.isEmpty ? "skill" : $0.description) }
    }

    // Raycast-style: typing matches commands right alongside sessions
    var commandRows: [PanelRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard searching, !q.isEmpty, !query.hasPrefix("/") else { return [] }
        var cmds: [(String, String, String)] = [
            ("clean", "Clean Stale Sessions", "오래된 세션 정리"),
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
        cmds.append(("stats", "Stats", "사용 통계 — 14일 활동, 세션 수, 쿼터"))
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
            let name = String(id.dropFirst(6))
            // target: the session selected before entering "/" mode, else the
            // most attention-worthy one
            let target = viewSessions.first(where: { $0.session_id == lastSessionSid })
                ?? attention.first ?? viewSessions.first
            if let t = target {
                messagingSession = t
                messageText = "/\(name) "
                query = ""
            }
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
        else if id == "quit" { NSApp.terminate(nil) }
        else if id == "agent-toggle" { model.mainAgent = model.otherAgent }
        else if id == "stats" {
            model.fetchStats()
            showStats = true
            query = ""
        }
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
            case .label, .command, .dropzone, .stats: break
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
        if !pinnedSessions.isEmpty {
            out.append(.label("PINNED"))
            out += pinnedSessions.map { .session($0, indented: false) }
        }
        let pool = filtered.filter { !$0.pinned }
            .filter { selectedChip == nil || $0.group == selectedChip }
        // fork children nest under their parent's row when both are visible —
        // but only while the child is active; a stopped child drops back to
        // its own section (ENDED/IDLE) instead of clinging to the parent
        let poolIds = Set(pool.map { $0.session_id })
        let children = Dictionary(grouping: pool.filter {
            guard let p = $0.parent, poolIds.contains(p) else { return false }
            return $0.status != "gone"
        }, by: { $0.parent! })
        let nestedIds = Set(children.values.flatMap { $0 }.map { $0.session_id })
        // everything that needs the user folds into one ATTENTION section,
        // ordered by urgency: approval ask > reply wait > finished
        let sections: [(statuses: [String], label: String)] = [
            (["waiting", "input", "finished"], "ATTENTION"),
            (["running"], "RUNNING"),
            (["done"], "IDLE"),
            (["gone"], "ENDED"),
        ]
        for (sts, label) in sections {
            let members = pool.filter { sts.contains($0.status) && !nestedIds.contains($0.session_id) }
                .sorted { a, b in
                    let ua = sts.firstIndex(of: a.status) ?? 9
                    let ub = sts.firstIndex(of: b.status) ?? 9
                    if ua != ub { return ua < ub }
                    // IDLE is pure recency; other sections honor manual order
                    if label != "IDLE" {
                        let oa = a.sort_order ?? Int.max
                        let ob = b.sort_order ?? Int.max
                        if oa != ob { return oa < ob }
                    }
                    return (a.updated_at ?? 0) > (b.updated_at ?? 0)
                }
            if members.isEmpty { continue }
            out.append(.label(label))
            for m in members {
                out.append(.session(m, indented: false))
                for c in (children[m.session_id] ?? [])
                    .sorted(by: { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }) {
                    out.append(.session(c, indented: true))
                }
            }
        }
        return out
    }

    // the navigable list, in display order
    var rows: [PanelRow] {
        if showStats { return [.stats] }
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
            case .stats: return acc + 240 + CGFloat(model.modelUsage.count) * 16
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
        case .label, .dropzone, .stats, nil: break
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
        case .stats:
            if let st = model.stats {
                StatsCard(stats: st, gauges: model.gauges,
                          modelUsage: model.modelUsage, usageText: model.usageText)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
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
                                  },
                                  renameCancel: { renamingSession = nil })
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
                        if draggedStatus == s.status {
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
        let pool = filtered.filter { !$0.pinned && $0.status == s.status }
            .filter { selectedChip == nil || $0.group == selectedChip }
            .sorted(by: manualThenRecent)
        return pool.last?.session_id == s.session_id
    }

    func draggedSameStatus(as s: Session) -> Bool {
        guard let d = draggingSessionSid,
              let dragged = viewSessions.first(where: { $0.session_id == d }) else { return false }
        return dragged.status == s.status
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
                PixelAppIcon(choice: model.iconChoiceKey, pixel: 2.2)
                TextField("Search…  (/ skills)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .rounded))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
                    .onExitCommand { appDelegate?.hidePanel(restoreFocus: true) }
                    .onChange(of: query) { q in
                        selected = 0
                        if !q.isEmpty { showStats = false }
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
                    if model.usageText.isEmpty {
                        Text("↩ 열기 · ⌘1-9 점프 · ⌃X 중지 · Tab 완성 · / 스킬")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 4) {
                            Text("⚡").font(.system(size: 10))
                                .foregroundStyle(claudeOrange)
                            Text(model.usageText)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .help("claude: 최근 5시간 토큰(로컬 추정) · codex: 공식 주간 사용률\n↩ 열기 · ⌘1-9 점프 · ⌃X 중지 · Tab 완성 · / 스킬")
                    }
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
            showStats = false
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
            model.enterKey = { activateSelected(alt: $0) }
            model.isTextEditing = {
                renamingSession != nil || editingCommand || messagingSession != nil
                    || renaming != nil || addingGroup
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
            // arrows and tab — don't steal them for list navigation
            if self.model.isTextEditing?() == true { return event }
            switch event.keyCode {
            case 125: self.model.moveSelection?(1); return nil // down
            case 126: self.model.moveSelection?(-1); return nil // up
            case 123: return self.model.arrowLR?(-1) == true ? nil : event // left
            case 124: return self.model.arrowLR?(1) == true ? nil : event // right
            case 48: self.model.messageSelected?(); return nil // tab → quick prompt
            default:
                if event.modifierFlags.contains(.command) {
                    // ⌘1..9 — jump to the badged target
                    let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                                                 22: 6, 26: 7, 28: 8, 25: 9]
                    if let n = digits[event.keyCode] {
                        self.model.hotkeyNumber?(n)
                        return nil
                    }
                    if event.keyCode == 15 { // ⌘R — refresh now
                        self.model.refresh()
                        return nil
                    }
                    if event.keyCode == 36 { // ⌘↩ — activate with the alt agent
                        self.model.enterKey?(true)
                        return nil
                    }
                }
                if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) {
                    // ⌃ actions on the selected session (less conflict-prone)
                    let shift = event.modifierFlags.contains(.shift)
                    let action: String?
                    switch (event.keyCode, shift) {
                    case (35, _): action = "pin"        // ⌃P
                    case (15, false): action = "rename" // ⌃R
                    case (8, _): action = "copyresume"  // ⌃C
                    case (7, _): action = "end"         // ⌃X
                    case (51, _): action = "ungroup"    // ⌃⌫
                    default: action = nil
                    }
                    let handled = action.flatMap { self.model.actionKey?($0) }
                    if handled == true { return nil }
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

    func showPanel() {
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

    func hidePanel(restoreFocus: Bool = false) {
        panel.orderOut(nil)
        model.panelVisible = false
        // dismissals (Esc / ⌥Space) hand focus back to where it was; action
        // paths (jump, new session…) pick their own target instead
        if restoreFocus, let p = previousApp,
           p.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            p.activate(options: [])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Raycast behavior: clicking elsewhere dismisses the panel
        if (notification.object as? NSWindow) === iconPanel {
            iconPanel?.orderOut(nil)
        } else {
            hidePanel()
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

    // menubar mascot frames: static idle pose + the running bounce, all
    // 11 rows tall so swapping frames never shifts the icon's baseline.
    // The mascot itself is user-selectable (right-click → Claude / Codex).
    var menubarAgent = UserDefaults.standard.string(forKey: "menubarAgent") ?? "generic"
    var menubarStaticImage = NSImage()
    var menubarStatusFrames: [String: [NSImage]] = [:]
    var menubarStatus: String?
    var menubarTimer: Timer?
    var menubarFrameIdx = 0
    var lastSessions: [Session] = []

    func buildMenubarImages() {
        let empty = String(repeating: ".", count: 16)
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
        p.layoutIfNeeded()
        if let btn = statusItem.button, let win = btn.window {
            let f = win.frame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - p.frame.width / 2,
                                           y: f.minY - 4))
        }
        p.makeKeyAndOrderFront(nil)
    }

    func updateTitle(sessions: [Session]) {
        lastSessions = sessions
        guard let button = statusItem.button else { return }
        // most attention-worthy state wins: approval ask > running
        let statuses = Set(sessions.map(\.status))
        let active = ["waiting", "running"].first { statuses.contains($0) }
        if active != menubarStatus {
            menubarStatus = active
            menubarFrameIdx = 0
            menubarTimer?.invalidate()
            menubarTimer = nil
            if let st = active, let frames = menubarStatusFrames[st], frames.count > 1 {
                // many-frame custom GIFs play fast; two-frame mascots stay calm
                let interval = frames.count > 2 ? 0.12
                    : ["running": 0.35, "waiting": 0.4, "input": 0.6][st] ?? 0.4
                menubarTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    guard let self, let st = self.menubarStatus,
                          let fr = self.menubarStatusFrames[st] else { return }
                    self.menubarFrameIdx = (self.menubarFrameIdx + 1) % fr.count
                    self.statusItem.button?.image = fr[self.menubarFrameIdx]
                }
            }
        }
        if let st = active, let fr = menubarStatusFrames[st] {
            button.image = fr[menubarFrameIdx % fr.count]
        } else {
            button.image = menubarStaticImage
        }
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
