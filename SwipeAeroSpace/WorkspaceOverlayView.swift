import Cocoa
import SwiftUI

class OverlayState: ObservableObject {
    @Published var hoveredWorkspace: String? = nil
    @Published var hoveredWindow: WindowInfo? = nil
    @Published var selection: OverlaySelection? = nil
    @Published var useOuterScroll: Bool = false
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var visible: Bool = false
    @Published var focusedMonitorId: String? = nil

    /// Hover wins over the keyboard cursor; all highlight/preview decisions
    /// read this instead of tracking hover and keyboard state separately.
    var activeName: String? {
        if let hovered = hoveredWorkspace {
            return hovered
        }
        if let selection, workspaces.indices.contains(selection.workspaceIndex) {
            return workspaces[selection.workspaceIndex].id
        }
        return nil
    }
}

struct WorkspaceOverlayView: View {
    let onSelect: (String) -> Void
    let onSelectWindow: (String) -> Void
    let onPreview: (String) -> Void
    let onDismiss: () -> Void
    @ObservedObject var overlayState: OverlayState
    @State private var revertTask: DispatchWorkItem? = nil

    private var hasMultipleMonitors: Bool {
        Set(overlayState.workspaces.map(\.monitorId)).count > 1
    }
    private var monitorGroups: [OverviewMonitorGroup] {
        overviewMonitorGroups(overlayState.workspaces)
    }
    private var workspaceIndexByName: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: overlayState.workspaces.enumerated().map { ($1.id, $0) }
        )
    }

    private func rows(for items: [WorkspaceInfo]) -> [[WorkspaceInfo]] {
        stride(from: 0, to: items.count, by: OverviewMetrics.maxColumns).map {
            Array(items[$0..<min($0 + OverviewMetrics.maxColumns, items.count)])
        }
    }

    private func selectionWindowIndex(flatIndex: Int) -> Int? {
        guard let selection = overlayState.selection,
            selection.workspaceIndex == flatIndex
        else { return nil }
        return selection.windowIndex
    }

    var body: some View {
        VStack(spacing: OverviewMetrics.titleSpacing) {
            header

            if overlayState.useOuterScroll {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid
                    }
                    .onChange(of: overlayState.selection?.workspaceIndex) { newIndex in
                        guard let newIndex,
                            overlayState.workspaces.indices.contains(newIndex)
                        else { return }
                        proxy.scrollTo(
                            overlayState.workspaces[newIndex].id, anchor: .center
                        )
                    }
                }
            } else {
                grid
            }
        }
        .padding(OverviewMetrics.contentPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
        .padding(OverviewMetrics.panelMargin)
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

    private var header: some View {
        HStack(spacing: 8) {
            Text("Workspaces")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            if let buffer = overlayState.selection?.typedBuffer, !buffer.isEmpty {
                Text("\(buffer)_")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .frame(height: OverviewMetrics.titleHeight)
    }

    private var grid: some View {
        let indexByName = workspaceIndexByName
        return VStack(
            spacing: hasMultipleMonitors ? OverviewMetrics.groupSpacing : OverviewMetrics.groupInnerSpacing
        ) {
            ForEach(monitorGroups) { group in
                VStack(spacing: OverviewMetrics.groupInnerSpacing) {
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
                        .frame(height: OverviewMetrics.monitorHeaderHeight)
                    }
                    ForEach(
                        Array(rows(for: group.workspaces).enumerated()),
                        id: \.offset
                    ) { _, row in
                        HStack(alignment: .top, spacing: OverviewMetrics.cardSpacing) {
                            ForEach(row) { ws in
                                let flatIndex = indexByName[ws.id] ?? 0
                                WorkspaceCard(
                                    workspace: ws,
                                    isActive: overlayState.activeName == ws.id,
                                    selectionWindowIndex: selectionWindowIndex(flatIndex: flatIndex),
                                    hoveredWindowId: overlayState.hoveredWindow?.id,
                                    onSelect: { onSelect(ws.id) },
                                    onSelectWindow: onSelectWindow,
                                    onWindowHover: { win, hovering in
                                        if hovering {
                                            overlayState.hoveredWindow = win
                                        } else if overlayState.hoveredWindow?.id == win.id {
                                            overlayState.hoveredWindow = nil
                                        }
                                    }
                                )
                                .id(ws.id)
                                .onHover { hovering in
                                    if hovering {
                                        revertTask?.cancel()
                                        revertTask = nil
                                        overlayState.hoveredWorkspace = ws.id
                                        if ws.monitorId == overlayState.focusedMonitorId {
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
}

struct WorkspaceCard: View {
    let workspace: WorkspaceInfo
    let isActive: Bool
    let selectionWindowIndex: Int?
    let hoveredWindowId: String?
    let onSelect: () -> Void
    let onSelectWindow: (String) -> Void
    let onWindowHover: (WindowInfo, Bool) -> Void

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

    private var highlighted: Bool { isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: OverviewMetrics.cardItemSpacing) {
            Button(action: onSelect) {
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
                .frame(height: OverviewMetrics.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(highlighted ? 0.3 : 0.15))
                .frame(height: 1)

            windowArea
        }
        .frame(width: OverviewMetrics.cardWidth, alignment: .leading)
        .padding(OverviewMetrics.cardPadding)
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
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var windowArea: some View {
        let areaHeight = OverviewMetrics.windowAreaHeight(
            windowCount: workspace.windows.count
        )
        if workspace.windows.isEmpty {
            Text("(empty)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(height: areaHeight, alignment: .topLeading)
        } else if workspace.windows.count > OverviewMetrics.maxVisibleRows {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    windowList
                }
                .scrollIndicators(.hidden)
                .frame(height: areaHeight)
                .onChange(of: selectionWindowIndex) { newIndex in
                    guard let newIndex,
                        workspace.windows.indices.contains(newIndex)
                    else { return }
                    proxy.scrollTo(workspace.windows[newIndex].id, anchor: .center)
                }
            }
        } else {
            windowList
                .frame(height: areaHeight, alignment: .topLeading)
        }
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(
                Array(workspace.windows.enumerated()), id: \.element.id
            ) { index, win in
                windowRow(win, index: index)
                    .frame(height: OverviewMetrics.rowHeight)
            }
        }
    }

    private func windowRow(_ win: WindowInfo, index: Int) -> some View {
        let rowHighlighted = hoveredWindowId == win.id || selectionWindowIndex == index
        return Button {
            onSelectWindow(win.windowId)
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: Self.appIcon(for: win.appName))
                    .resizable()
                    .frame(width: 15, height: 15)
                Text(win.appName)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(rowHighlighted ? Color.white.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(win.id)
        .onHover { hovering in
            onWindowHover(win, hovering)
        }
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
    private var onSelectWindowCallback: ((String) -> Void)?
    private var onPreviewCallback: ((String) -> Void)?
    private var typingTimeout: DispatchWorkItem?
    private var previewDebounce: DispatchWorkItem?
    private let overlayState = OverlayState()

    func show(
        workspaces: [WorkspaceInfo],
        focusedMonitorId: String? = nil,
        onSelect: @escaping (String) -> Void,
        onSelectWindow: @escaping (String) -> Void,
        onPreview: @escaping (String) -> Void,
        onRevert: @escaping () -> Void
    ) {
        dismiss()
        isVisible = true
        overlayState.visible = false
        overlayState.focusedMonitorId = focusedMonitorId
        overlayState.workspaces = workspaces
        overlayState.hoveredWorkspace = nil
        overlayState.hoveredWindow = nil
        overlayState.selection = workspaces.isEmpty
            ? nil
            : OverlaySelection(
                workspaceIndex: workspaces.firstIndex(where: \.isFocused) ?? 0)

        let selectHandler: (String) -> Void = { [weak self] ws in
            self?.onDismissCallback = nil  // Don't revert on select
            onSelect(ws)
            self?.dismiss()
        }
        let selectWindowHandler: (String) -> Void = { [weak self] windowId in
            self?.onDismissCallback = nil  // Don't revert on window select
            onSelectWindow(windowId)
            self?.dismiss()
        }
        onSelectCallback = selectHandler
        onSelectWindowCallback = selectWindowHandler
        onPreviewCallback = onPreview

        let view = WorkspaceOverlayView(
            onSelect: selectHandler,
            onSelectWindow: selectWindowHandler,
            onPreview: onPreview,
            onDismiss: {
                onRevert()
            },
            overlayState: overlayState
        )

        onDismissCallback = onRevert

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

        // Panel size is derived from the data, not from SwiftUI's intrinsic
        // measurement, so the phase-2 window data never outgrows the panel.
        let multiMonitor = Set(workspaces.map(\.monitorId)).count > 1
        let contentSize = overviewContentSize(
            workspaces: workspaces, multiMonitor: multiMonitor
        )
        let width = max(contentSize.width, 400)
        let height = max(contentSize.height, 200)
        overlayState.useOuterScroll = height > screenFrame.height * 0.8

        let panelWidth = min(width, screenFrame.width * 0.9)
        let panelHeight = min(height, screenFrame.height * 0.8)

        let hostingView = NSHostingView(rootView: view)
        hostingView.setFrameSize(NSSize(width: panelWidth, height: panelHeight))

        // Wrap in a view that accepts first mouse click without requiring activation
        let wrapper = FirstClickView(frame: hostingView.frame)
        hostingView.frame = wrapper.bounds
        hostingView.autoresizingMask = [.width, .height]
        wrapper.addSubview(hostingView)

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

        // Local monitor catches keyboard navigation, Escape, and clicks when
        // the panel is key. Clicks must be routed here (not in SwiftUI) so a
        // window-row click doesn't also select the workspace.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                if self.handleKeyDown(event) {
                    return nil
                }
                return event
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let screenPoint = NSEvent.mouseLocation
                if let panel = self.panel,
                    !NSPointInRect(screenPoint, panel.frame)
                {
                    self.dismiss()
                } else if let win = self.overlayState.hoveredWindow {
                    // Focus the hovered window directly
                    self.onSelectWindowCallback?(win.windowId)
                    return nil
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
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        typingTimeout?.cancel()
        typingTimeout = nil
        previewDebounce?.cancel()
        previewDebounce = nil
        onDismissCallback?()
        onDismissCallback = nil
        onSelectCallback = nil
        onSelectWindowCallback = nil
        onPreviewCallback = nil
        overlayState.hoveredWorkspace = nil
        overlayState.hoveredWindow = nil
        overlayState.selection = nil
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
            self.overlayState.useOuterScroll = false
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

    // MARK: Keyboard navigation

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !overlayState.workspaces.isEmpty else { return false }
        // Only treat bare keys as navigation/typing; Cmd+1 etc. must pass through.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        else { return false }
        switch event.keyCode {
        case 123:
            moveSelection(.left)
            return true
        case 124:
            moveSelection(.right)
            return true
        case 125:
            moveSelection(.down)
            return true
        case 126:
            moveSelection(.up)
            return true
        case 36, 76:
            activateSelection()
            return true
        default:
            guard let chars = event.charactersIgnoringModifiers,
                chars.count == 1,
                let ch = chars.first,
                ch.isLetter || ch.isNumber
            else { return false }
            handleTypedCharacter(ch)
            return true
        }
    }

    private func moveSelection(_ direction: OverviewDirection) {
        typingTimeout?.cancel()
        typingTimeout = nil
        let workspaces = overlayState.workspaces
        var selection = overlayState.selection
            ?? OverlaySelection(
                workspaceIndex: workspaces.firstIndex(where: \.isFocused) ?? 0)
        let previous = selection.workspaceIndex
        selection.typedBuffer = ""
        selection.move(direction, in: workspaces)
        overlayState.selection = selection
        if selection.workspaceIndex != previous {
            scheduleKeyboardPreview(workspaces[selection.workspaceIndex])
        }
    }

    private func handleTypedCharacter(_ character: Character) {
        typingTimeout?.cancel()
        typingTimeout = nil
        let workspaces = overlayState.workspaces
        let names = workspaces.map(\.id)
        var selection = overlayState.selection
            ?? OverlaySelection(workspaceIndex: 0)
        let result = selection.type(character, names: names)
        overlayState.selection = selection
        switch result {
        case .jump(let name):
            jumpSelection(to: name)
        case .buffering(let buffer):
            let candidates = names.filter {
                $0.lowercased().hasPrefix(buffer.lowercased())
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isVisible else { return }
                if let first = candidates.first {
                    self.jumpSelection(to: first)
                }
            }
            typingTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        case .reset:
            break
        }
    }

    private func jumpSelection(to name: String) {
        guard
            let index = overlayState.workspaces.firstIndex(where: { $0.id == name })
        else { return }
        var selection = overlayState.selection
            ?? OverlaySelection(workspaceIndex: index)
        selection.workspaceIndex = index
        selection.windowIndex = nil
        selection.typedBuffer = ""
        overlayState.selection = selection
        scheduleKeyboardPreview(overlayState.workspaces[index])
    }

    /// Keyboard preview runs a real `workspace <name>` switch on every step;
    /// coalesce rapid arrow presses so only the final stop is previewed.
    private func scheduleKeyboardPreview(_ workspace: WorkspaceInfo) {
        guard workspace.monitorId == overlayState.focusedMonitorId else { return }
        previewDebounce?.cancel()
        let name = workspace.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.onPreviewCallback?(name)
        }
        previewDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func activateSelection() {
        guard let selection = overlayState.selection else { return }
        let workspaces = overlayState.workspaces
        guard workspaces.indices.contains(selection.workspaceIndex) else { return }
        let workspace = workspaces[selection.workspaceIndex]
        if let windowIndex = selection.windowIndex,
            workspace.windows.indices.contains(windowIndex)
        {
            onSelectWindowCallback?(workspace.windows[windowIndex].windowId)
        } else {
            onSelectCallback?(workspace.id)
        }
    }
}
