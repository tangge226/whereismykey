import SwiftUI

@main
struct WhereKeyApplication: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("WhereKey", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 880, minHeight: 560)
                .task { state.start() }
                .alert("WhereKey", isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.clearError() } }
                )) {
                    if state.offersRestart {
                        Button("重新打开 WhereKey") { state.restartApplication() }
                        Button("取消", role: .cancel) { state.clearError() }
                    } else {
                        Button("好") { state.clearError() }
                    }
                } message: {
                    Text(state.errorMessage ?? "")
                }
        }
        .defaultSize(width: 1040, height: 650)

        MenuBarExtra("WhereKey", systemImage: "key.fill") {
            MenuBarContent()
                .environmentObject(state)
                .task { state.start() }
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 WhereKey") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("检查全部服务") { Task { await state.checkAll() } }
            .disabled(state.isChecking || state.snapshot.services.isEmpty)
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}
