import Cocoa
import SwiftUI

struct WorkspaceInfo: Identifiable {
    let id: String  // workspace name
    let windows: [WindowInfo]
    let isFocused: Bool
    let monitorId: String
    let monitorName: String
}

struct WindowInfo: Identifiable {
    let id: String
    let appName: String
    let windowTitle: String
}

class OverlayState: ObservableObject {
    @Published var hoveredWorkspace: String? = nil
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var visible: Bool = false
    @Published var focusedMonitorId: String? = nil
}

struct WorkspaceOverlayView: View {
    let onSelect: (String) -> Void
    let onPreview: (String) -> Void
    let onDismiss: () -> Void
    @ObservedObject var overlayState: OverlayState
    @State private var revertTask: DispatchWorkItem? = nil

    private let maxColumns = 5
    private var focusedMonitorId: String? {
        overlayState.focusedMonitorId
    }
    private var hasMultipleMonitors: Bool {
        Set(overlayState.workspaces.map(\.monitorId)).count > 1
    }

    private struct MonitorGroup: Identifiable {
        let id: String  // monitorId
        let name: String
        let workspaces: [WorkspaceInfo]
    }

    private var monitorGroups: [MonitorGroup] {
        var seen: [String: Int] = [:]
        var groups: [MonitorGroup] = []
        for ws in overlayState.workspaces {
            if let idx = seen[ws.monitorId] {
                groups[idx] = MonitorGroup(
                    id: groups[idx].id,
                    name: groups[idx].name,
                    workspaces: groups[idx].workspaces + [ws]
                )
            } else {
                seen[ws.monitorId] = groups.count
                groups.append(MonitorGroup(
                    id: ws.monitorId, name: ws.monitorName, workspaces: [ws]
                ))
            }
        }
        return groups
    }

    private func rows(for items: [WorkspaceInfo]) -> [[WorkspaceInfo]] {
        stride(from: 0, to: items.count, by: maxColumns).map {
            Array(items[$0..<min($0 + maxColumns, items.count)])
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Workspaces")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: hasMultipleMonitors ? 16 : 8) {
                ForEach(monitorGroups) { group in
                    VStack(spacing: 8) {
                        if hasMultipleMonitors {
                            HStack {
                                Rectangle()
                                    .fill(.secondary.opacity(0.3))
                                    .frame(height: 1)
                                Text(group.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Rectangle()
                                    .fill(.secondary.opacity(0.3))
                                    .frame(height: 1)
                            }
                        }
                        ForEach(
                            Array(rows(for: group.workspaces).enumerated()),
                            id: \.offset
                        ) { _, row in
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(row) { ws in
                                    Button { onSelect(ws.id) } label: {
                                        WorkspaceCard(
                                            workspace: ws,
                                            isHoveredExternally: overlayState.hoveredWorkspace
                                                == ws.id
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hovering in
                                        if hovering {
                                            revertTask?.cancel()
                                            revertTask = nil
                                            overlayState.hoveredWorkspace = ws.id
                                            if ws.monitorId == focusedMonitorId {
                                                onPreview(ws.id)
                                            }
                                        } else if overlayState.hoveredWorkspace == ws.id {
                                            overlayState.hoveredWorkspace = nil
                                            let task = DispatchWorkItem {
                                                onDismiss()
                                            }
                                            revertTask = task
                                            DispatchQueue.main.asyncAfter(
                                                deadline: .now() + 0.08,
                                                execute: task)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
        .padding(24)
        .opacity(overlayState.visible ? 1 : 0)
        .offset(y: overlayState.visible ? 0 : 8)
        .scaleEffect(overlayState.visible ? 1 : 0.98)
        .onExitCommand { onDismiss() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) {
                overlayState.visible = true
            }
        }
    }
}

struct WorkspaceCard: View {
    let workspace: WorkspaceInfo
    var isHoveredExternally: Bool = false
    @State private var isHovered = false

    private static let iconCache = NSCache<NSString, NSImage>()

    private static func appIcon(for appName: String) -> NSImage {
        if let cached = iconCache.object(forKey: appName as NSString) {
            return cached
        }
        let applicationDirs = [
            "/Applications",
            "/System/Applications",
            NSString(string: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        var icon: NSImage? = nil
        for dir in applicationDirs {
            let path = "\(dir)/\(appName).app"
            if FileManager.default.fileExists(atPath: path) {
                icon = NSWorkspace.shared.icon(forFile: path)
                break
            }
        }
        let result = icon ?? NSWorkspace.shared.icon(forFileType: "app")
        iconCache.setObject(result, forKey: appName as NSString)
        return result
    }

    private var highlighted: Bool { isHovered || isHoveredExternally }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(workspace.id)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                if workspace.isFocused {
                    Circle()
                        .fill(.blue)
                        .frame(width: 7, height: 7)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(highlighted ? 0.3 : 0.15))
                .frame(height: 1)

            if workspace.windows.isEmpty {
                Text("(empty)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.windows) { win in
                        HStack(spacing: 5) {
                            Image(nsImage: Self.appIcon(for: win.appName))
                                .resizable()
                                .frame(width: 15, height: 15)
                            Text(win.appName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .background(
            workspace.isFocused
                ? Color.accentColor.opacity(highlighted ? 0.35 : 0.15)
                : Color.white.opacity(highlighted ? 0.25 : 0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(highlighted ? 0.5 : 0), lineWidth: 2)
        )
        .scaleEffect(highlighted ? 1.03 : 1.0)
        .shadow(color: .accentColor.opacity(highlighted ? 0.2 : 0), radius: 8)
        .animation(.easeOut(duration: 0.08), value: highlighted)
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
    }
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // On mouse-down, make key first so SwiftUI receives the click immediately
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

class FirstClickView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class OverlayPanelController {
    private(set) var isVisible: Bool = false
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var onDismissCallback: (() -> Void)?
    private var onSelectCallback: ((String) -> Void)?
    private let overlayState = OverlayState()

    func show(
        workspaces: [WorkspaceInfo],
        focusedMonitorId: String? = nil,
        onSelect: @escaping (String) -> Void,
        onPreview: @escaping (String) -> Void,
        onRevert: @escaping () -> Void
    ) {
        dismiss()
        isVisible = true
        overlayState.visible = false
        overlayState.focusedMonitorId = focusedMonitorId

        let selectHandler: (String) -> Void = { [weak self] ws in
            self?.onDismissCallback = nil  // Don't revert on select
            onSelect(ws)
            self?.dismiss()
        }
        self.onSelectCallback = selectHandler
        overlayState.workspaces = workspaces

        let view = WorkspaceOverlayView(
            onSelect: selectHandler,
            onPreview: { ws in
                onPreview(ws)
            },
            onDismiss: {
                onRevert()
            },
            overlayState: overlayState
        )

        self.onDismissCallback = onRevert

        let hostingView = NSHostingView(rootView: view)

        // Force layout and get intrinsic size
        let intrinsicSize = hostingView.intrinsicContentSize
        let width = max(intrinsicSize.width, 400)
        let height = max(intrinsicSize.height, 200)
        hostingView.setFrameSize(NSSize(width: width, height: height))

        // Wrap in a view that accepts first mouse click without requiring activation
        let wrapper = FirstClickView(frame: hostingView.frame)
        hostingView.frame = wrapper.bounds
        hostingView.autoresizingMask = [.width, .height]
        wrapper.addSubview(hostingView)

        // Show on the screen where the cursor is
        let mouseLocation = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: {
                NSPointInRect(mouseLocation, $0.frame)
            }) ?? NSScreen.main ?? NSScreen.screens.first
        else {
            isVisible = false
            return
        }
        let screenFrame = screen.visibleFrame

        let panelWidth = min(width, screenFrame.width * 0.9)
        let panelHeight = min(height, screenFrame.height * 0.8)

        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.midY - panelHeight / 2

        let panel = KeyablePanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        panel.contentView = wrapper

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Local monitor catches Escape and clicks when the panel is key
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let screenPoint = NSEvent.mouseLocation
                if let panel = self?.panel,
                    !NSPointInRect(screenPoint, panel.frame)
                {
                    self?.dismiss()
                } else if let ws = self?.overlayState.hoveredWorkspace {
                    // Select the hovered workspace on first click
                    self?.onSelectCallback?(ws)
                    return nil
                }
            }
            return event
        }

        // Global monitor catches clicks/Escape when another app is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                self?.dismiss()
                return
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self?.dismiss()
            }
        }
    }

    func update(workspaces: [WorkspaceInfo]) {
        overlayState.workspaces = workspaces
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        onDismissCallback?()
        onDismissCallback = nil
        onSelectCallback = nil
        overlayState.hoveredWorkspace = nil
        overlayState.focusedMonitorId = nil

        // Animate out, then tear down. Capture the closing panel so a new
        // overlay shown within the animation window isn't torn down instead.
        withAnimation(.easeIn(duration: 0.1)) {
            overlayState.visible = false
        }
        let closingPanel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            closingPanel?.orderOut(nil)
            guard let self, self.panel === closingPanel else { return }
            self.panel = nil
            self.overlayState.workspaces = []
        }

        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}
