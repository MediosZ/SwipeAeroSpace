import XCTest
@testable import ConfigurationSupport

final class OverviewTests: XCTestCase {
    private func workspace(
        _ name: String, windowCount: Int = 0, monitor: String = "1"
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: name,
            windows: (0..<windowCount).map {
                WindowInfo(
                    id: "\(name)-\($0)", windowId: "\($0)",
                    appName: "App", windowTitle: "Title"
                )
            },
            isFocused: false,
            monitorId: monitor,
            monitorName: monitor
        )
    }

    // MARK: parseWindowLine

    func testParseWindowLineThreeFields() {
        let win = parseWindowLine("123|Safari|Welcome")
        XCTAssertEqual(win?.windowId, "123")
        XCTAssertEqual(win?.appName, "Safari")
        XCTAssertEqual(win?.windowTitle, "Welcome")
    }

    func testParseWindowLineKeepsPipeInTitle() {
        let win = parseWindowLine("123|Terminal|git|main")
        XCTAssertEqual(win?.windowTitle, "git|main")
        XCTAssertEqual(win?.appName, "Terminal")
    }

    func testParseWindowLineEmptyTitle() {
        let win = parseWindowLine("123|Safari|")
        XCTAssertEqual(win?.windowTitle, "")
    }

    func testParseWindowLineTwoFieldsReturnsNil() {
        XCTAssertNil(parseWindowLine("123|Safari"))
    }

    func testParseWindowLineNonNumericIdReturnsNil() {
        XCTAssertNil(parseWindowLine("abc|Safari|Title"))
    }

    // MARK: move

    func testMoveClampsAtBoundaries() {
        let workspaces = [workspace("1"), workspace("2")]
        var selection = OverlaySelection(workspaceIndex: 0)
        selection.move(.left, in: workspaces)
        XCTAssertEqual(selection.workspaceIndex, 0)
        selection.move(.right, in: workspaces)
        selection.move(.right, in: workspaces)
        XCTAssertEqual(selection.workspaceIndex, 1)
    }

    func testMoveDownEntersAndWalksWindowRows() {
        let workspaces = [workspace("1", windowCount: 2)]
        var selection = OverlaySelection(workspaceIndex: 0)
        selection.move(.down, in: workspaces)
        XCTAssertEqual(selection.windowIndex, 0)
        selection.move(.down, in: workspaces)
        XCTAssertEqual(selection.windowIndex, 1)
        selection.move(.down, in: workspaces)
        XCTAssertEqual(selection.windowIndex, 1)  // clamped at last row
    }

    func testMoveDownOnWindowlessCardIsIgnored() {
        var selection = OverlaySelection(workspaceIndex: 0)
        selection.move(.down, in: [workspace("1")])
        XCTAssertNil(selection.windowIndex)
        XCTAssertEqual(selection.workspaceIndex, 0)
    }

    func testMoveLeftRightFromWindowRowReturnsToCardLevel() {
        let workspaces = [workspace("1", windowCount: 2), workspace("2")]
        var selection = OverlaySelection(workspaceIndex: 0, windowIndex: 1)
        selection.move(.right, in: workspaces)
        XCTAssertNil(selection.windowIndex)
        XCTAssertEqual(selection.workspaceIndex, 0)
        selection.move(.down, in: workspaces)
        selection.move(.left, in: workspaces)
        XCTAssertNil(selection.windowIndex)
    }

    func testMoveUpFromFirstRowReturnsToCardLevel() {
        var selection = OverlaySelection(workspaceIndex: 0, windowIndex: 0)
        selection.move(.up, in: [workspace("1", windowCount: 2)])
        XCTAssertNil(selection.windowIndex)
    }

    func testMoveUpAtCardLevelIsIgnored() {
        var selection = OverlaySelection(workspaceIndex: 0)
        selection.move(.up, in: [workspace("1", windowCount: 2)])
        XCTAssertEqual(selection.workspaceIndex, 0)
        XCTAssertNil(selection.windowIndex)
    }

    func testMoveWithEmptyWorkspacesIsNoop() {
        var selection = OverlaySelection(workspaceIndex: 3, windowIndex: 2)
        selection.move(.right, in: [])
        selection.move(.down, in: [])
        XCTAssertEqual(selection.workspaceIndex, 3)
        XCTAssertEqual(selection.windowIndex, 2)
    }

    // MARK: type

    func testTypeUniqueExactMatchJumpsImmediately() {
        var selection = OverlaySelection(workspaceIndex: 0)
        let result = selection.type("1", names: ["1", "2", "3"])
        XCTAssertEqual(result, .jump("1"))
        XCTAssertEqual(selection.typedBuffer, "")
    }

    func testTypeBuffersWhilePrefixIsAmbiguous() {
        var selection = OverlaySelection(workspaceIndex: 0)
        var result = selection.type("1", names: ["1", "12", "2"])
        XCTAssertEqual(result, .buffering("1"))
        XCTAssertEqual(selection.typedBuffer, "1")
        result = selection.type("2", names: ["1", "12", "2"])
        XCTAssertEqual(result, .jump("12"))
        XCTAssertEqual(selection.typedBuffer, "")
    }

    func testTypeResetWhenNoLongerAPrefix() {
        var selection = OverlaySelection(workspaceIndex: 0)
        _ = selection.type("1", names: ["1", "12"])
        let result = selection.type("x", names: ["1", "12"])
        XCTAssertEqual(result, .reset)
        XCTAssertEqual(selection.typedBuffer, "")
    }

    func testTypeResetReinterpretsSingleCharacter() {
        var selection = OverlaySelection(workspaceIndex: 0)
        _ = selection.type("1", names: ["1", "12", "W"])
        // "1W" matches nothing; "W" alone buffers again.
        let result = selection.type("w", names: ["1", "12", "W"])
        XCTAssertEqual(result, .jump("W"))
    }

    // MARK: overviewContentSize

    private func workspaces(_ count: Int, windowCount: Int = 1) -> [WorkspaceInfo] {
        (0..<count).map { workspace("\($0)", windowCount: windowCount) }
    }

    func testContentSizeGrowsByOneRowFrom5To6Workspaces() {
        let five = overviewContentSize(workspaces: workspaces(5), multiMonitor: false)
        let six = overviewContentSize(workspaces: workspaces(6), multiMonitor: false)
        XCTAssertEqual(
            six.height - five.height,
            OverviewMetrics.cardHeight(windowCount: 1) + OverviewMetrics.cardSpacing
        )
        XCTAssertEqual(
            six.width, five.width,
            "both fit in a single row of at most \(OverviewMetrics.maxColumns) cards"
        )
    }

    func testContentSize27WorkspacesUsesSixRows() {
        let size25 = overviewContentSize(workspaces: workspaces(25), multiMonitor: false)
        let size27 = overviewContentSize(workspaces: workspaces(27), multiMonitor: false)
        XCTAssertEqual(
            size27.height - size25.height,
            OverviewMetrics.cardHeight(windowCount: 1) + OverviewMetrics.cardSpacing
        )
    }

    func testContentSizeMultiMonitorAddsHeaderPerGroup() {
        let single = workspaces(6)
        let split = [
            workspace("1", windowCount: 1, monitor: "1"),
            workspace("2", windowCount: 1, monitor: "1"),
            workspace("3", windowCount: 1, monitor: "1"),
            workspace("4", windowCount: 1, monitor: "2"),
            workspace("5", windowCount: 1, monitor: "2"),
            workspace("6", windowCount: 1, monitor: "2"),
        ]
        let singleSize = overviewContentSize(workspaces: single, multiMonitor: false)
        let multiSize = overviewContentSize(workspaces: split, multiMonitor: true)
        XCTAssertEqual(
            multiSize.height - singleSize.height,
            2 * (OverviewMetrics.monitorHeaderHeight + OverviewMetrics.groupInnerSpacing)
                + OverviewMetrics.groupSpacing - OverviewMetrics.cardSpacing
        )
    }

    func testContentSizeEmptyWorkspaces() {
        let size = overviewContentSize(workspaces: [], multiMonitor: false)
        XCTAssertEqual(
            size.height,
            2 * OverviewMetrics.panelMargin + 2 * OverviewMetrics.contentPadding
                + OverviewMetrics.titleHeight + OverviewMetrics.titleSpacing
        )
    }

    func testContentSizeMatchesWindowCap() {
        let capped = overviewContentSize(workspaces: workspaces(1, windowCount: 9), multiMonitor: false)
        let exact = overviewContentSize(workspaces: workspaces(1, windowCount: 5), multiMonitor: false)
        XCTAssertEqual(capped.height, exact.height)
        let fewer = overviewContentSize(workspaces: workspaces(1, windowCount: 3), multiMonitor: false)
        XCTAssertEqual(
            exact.height - fewer.height,
            2 * OverviewMetrics.rowHeight
        )
    }

    // MARK: overviewMonitorGroups

    func testMonitorGroupsPreserveFirstAppearanceOrder() {
        let workspaces = [
            workspace("1", monitor: "2"),
            workspace("2", monitor: "1"),
            workspace("3", monitor: "2"),
        ]
        let groups = overviewMonitorGroups(workspaces)
        XCTAssertEqual(groups.map(\.id), ["2", "1"])
        XCTAssertEqual(groups[0].workspaces.map(\.id), ["1", "3"])
        XCTAssertEqual(groups[1].workspaces.map(\.id), ["2"])
    }
}
