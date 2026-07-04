import SwiftUI

struct SettingsView: View {
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("hookToken") private var hookToken = ""

    var body: some View {
        Form {
            Section("服务器") {
                TextField("VPS URL", text: $relayURL).textContentType(.URL)
                SecureField("Hook Token", text: $hookToken)
            }
            Section("关于") {
                Text("WatchApprove Pro v1.0")
            }
        }
        .frame(width: 380, height: 300)
    }
}