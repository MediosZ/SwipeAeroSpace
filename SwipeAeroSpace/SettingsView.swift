import SwiftUI

struct SettingsView: View {
    @AppStorage("aerospace") private static var aerospace: String =
        "/opt/homebrew/bin/aerospace"
    @AppStorage("threshold") private static var swipeThreshold: Double = 0.3
    
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natrual") private var naturalSwipe: Bool = true

    @State private var isValid = true
    @State private var numberFormatter: NumberFormatter = {
        var nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf
    }()

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Form {
                HStack {
                    TextField(
                        "AeroSpace Location:", text: SettingsView.$aerospace,
                        prompt: Text("/opt/homebrew/bin/aerospace")
                    ).textFieldStyle(RoundedBorderTextFieldStyle())
                        .disableAutocorrection(true)
                        .onSubmit {
                            isValid = FileManager.default.fileExists(
                                atPath: SettingsView.aerospace)
                        }
                    Image(systemName: "circle.fill").foregroundStyle(
                        isValid ? .green : .red)
                }

                TextField(
                    "Swipe Threshold:", value: SettingsView.$swipeThreshold,
                    formatter: numberFormatter,
                    prompt: Text("0.3")
                ).textFieldStyle(RoundedBorderTextFieldStyle()).frame(
                    maxWidth: 200)
                
                VStack(alignment: .leading){
                    Toggle("Wrap Workspace", isOn: $wrapWorkspace)
                    Text("Enable to jump between first and last workspaces").foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                
                VStack(alignment: .leading){
                    Toggle("Natural Swipe", isOn: $naturalSwipe)
                    Text("Disable to use reversed swipe ").foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                
                LaunchAtLogin.Toggle {
                    Text("Launch At Login")
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)

    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
