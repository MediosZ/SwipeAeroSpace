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
                                            if ws.monitorId == focusedMonitorId {
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
                            let icon = NSWorkspace.shared.icon(
                                forFile: appPath(for: win.appName))
                            Image(nsImage: icon)
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

    private func appPath(for appName: String) -> String {
        "/Applications/\(appName).app"
    }
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
    private let maxColumns = 5

    private struct Coordinate {
        let display: Int
        let row: Int
        let col: Int
    }

    private func computeLayout() -> [[[WorkspaceInfo]]] {
        var seen: [String: Int] = [:]
        var groups: [[WorkspaceInfo]] = []
        for ws in overlayState.workspaces {
            if let idx = seen[ws.monitorId] {
                groups[idx].append(ws)
            } else {
                seen[ws.monitorId] = groups.count
                groups.append([ws])
            }
        }
        return groups.map { groupWorkspaces in
            stride(from: 0, to: groupWorkspaces.count, by: maxColumns).map {
                Array(groupWorkspaces[$0..<min($0 + maxColumns, groupWorkspaces.count)])
            }
        }
    }

    private func findCoordinate(id: String?, in layout: [[[WorkspaceInfo]]]) -> Coordinate? {
        guard let id = id else { return nil }
        for (dIdx, display) in layout.enumerated() {
            for (rIdx, row) in display.enumerated() {
                for (cIdx, ws) in row.enumerated() {
                    if ws.id == id {
                        return Coordinate(display: dIdx, row: rIdx, col: cIdx)
                    }
                }
            }
        }
        return nil
    }

    private func navigateGrid(dx: Int, dy: Int) {
        let layout = computeLayout()
        guard !layout.isEmpty else { return }

        guard let coord = findCoordinate(id: overlayState.hoveredWorkspace, in: layout) else {
            if let firstWs = overlayState.workspaces.first {
                selectWorkspace(firstWs.id)
            }
            return
        }

        if dx != 0 {
            // Horizontal move: wrap within the current row
            let currentRow = layout[coord.display][coord.row]
            let rowCount = currentRow.count
            let newCol = (coord.col + dx + rowCount) % rowCount
            let target = currentRow[newCol]
            selectWorkspace(target.id)
            return
        }

        if dy > 0 {
            // Down: next row in current display, or first row in next display, clamp at end
            let currentDisplay = layout[coord.display]
            if coord.row + 1 < currentDisplay.count {
                let nextRow = currentDisplay[coord.row + 1]
                let newCol = min(coord.col, nextRow.count - 1)
                selectWorkspace(nextRow[newCol].id)
            } else if coord.display + 1 < layout.count {
                let nextDisplayRow = layout[coord.display + 1][0]
                let newCol = min(coord.col, nextDisplayRow.count - 1)
                selectWorkspace(nextDisplayRow[newCol].id)
            }
            return
        }

        if dy < 0 {
            // Up: prev row in current display, or last row in prev display, clamp at top
            let currentDisplay = layout[coord.display]
            if coord.row - 1 >= 0 {
                let prevRow = currentDisplay[coord.row - 1]
                let newCol = min(coord.col, prevRow.count - 1)
                selectWorkspace(prevRow[newCol].id)
            } else if coord.display - 1 >= 0 {
                let prevDisplay = layout[coord.display - 1]
                let lastRowOfPrevDisplay = prevDisplay[prevDisplay.count - 1]
                let newCol = min(coord.col, lastRowOfPrevDisplay.count - 1)
                selectWorkspace(lastRowOfPrevDisplay[newCol].id)
            }
            return
        }
    }

    private func navigateLinear(forward: Bool) {
        let all = overlayState.workspaces
        guard !all.isEmpty else { return }
        let currentIdx = all.firstIndex(where: { $0.id == overlayState.hoveredWorkspace }) ?? 0
        let delta = forward ? 1 : -1
        let nextIdx = (currentIdx + delta + all.count) % all.count
        selectWorkspace(all[nextIdx].id)
    }

    private func selectWorkspace(_ id: String) {
        overlayState.hoveredWorkspace = id
    }

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
        overlayState.hoveredWorkspace = workspaces.first(where: { $0.isFocused })?.id ?? workspaces.first?.id

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
        let screen = NSScreen.screens.first(where: {
            NSPointInRect(mouseLocation, $0.frame)
        }) ?? NSScreen.main ?? NSScreen.screens.first!
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

        // Local monitor catches Escape, navigation keys, and clicks when the panel is key
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .keyDown {
                switch event.keyCode {
                case 53: // Escape
                    self.dismiss()
                    return nil
                case 123: // Left Arrow
                    self.navigateGrid(dx: -1, dy: 0)
                    return nil
                case 124: // Right Arrow
                    self.navigateGrid(dx: 1, dy: 0)
                    return nil
                case 125: // Down Arrow
                    self.navigateGrid(dx: 0, dy: 1)
                    return nil
                case 126: // Up Arrow
                    self.navigateGrid(dx: 0, dy: -1)
                    return nil
                case 48: // Tab
                    let isShift = event.modifierFlags.contains(.shift)
                    self.navigateLinear(forward: !isShift)
                    return nil
                case 36, 76, 49: // Return, Keypad Enter, Space
                    if let ws = self.overlayState.hoveredWorkspace {
                        self.onSelectCallback?(ws)
                    }
                    return nil
                default:
                    break
                }
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let screenPoint = NSEvent.mouseLocation
                if let panel = self.panel,
                    !NSPointInRect(screenPoint, panel.frame)
                {
                    self.dismiss()
                } else if let ws = self.overlayState.hoveredWorkspace {
                    // Select the hovered workspace on first click
                    self.onSelectCallback?(ws)
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
        if overlayState.hoveredWorkspace == nil {
            overlayState.hoveredWorkspace = workspaces.first(where: { $0.isFocused })?.id ?? workspaces.first?.id
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        onDismissCallback?()
        onDismissCallback = nil
        onSelectCallback = nil
        overlayState.hoveredWorkspace = nil
        overlayState.focusedMonitorId = nil

        // Animate out, then tear down
        withAnimation(.easeIn(duration: 0.1)) {
            overlayState.visible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            overlayState.workspaces = []
            panel?.orderOut(nil)
            panel = nil
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
