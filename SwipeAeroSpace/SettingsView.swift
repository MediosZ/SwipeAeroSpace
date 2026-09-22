import SwiftUI

struct SettingsView: View {
    @AppStorage("threshold") private static var swipeThreshold: Double = 1.0
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natural") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false
    @AppStorage("fingers") private var fingers: String = "Three"
    @AppStorage("multiSwipe") private var multiSwipeEnabled: Bool = true
    @AppStorage("maxSteps") private var maxSteps: Int = 5
    @AppStorage("swipeUpOverview") private var swipeUpOverviewEnabled: Bool = true
    @AppStorage("swipeUpFingers") private var swipeUpFingers: String = "Three"
    @AppStorage("show-empty-workspaces") private var showEmptyWorkspaces: Bool = false

    @State private var numberFormatter: NumberFormatter = {
        var nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf
    }()

    let fingerOptions = ["Three", "Four"]

    var swipeManager: SwipeManager
    @ObservedObject var socketInfo: SocketInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: - Connection
            sectionHeader("Connection")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(socketInfo.socketConnected ? .green : .red)
                    Text(socketInfo.socketConnected ? "Connected to AeroSpace" : "Not connected")
                }
                if !socketInfo.socketConnected {
                    Button("Reconnect") {
                        swipeManager.connectSocket(reconnect: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - Horizontal Swipe
            sectionHeader("Horizontal Swipe")
            VStack(alignment: .leading, spacing: 12) {
                settingRow(
                    title: "Sensitivity",
                    description: "Lower values require less finger movement to switch. Default: 1.0"
                ) {
                    TextField(
                        "Sensitivity",
                        value: SettingsView.$swipeThreshold,
                        formatter: numberFormatter,
                        prompt: Text("1.0")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                }

                settingRow(
                    title: "Number of Fingers",
                    description: "How many fingers trigger a horizontal workspace switch"
                ) {
                    Picker("", selection: $fingers) {
                        ForEach(fingerOptions, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                }

                settingRow(
                    title: "Natural Swipe",
                    description: "Swipe direction matches finger movement, like trackpad scrolling"
                ) {
                    Toggle("", isOn: $naturalSwipe)
                        .labelsHidden()
                }

                settingRow(
                    title: "Wrap Around",
                    description: "Swiping past the last workspace jumps back to the first"
                ) {
                    Toggle("", isOn: $wrapWorkspace)
                        .labelsHidden()
                }

                settingRow(
                    title: "Skip Empty",
                    description: "Only land on workspaces that have windows"
                ) {
                    Toggle("", isOn: $skipEmpty)
                        .labelsHidden()
                }

                settingRow(
                    title: "Multi-Workspace Swipe",
                    description: "Longer swipes jump multiple workspaces in one gesture"
                ) {
                    Toggle("", isOn: $multiSwipeEnabled)
                        .labelsHidden()
                }

                if multiSwipeEnabled {
                    settingRow(
                        title: "Max per Swipe: \(maxSteps)",
                        description: "Maximum number of workspaces a single swipe can jump"
                    ) {
                        Slider(
                            value: Binding(
                                get: { Double(maxSteps) },
                                set: { maxSteps = Int($0) }
                            ),
                            in: 2...9,
                            step: 1
                        )
                        .frame(maxWidth: 140)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - Workspace Overview
            sectionHeader("Workspace Overview")
            VStack(alignment: .leading, spacing: 12) {
                settingRow(
                    title: "Enable Overview",
                    description: "Swipe up to see all workspaces and their apps"
                ) {
                    Toggle("", isOn: $swipeUpOverviewEnabled)
                        .labelsHidden()
                }

                if swipeUpOverviewEnabled {
                    settingRow(
                        title: "Number of Fingers",
                        description: "How many fingers trigger the workspace overview"
                    ) {
                        Picker("", selection: $swipeUpFingers) {
                            ForEach(fingerOptions, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 140)
                    }

                    settingRow(
                        title: "Show Empty Workspaces",
                        description: "Include empty workspaces in the workspace overview"
                    ) {
                        Toggle("", isOn: $showEmptyWorkspaces)
                            .labelsHidden()
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - General
            sectionHeader("General")
            VStack(alignment: .leading, spacing: 12) {
                LaunchAtLogin.Toggle {
                    Text("Launch at Login")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .padding(.vertical, 8)
        .frame(width: 600)
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func sectionDivider() -> some View {
        Divider()
            .padding(.horizontal, 24)
    }

    private func settingRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var swipeManager = SwipeManager()
    static var previews: some View {
        SettingsView(
            swipeManager: swipeManager,
            socketInfo: swipeManager.socketInfo
        )
    }
}
