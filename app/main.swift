// Agent Status: the menu bar app.
//
// Shows a three-colour badge in the menu bar (waiting for you · running · finished,
// unread) and, on click, a panel listing those sessions. Click a session to jump
// back to it.
//
// All the state logic lives in bin/agent-status; this app only draws. It runs
// `agent-status status` when the state folder changes (the hooks write to it), when
// the panel opens, and every 30 seconds (to pick up what the hooks can't see).
//
// Built by `agent-status install`:
//   swiftc -O -target <arch>-apple-macos13 -o "build/Agent Status.app/Contents/MacOS/AgentStatus" app/*.swift

import AppKit
import SwiftUI

// MARK: - Data

struct Session: Codable, Identifiable, Equatable {
    let key: String
    let tool: String
    let kind: String      // waiting | running | unread
    let reason: String
    let detail: String
    let name: String
    let cwd: String
    let updated_at: Double
    let prompt: String
    var id: String { key }
}

struct Snapshot: Codable, Equatable {
    var counts: [String: Int]
    var sessions: [Session]
    func count(_ kind: Kind) -> Int { counts[kind.rawValue] ?? 0 }
}

enum Kind: String, CaseIterable {
    case waiting, running, unread

    /// Badge segment and panel order.
    static let badgeOrder: [Kind] = [.waiting, .running, .unread]
    /// List order: what needs you first.
    static let listOrder: [Kind] = [.waiting, .unread, .running]

    var fill: NSColor { NSColor(hex: ["waiting": 0xFFE066, "running": 0xB2F2BB, "unread": 0xA5D8FF][rawValue]!) }
    var edge: NSColor { NSColor(hex: ["waiting": 0xF59F00, "running": 0x2F9E44, "unread": 0x1971C2][rawValue]!) }
    var tint: Color { Color(edge) }
    var symbol: String {
        ["waiting": "hand.raised.fill", "running": "bolt.fill", "unread": "checkmark.circle.fill"][rawValue]!
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// MARK: - Strings

let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

enum L {
    static func kind(_ k: Kind) -> String {
        switch k {
        case .waiting: return zh ? "等你处理" : "Needs you"
        case .running: return zh ? "运行中" : "Running"
        case .unread: return zh ? "已完成未读" : "Unread"
        }
    }
    static func status(_ s: Session) -> String {
        switch s.kind {
        case "waiting":
            let base: String
            switch s.reason {
            case "question": base = zh ? "有问题要问你" : "Has a question"
            case "plan": base = zh ? "等你确认计划" : "Plan to review"
            default: base = zh ? "等待审批" : "Needs approval"
            }
            return s.detail.isEmpty ? base : "\(base) · \(s.detail)"
        case "unread": return zh ? "已完成" : "Finished"
        default: return zh ? "运行中" : "Running"
        }
    }
    static func ago(_ ts: Double) -> String {
        let d = max(0, Int(Date().timeIntervalSince1970 - ts))
        if d < 60 { return zh ? "刚刚" : "now" }
        if d < 3600 { return zh ? "\(d / 60) 分钟前" : "\(d / 60)m ago" }
        if d < 86400 { return zh ? "\(d / 3600) 小时前" : "\(d / 3600)h ago" }
        return zh ? "\(d / 86400) 天前" : "\(d / 86400)d ago"
    }
    static let all = zh ? "全部" : "All"
    static let emptyTitle = zh ? "一切就绪" : "All clear"
    static let emptyBody = zh ? "没有运行中或等你处理的会话" : "Nothing running or waiting for you."
    static let noneForTool = zh ? "这里没有会话" : "No sessions here."
    static let seenAll = zh ? "全部标为已读" : "Mark all as seen"
    static let folder = zh ? "打开状态目录" : "Open state folder"
    static let quit = zh ? "退出" : "Quit"
}

// MARK: - Store

final class Store: ObservableObject {
    @Published private(set) var snap = Snapshot(counts: [:], sessions: [])
    var onChange: (() -> Void)?

    let bin: String
    let stateDir: String
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var loading = false
    private var again = false
    private let work = DispatchQueue(label: "agent-status.store")

    init() {
        let env = ProcessInfo.processInfo.environment
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        bin = env["AGENT_STATUS_BIN"] ?? root.appendingPathComponent("bin/agent-status").path
        stateDir = env["AGENT_STATUS_DIR"] ?? (NSHomeDirectory() + "/.agent-status")
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.reload() }
        reload()
    }

    /// The hooks replace files in the state folder; any change there means "look again".
    private func watch() {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let fd = open(stateDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    /// Runs `agent-status status`. Calls that arrive while one is running are folded into one more run.
    func reload() {
        if loading { again = true; return }
        loading = true
        work.async { [self] in
            let data = run(["status"])
            let next = try? JSONDecoder().decode(Snapshot.self, from: data)
            DispatchQueue.main.async { [self] in
                loading = false
                if let next = next, next != snap {
                    snap = next
                    onChange?()
                }
                if again { again = false; reload() }
            }
        }
    }

    func perform(_ args: [String], then: (() -> Void)? = nil) {
        work.async { [self] in
            _ = run(args)
            DispatchQueue.main.async { self.reload(); then?() }
        }
    }

    private func run(_ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

// MARK: - Badge

/// One rounded pill in three segments, each with its count. Drawn at the screen's scale.
func badgeImage(_ snap: Snapshot) -> NSImage {
    let segW: CGFloat = 21, height: CGFloat = 18, pillH: CGFloat = 17
    let lineW: CGFloat = 1.5, radius: CGFloat = 6
    let kinds = Kind.badgeOrder
    let width = segW * CGFloat(kinds.count)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        let pill = NSRect(x: lineW / 2, y: (height - pillH) / 2 + lineW / 2,
                          width: width - lineW, height: pillH - lineW)
        let outline = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        outline.lineWidth = lineW
        for (i, kind) in kinds.enumerated() {
            let slice = NSRect(x: CGFloat(i) * segW, y: 0, width: segW, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: slice).addClip()
            kind.fill.setFill()
            outline.fill()
            kind.edge.setStroke()
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let n = snap.count(kind)
            let text = n > 99 ? "99+" : String(n)
            let size: CGFloat = text.count > 2 ? 9 : 11.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size, .semibold),
                .foregroundColor: NSColor(hex: 0x1E1E1E),
            ]
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: slice.midX - s.width / 2, y: pill.midY - s.height / 2),
                                    withAttributes: attrs)
        }
        return true
    }
    image.isTemplate = false
    return image
}

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

// MARK: - Panel

struct Actions {
    var open: (Session) -> Void
    var seenAll: () -> Void
    var openFolder: () -> Void
    var quit: () -> Void
}

enum Filter: String, CaseIterable { case all, claude, codex }

struct Panel: View {
    @ObservedObject var store: Store
    let actions: Actions
    @State private var filter: Filter = .all

    private var sessions: [Session] {
        store.snap.sessions.filter { filter == .all || $0.tool == filter.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(spacing: 10) {
                ForEach(Kind.badgeOrder, id: \.self) { StatTile(kind: $0, count: store.snap.count($0)) }
            }
            if !store.snap.sessions.isEmpty {
                Picker("", selection: $filter) {
                    Text(L.all).tag(Filter.all)
                    Text("Claude").tag(Filter.claude)
                    Text("Codex").tag(Filter.codex)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            list
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 380)
        // The popover is translucent; without this, a dark window behind it greys the panel.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.75))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Agent Status").font(.system(size: 18, weight: .bold))
            Spacer()
            HStack(spacing: 8) {
                ToolCount(tool: "claude", count: store.snap.sessions.filter { $0.tool == "claude" }.count)
                Text("·").foregroundStyle(.tertiary)
                ToolCount(tool: "codex", count: store.snap.sessions.filter { $0.tool == "codex" }.count)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }

    @ViewBuilder private var list: some View {
        if store.snap.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundColor(Kind.running.tint)
                Text(L.emptyTitle).font(.system(size: 14, weight: .semibold))
                Text(L.emptyBody).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
        } else if sessions.isEmpty {
            Text(L.noneForTool).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
        } else {
            let content = VStack(alignment: .leading, spacing: 14) {
                ForEach(Kind.listOrder, id: \.self) { kind in
                    let group = sessions.filter { $0.kind == kind.rawValue }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L.kind(kind)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(group) { s in SessionRow(session: s) { actions.open(s) } }
                        }
                    }
                }
            }
            if sessions.count > 5 {
                ScrollView { content.padding(.trailing, 4) }.frame(height: 360)
            } else {
                content
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "checkmark.circle", help: L.seenAll, action: actions.seenAll)
                .disabled(store.snap.count(.unread) == 0)
            IconButton(symbol: "folder", help: L.folder, action: actions.openFolder)
            Spacer()
            Button(action: actions.quit) {
                Text(L.quit).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }
}

struct StatTile: View {
    let kind: Kind
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 11, weight: .semibold))
                Text(L.kind(kind)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(kind.tint)
            Text("\(count)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(count == 0 ? .secondary : kind.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(kind.fill).opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind.tint.opacity(0.25), lineWidth: 1))
    }
}

struct SessionRow: View {
    let session: Session
    let action: () -> Void
    @State private var hover = false

    private var kind: Kind { Kind(rawValue: session.kind) ?? .running }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIcon(tool: session.tool, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(kind.tint).frame(width: 6, height: 6)
                        Text(L.status(session)).foregroundColor(kind.tint).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("· " + L.ago(session.updated_at)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    if !session.prompt.isEmpty {
                        Text(session.prompt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.09 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(session.cwd)
    }
}

struct ToolCount: View {
    let tool: String
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            AppIcon(tool: tool, size: 14)
            Text("\(count)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

/// The app's own icon (Claude or Codex), or a plain symbol if it isn't installed.
struct AppIcon: View {
    let tool: String
    let size: CGFloat
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let img = Self.icon(tool) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: tool == "claude" ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.55, weight: .semibold))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25).fill(Color.primary.opacity(0.08)))
        }
    }

    static func icon(_ tool: String) -> NSImage? {
        if let hit = cache[tool] { return hit }
        let bundle = tool == "claude" ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[tool] = img
        return img
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover && enabled ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let store = Store()

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggle)
        store.onChange = { [weak self] in self?.updateBadge() }
        updateBadge()

        let actions = Actions(
            open: { [weak self] s in
                self?.popover.performClose(nil)
                self?.store.perform(["open", s.key])
            },
            seenAll: { [weak self] in self?.store.perform(["seen-all"]) },
            openFolder: { [weak self] in
                guard let self = self else { return }
                self.popover.performClose(nil)
                NSWorkspace.shared.open(URL(fileURLWithPath: self.store.stateDir))
            },
            quit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: Panel(store: store, actions: actions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        // For screenshots and debugging: open the panel right away.
        if ProcessInfo.processInfo.environment["AGENT_STATUS_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.toggle()
                // The window number, for `screencapture -l`.
                print(self.popover.contentViewController?.view.window?.windowNumber ?? -1)
                fflush(stdout)
            }
        }
    }

    private func updateBadge() {
        let snap = store.snap
        item.button?.image = badgeImage(snap)
        item.button?.setAccessibilityLabel(Kind.badgeOrder.map { "\(L.kind($0)) \(snap.count($0))" }
            .joined(separator: ", "))
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
