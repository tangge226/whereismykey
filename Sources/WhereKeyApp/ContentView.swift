import SwiftUI
import AppKit
import WhereKeyCore

private enum MainSection: String, CaseIterable { case services = "服务", projects = "项目" }

private struct EditorPresentation: Identifiable {
    let id = UUID()
    let draft: ServiceDraft
    let keysOnly: Bool
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var section: MainSection = .services
    @State private var editorDraft: EditorPresentation?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack { Text("WhereKey").font(.system(size: 20, weight: .semibold)); Spacer() }
                HStack(spacing: 30) {
                    ForEach(MainSection.allCases, id: \.self) { item in
                        Button { section = item } label: {
                            Text(item.rawValue).font(.system(size: 16, weight: section == item ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                                .foregroundStyle(section == item ? Color.accentColor : Color.secondary)
                        }.buttonStyle(.plain).focusEffectDisabled()
                    }
                }
            }.padding(.horizontal, 28).frame(height: 58)
            Divider()
            if state.storageUnavailable {
                Label("数据未能加载，已暂停编辑。原有配置保留在本机。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).padding()
            }
            Group {
                if section == .services {
                    ServicesView(onEdit: { edit($0, keys: false) }, onManageKeys: { edit($0, keys: true) }, onAdd: { isImporting = true })
                } else {
                    ProjectsView(onAdd: { isImporting = true })
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $editorDraft) { item in
            ServiceEditor(initialDraft: item.draft, keysOnly: item.keysOnly) { editorDraft = nil }.environmentObject(state)
        }
        .sheet(isPresented: $isImporting) {
            BulkImportView(dismiss: { isImporting = false; section = .services }, manualAdd: {
                isImporting = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { editorDraft = EditorPresentation(draft: ServiceDraft(), keysOnly: false) }
            }).environmentObject(state)
        }
    }

    private func edit(_ id: UUID, keys: Bool) {
        do { editorDraft = EditorPresentation(draft: try state.makeDraft(serviceID: id), keysOnly: keys) }
        catch { state.present(error) }
    }
}

struct CatalogSidebar<Content: View>: View {
    @Binding var search: String
    let placeholder: String
    let onAdd: () -> Void
    @ViewBuilder let content: Content
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $search).textFieldStyle(.plain)
            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            content
            Spacer(minLength: 0)
            Button(action: onAdd) { Label("粘贴添加", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 5) }
                .buttonStyle(.borderedProminent).disabled(state.storageUnavailable)
            Label("本机保存", systemImage: "lock").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(.horizontal, 14).padding(.vertical, 16).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }
}


/// Share a bounded width across both catalogs and subsequent launches.
struct CatalogSplitView<Sidebar: View, Detail: View>: View {
    @AppStorage("catalogSidebarWidth") private var savedWidth = 260.0
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(220, min(520, geometry.size.width - 409))
            let width = min(max(savedWidth.isFinite ? savedWidth : 260, 220), maximum)
            HStack(spacing: 0) {
                sidebar.frame(width: width)
                SidebarResizeHandle(currentWidth: width) { requested in
                    savedWidth = min(max(requested, 220), maximum)
                }
                    .frame(width: 9, height: geometry.size.height)
                    .accessibilityElement()
                    .accessibilityLabel("调整侧栏宽度")
                    .accessibilityValue("\(Int(width))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: savedWidth = min(width + 20, maximum)
                        case .decrement: savedWidth = max(width - 20, 220)
                        @unknown default: break
                        }
                    }
                    .help("拖动调整侧栏宽度；双击恢复默认宽度")
                    .zIndex(1)
                detail.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }.coordinateSpace(name: "catalogSplit")
        }
    }
}


private struct SidebarResizeHandle: NSViewRepresentable {
    let currentWidth: CGFloat
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.currentWidth = currentWidth
        view.onResize = onResize
    }

    final class ResizeView: NSView {
        var currentWidth: CGFloat = 260
        var onResize: (CGFloat) -> Void = { _ in }
        private var startingWidth: CGFloat = 260
        private var startingX: CGFloat = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill()
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onResize(260); return }
            startingWidth = currentWidth
            startingX = event.locationInWindow.x
        }
        override func mouseDragged(with event: NSEvent) {
            onResize(startingWidth + event.locationInWindow.x - startingX)
        }
    }
}
