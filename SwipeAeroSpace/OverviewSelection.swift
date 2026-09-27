import Foundation

struct WorkspaceInfo: Identifiable {
    let id: String  // workspace name
    let windows: [WindowInfo]
    let isFocused: Bool
    let monitorId: String
    let monitorName: String
}

struct WindowInfo: Identifiable {
    let id: String
    let windowId: String
    let appName: String
    let windowTitle: String
}

struct OverlaySelection: Equatable {
    var workspaceIndex: Int
    var windowIndex: Int?
    var typedBuffer: String

    init(
        workspaceIndex: Int = 0,
        windowIndex: Int? = nil,
        typedBuffer: String = ""
    ) {
        self.workspaceIndex = workspaceIndex
        self.windowIndex = windowIndex
        self.typedBuffer = typedBuffer
    }
}

enum OverviewDirection {
    case left
    case right
    case up
    case down
}

extension OverlaySelection {
    /// Arrow-key semantics over the flattened workspace list. At window level,
    /// left/right return to card level; down enters the rows (or moves down);
    /// up moves up and returns to card level from the first row.
    mutating func move(_ direction: OverviewDirection, in workspaces: [WorkspaceInfo]) {
        guard !workspaces.isEmpty else { return }
        workspaceIndex = min(max(workspaceIndex, 0), workspaces.count - 1)
        let windowCount = workspaces[workspaceIndex].windows.count
        switch direction {
        case .left, .right:
            if windowIndex != nil {
                windowIndex = nil
            } else if direction == .left {
                workspaceIndex = max(0, workspaceIndex - 1)
            } else {
                workspaceIndex = min(workspaces.count - 1, workspaceIndex + 1)
            }
        case .down:
            guard windowCount > 0 else { return }
            let current = windowIndex ?? -1
            windowIndex = min(current + 1, windowCount - 1)
        case .up:
            guard let current = windowIndex else { return }
            windowIndex = current == 0 ? nil : current - 1
        }
    }
}

enum OverviewTypeResult: Equatable {
    case jump(String)
    case buffering(String)
    case reset
}

extension OverlaySelection {
    /// Type-ahead state machine. Matching is case-insensitive so lowercase
    /// input reaches workspaces named with uppercase letters.
    mutating func type(_ character: Character, names: [String]) -> OverviewTypeResult {
        let appended = typedBuffer + String(character)
        var result = Self.resolve(appended, names: names)
        if case .reset = result {
            // The buffer is no longer a prefix of anything: start over by
            // re-interpreting this character alone.
            result = Self.resolve(String(character), names: names)
        }
        switch result {
        case .jump:
            typedBuffer = ""
        case .buffering(let buffer):
            typedBuffer = buffer
        case .reset:
            typedBuffer = ""
        }
        return result
    }

    private static func resolve(_ buffer: String, names: [String]) -> OverviewTypeResult {
        let lowered = buffer.lowercased()
        let candidates = names.filter { $0.lowercased().hasPrefix(lowered) }
        if candidates.isEmpty {
            return .reset
        }
        if candidates.count == 1 && candidates[0].lowercased() == lowered {
            return .jump(candidates[0])
        }
        return .buffering(buffer)
    }
}

struct OverviewMonitorGroup: Identifiable {
    let id: String  // monitorId
    let name: String
    let workspaces: [WorkspaceInfo]
}

/// Group workspaces by monitor, preserving first-appearance order.
func overviewMonitorGroups(_ workspaces: [WorkspaceInfo]) -> [OverviewMonitorGroup] {
    var order: [String] = []
    var byMonitor: [String: (name: String, items: [WorkspaceInfo])] = [:]
    for ws in workspaces {
        if byMonitor[ws.monitorId] == nil {
            order.append(ws.monitorId)
        }
        var entry = byMonitor[ws.monitorId] ?? (ws.monitorName, [])
        entry.items.append(ws)
        byMonitor[ws.monitorId] = entry
    }
    return order.map {
        OverviewMonitorGroup(
            id: $0,
            name: byMonitor[$0]?.name ?? $0,
            workspaces: byMonitor[$0]?.items ?? []
        )
    }
}

enum OverviewMetrics {
    static let cardWidth: CGFloat = 150
    static let maxColumns = 5
    static let maxVisibleRows = 5
    static let rowHeight: CGFloat = 20
    static let headerHeight: CGFloat = 24
    static let cardPadding: CGFloat = 20
    static let cardItemSpacing: CGFloat = 5
    static let cardSpacing: CGFloat = 10
    static let groupSpacing: CGFloat = 16
    static let groupInnerSpacing: CGFloat = 8
    static let monitorHeaderHeight: CGFloat = 16
    static let titleHeight: CGFloat = 22
    static let titleSpacing: CGFloat = 12
    static let contentPadding: CGFloat = 20
    static let panelMargin: CGFloat = 24

    static var cardTotalWidth: CGFloat { cardWidth + 2 * cardPadding }

    /// Empty workspaces reserve the full row area so the panel size never
    /// changes between the shell query (phase 1) and the window data (phase 2).
    static func windowAreaHeight(windowCount: Int) -> CGFloat {
        let rows = windowCount == 0 ? maxVisibleRows : min(windowCount, maxVisibleRows)
        return CGFloat(rows) * rowHeight
    }

    static func cardHeight(windowCount: Int) -> CGFloat {
        2 * cardPadding + headerHeight + 2 * cardItemSpacing + 1
            + windowAreaHeight(windowCount: windowCount)
    }
}

/// Deterministic overlay size computed from the workspace data, replacing
/// intrinsicContentSize measurement that froze before window data arrived.
func overviewContentSize(workspaces: [WorkspaceInfo], multiMonitor: Bool) -> CGSize {
    let groups = overviewMonitorGroups(workspaces)
    var maxRowWidth: CGFloat = 0
    var bodyHeight: CGFloat = 0
    for (groupIndex, group) in groups.enumerated() {
        if groupIndex > 0 {
            bodyHeight += OverviewMetrics.groupSpacing
        }
        if multiMonitor {
            bodyHeight += OverviewMetrics.monitorHeaderHeight + OverviewMetrics.groupInnerSpacing
        }
        let rows = stride(
            from: 0, to: group.workspaces.count, by: OverviewMetrics.maxColumns
        )
        for (rowIndex, rowStart) in rows.enumerated() {
            if rowIndex > 0 {
                bodyHeight += OverviewMetrics.cardSpacing
            }
            let rowEnd = min(rowStart + OverviewMetrics.maxColumns, group.workspaces.count)
            let rowItems = group.workspaces[rowStart..<rowEnd]
            bodyHeight += rowItems
                .map { OverviewMetrics.cardHeight(windowCount: $0.windows.count) }
                .max() ?? 0
            let rowWidth = CGFloat(rowItems.count) * OverviewMetrics.cardTotalWidth
                + CGFloat(rowItems.count - 1) * OverviewMetrics.cardSpacing
            maxRowWidth = max(maxRowWidth, rowWidth)
        }
    }
    let width = 2 * OverviewMetrics.panelMargin + 2 * OverviewMetrics.contentPadding + maxRowWidth
    let height = 2 * OverviewMetrics.panelMargin + 2 * OverviewMetrics.contentPadding
        + OverviewMetrics.titleHeight + OverviewMetrics.titleSpacing + bodyHeight
    return CGSize(width: width, height: height)
}

/// Parse one `list-windows` line formatted as
/// `%{window-id}|%{app-name}|%{window-title}`. Returns nil when the line is
/// malformed or the window id is not numeric — a bogus id would make the
/// row's click silently ineffective.
func parseWindowLine(_ line: String) -> WindowInfo? {
    let parts = line.split(
        separator: "|", maxSplits: 2, omittingEmptySubsequences: false
    )
    guard parts.count == 3, Int(parts[0]) != nil else { return nil }
    let windowId = String(parts[0])
    return WindowInfo(
        id: windowId,
        windowId: windowId,
        appName: String(parts[1]),
        windowTitle: String(parts[2])
    )
}
