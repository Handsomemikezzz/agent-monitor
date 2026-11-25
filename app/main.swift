// Agent Status: the menu bar app.
//
// Shows a three-colour block badge in the menu bar (waiting for you · running · finished,
// unread) and, on click, a panel listing those sessions. Click a session to jump
// back to it.
//
// All the state logic lives in bin/agent-status; this app only draws. It runs
// `agent-status status` when the state folder changes (the hooks write to it), when
// the panel opens, and, while the badge shows any session, every 30 seconds (to pick
// up the few changes that send no hook).
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
    let app: String?      // the agent's display name, e.g. "Claude"
    let bundle: String?   // its app's bundle id, for the icon
    var id: String { key }
    var appName: String { app ?? tool.capitalized }
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

    var dotNSColor: NSColor {
        switch self {
        case .waiting:
            return NSColor(name: nil) {
                $0.isDark
                    ? NSColor(srgbRed: 1.00, green: 0.83, blue: 0.20, alpha: 1)
                    : NSColor(srgbRed: 0.92, green: 0.70, blue: 0.03, alpha: 1)
            }
        case .running: return .systemGreen
        case .unread: return .systemBlue
        }
    }

    var accentNSColor: NSColor {
        switch self {
        case .waiting:
            return NSColor(name: nil) {
                $0.isDark
                    ? NSColor(srgbRed: 1.00, green: 0.83, blue: 0.20, alpha: 1)
                    : NSColor(srgbRed: 0.72, green: 0.51, blue: 0.00, alpha: 1)
            }
        case .running: return .systemGreen
        case .unread: return .systemBlue
        }
    }

    /// Solid fill for the menu bar block: saturated enough to read at a glance in any menu bar.
    var blockNSColor: NSColor {
        switch self {
        case .waiting: return NSColor(srgbRed: 1.00, green: 0.78, blue: 0.00, alpha: 1)
        case .running: return NSColor(srgbRed: 0.16, green: 0.70, blue: 0.29, alpha: 1)
        case .unread: return NSColor(srgbRed: 0.04, green: 0.48, blue: 1.00, alpha: 1)
        }
    }

    /// Count colour on a filled block: dark on yellow, white on green and blue.
    var blockTextNSColor: NSColor {
        self == .waiting ? NSColor(white: 0.10, alpha: 1) : .white
    }

    var dotColor: Color { Color(nsColor: dotNSColor) }
    var accentColor: Color { Color(nsColor: accentNSColor) }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
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
    static let noneForFilter = zh ? "当前筛选下没有会话" : "No matching sessions."
    static let seenAll = zh ? "全部标为已读" : "Mark all as seen"
    static let seenAllShort = zh ? "全部已读" : "Mark read"
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
    private var t3Watcher: DispatchSourceFileSystemObject?
    private var t3Debouncer: DispatchWorkItem?
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
        watchT3()
        // Hooks cover most changes the moment they happen (see watch()). This timer only
        // catches the few that send no hook, such as Esc in Claude Code or reading a
        // session in the app, so it runs only while there's a session on the badge.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.snap.counts.values.contains(where: { $0 > 0 }) else { return }
            self.reload()
        }
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

    /// T3 Code writes its state to SQLite WAL instead of hooks; watch it with a short debounce.
    private func watchT3() {
        t3Watcher?.cancel()
        t3Watcher = nil
        let dir = NSHomeDirectory() + "/.t3/userdata"
        let wal = dir + "/statev2.sqlite-wal"
        let watchingWal = FileManager.default.fileExists(atPath: wal)
        let path = watchingWal ? wal : dir
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let mask: DispatchSource.FileSystemEvent = watchingWal
            ? [.write, .extend, .rename, .delete]
            : [.write, .rename, .delete]
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self = self else { return }
            self.scheduleReload()
            let flags = src?.data ?? []
            if !watchingWal || flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watchT3() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        t3Watcher = src
    }

    private func scheduleReload() {
        t3Debouncer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        t3Debouncer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
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
        let q = args.first == "open" ? DispatchQueue.global(qos: .userInitiated) : work
        q.async { [self] in
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

/// One continuous pill of solid colour blocks (waiting · running · unread), each with its count.
/// Blocks with no sessions are faded so the ones that matter stand out.
func badgeImage(_ snap: Snapshot) -> NSImage {
    let height: CGFloat = 18, pillH: CGFloat = 16, radius: CGFloat = 4.5
    let minSeg: CGFloat = 20, segPad: CGFloat = 6

    let items = Kind.badgeOrder.map { kind -> (Kind, Int, String, NSFont, NSSize, CGFloat) in
        let count = snap.count(kind)
        let text = count > 99 ? "99+" : String(count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return (kind, count, text, font, size, max(minSeg, ceil(size.width) + segPad * 2))
    }
    let width = items.reduce(CGFloat(0)) { $0 + $1.5 }

    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        let pill = NSRect(x: 0, y: (height - pillH) / 2, width: width, height: pillH)
        let shape = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        var x: CGFloat = 0
        for (kind, count, text, font, size, segW) in items {
            let slice = NSRect(x: x, y: 0, width: segW, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: slice).addClip()
            (count > 0 ? kind.blockNSColor : kind.blockNSColor.withAlphaComponent(0.28)).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            let textColor = count > 0 ? kind.blockTextNSColor : NSColor.labelColor.withAlphaComponent(0.5)
            (text as NSString).draw(at: NSPoint(x: slice.midX - size.width / 2, y: pill.midY - size.height / 2),
                                    withAttributes: [.font: font, .foregroundColor: textColor])
            x += segW
        }
        return true
    }
    image.isTemplate = false
    image.cacheMode = .never
    return image
}

// MARK: - Panel

struct Actions {
    var open: (Session) -> Void
    var seenAll: () -> Void
    var openFolder: () -> Void
    var quit: () -> Void
}

struct Panel: View {
    @ObservedObject var store: Store
    let actions: Actions
    @State private var toolFilter = ""   // "" for all agents, else a session's `tool`
    @State private var kindFilter: Kind? = nil

    /// The agents that have sessions right now, in a stable order, with their counts.
    private var tools: [(tool: String, name: String, count: Int)] {
        var order: [String] = [], names: [String: String] = [:], counts: [String: Int] = [:]
        for s in store.snap.sessions {
            if counts[s.tool] == nil { order.append(s.tool); names[s.tool] = s.appName }
            counts[s.tool, default: 0] += 1
        }
        return order.sorted { names[$0]! < names[$1]! }.map { ($0, names[$0]!, counts[$0]!) }
    }

    /// The tool filter, ignored once that agent has no sessions left.
    private var activeTool: String {
        tools.contains { $0.tool == toolFilter } ? toolFilter : ""
    }

    private var sessions: [Session] {
        store.snap.sessions.filter { s in
            (activeTool.isEmpty || s.tool == activeTool)
                && (kindFilter == nil || s.kind == kindFilter?.rawValue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusStrip
            if tools.count > 1 {
                filterBar
            }
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 344)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if kindFilter != nil {
                Button(action: { kindFilter = nil }) {
                    Text(L.all)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            ForEach(Kind.badgeOrder, id: \.self) { kind in
                StatusTile(
                    kind: kind,
                    count: store.snap.count(kind),
                    selected: kindFilter == kind
                ) {
                    kindFilter = (kindFilter == kind) ? nil : kind
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        Picker("", selection: Binding(get: { activeTool }, set: { toolFilter = $0 })) {
            Text(L.all).tag("")
            ForEach(tools, id: \.tool) { t in
                Text("\(t.name) \(t.count)").tag(t.tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var list: some View {
        if store.snap.sessions.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L.emptyTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L.emptyBody)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
        } else if sessions.isEmpty {
            Text(kindFilter != nil ? L.noneForFilter : L.noneForTool)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            let content = VStack(alignment: .leading, spacing: 10) {
                ForEach(Kind.listOrder, id: \.self) { kind in
                    let group = sessions.filter { $0.kind == kind.rawValue }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle().fill(kind.dotColor).frame(width: 6.5, height: 6.5)
                                Text(L.kind(kind))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(group.count)")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                            .padding(.bottom, 3)

                            ForEach(group) { s in
                                SessionRow(session: s) { actions.open(s) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)

            if sessions.count > 6 {
                ScrollView(.vertical, showsIndicators: true) { content }
                    .frame(height: 340)
            } else {
                content
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if store.snap.count(.unread) > 0 {
                FooterButton(symbol: "checkmark.circle", label: L.seenAllShort, help: L.seenAll, action: actions.seenAll)
            }
            FooterButton(symbol: "folder", label: nil, help: L.folder, action: actions.openFolder)
            Spacer()
            FooterButton(symbol: nil, label: L.quit, help: nil, action: actions.quit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct StatusTile: View {
    let kind: Kind
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    private var active: Bool { count > 0 || selected }

    private var fillColor: Color {
        if selected { return kind.dotColor.opacity(0.16) }
        if count > 0 { return kind.dotColor.opacity(hover ? 0.14 : 0.10) }
        return Color.primary.opacity(hover ? 0.06 : 0.035)
    }

    private var strokeColor: Color {
        if selected { return kind.dotColor.opacity(0.65) }
        if count > 0 { return kind.dotColor.opacity(0.28) }
        return Color.primary.opacity(0.08)
    }

    private var strokeWidth: CGFloat {
        if selected { return 1.25 }
        return count > 0 ? 0.75 : 0.5
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(kind.dotColor).frame(width: 7, height: 7)
                    Text(L.kind(kind))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(active ? kind.accentColor : .secondary)
                        .lineLimit(1)
                }
                Text("\(count)")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(active ? .primary : .tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(strokeColor, lineWidth: strokeWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: hover)
        .onHover { hover = $0 }
    }
}

struct SessionRow: View {
    let session: Session
    let action: () -> Void
    @State private var hover = false

    private var kind: Kind { Kind(rawValue: session.kind) ?? .running }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                AppIcon(bundle: session.bundle ?? "", size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(L.ago(session.updated_at))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if kind == .waiting {
                        Text(L.status(session))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(kind.accentColor)
                            .lineLimit(1)
                        if !session.prompt.isEmpty {
                            Text(session.prompt)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(session.prompt.isEmpty ? L.status(session) : session.prompt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hover ? 0.8 : 0)
                    .frame(width: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: hover)
        .onHover { hover = $0 }
        .help(session.cwd)
    }
}

/// The agent app's own icon, or a plain symbol if that app isn't installed.
struct AppIcon: View {
    let bundle: String
    let size: CGFloat
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let img = Self.icon(bundle) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(.quaternary))
        }
    }

    static func icon(_ bundle: String) -> NSImage? {
        if let hit = cache[bundle] { return hit }
        guard !bundle.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundle] = img
        return img
    }
}

struct FooterButton: View {
    let symbol: String?
    let label: String?
    let help: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                }
                if let label {
                    Text(label).font(.system(size: 12, weight: .regular))
                }
            }
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, label == nil ? 7 : 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: hover)
        .onHover { hover = $0 }
        .optionalHelp(help)
    }
}

private extension View {
    @ViewBuilder func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
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
