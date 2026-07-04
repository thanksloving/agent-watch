import SwiftUI

struct ApprovalsView: View {
    @StateObject private var vm = ApprovalsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.pending.isEmpty && vm.history.isEmpty {
                    ContentUnavailableView("没有审批", systemImage: "bell.slash",
                        description: Text("Claude Code 危险操作会出现在这里"))
                } else {
                    List {
                        if !vm.pending.isEmpty {
                            Section("待处理") {
                                ForEach(vm.pending) { approval in
                                    ApprovalCard(approval: approval) { decision in
                                        vm.resolve(approval, decision: decision)
                                    }
                                }
                            }
                        }
                        if !vm.history.isEmpty {
                            Section("历史") {
                                ForEach(vm.history) { approval in
                                    HStack {
                                        Text(approval.toolName).font(.caption).foregroundColor(.secondary)
                                        Spacer()
                                        Text(approval.status == .approved ? "✅" : "❌")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("审批")
        }
        .task { await vm.load() }
    }
}