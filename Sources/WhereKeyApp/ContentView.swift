import SwiftUI
import WhereKeyCore

private enum MainSection: String, CaseIterable {
    case services = "服务与 Key"
    case projects = "项目"
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var section: MainSection = .services
    @State private var search = ""
    @State private var editorDraft: ServiceDraft?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("", selection: $section) {
                    ForEach(MainSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $search).textFieldStyle(.plain).frame(width: 190)
                if section == .services {
                    Button { isImporting = true } label: { Label("粘贴导入", systemImage: "doc.on.clipboard") }
                    Button { editorDraft = ServiceDraft() } label: { Label("添加服务", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            Divider()
            Group {
                if section == .services {
                    ServicesView(search: search, onEdit: edit)
                } else {
                    ProjectsView(search: search)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editorDraft) { draft in
            ServiceEditor(initialDraft: draft) { editorDraft = nil }
                .environmentObject(state)
        }
        .sheet(isPresented: $isImporting) {
            BulkImportView { isImporting = false }
                .environmentObject(state)
        }
    }

    private func edit(_ id: UUID) {
        do { editorDraft = try state.makeDraft(serviceID: id) }
        catch { state.present(error) }
    }
}
