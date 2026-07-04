import SwiftUI

struct SettingsView: View {
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("hookToken") private var hookToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("VPS URL", text: $relayURL).textContentType(.URL).autocapitalization(.none)
                    SecureField("Hook Token", text: $hookToken).autocapitalization(.none)
                }
                Section("关于") {
                    Text("版本 1.0")
                }
            }
            .navigationTitle("设置")
        }
    }
}