import SwiftUI
import WhereKeyCore

struct ProjectsView: View {
    @EnvironmentObject var state: AppState
    let onAdd: () -> Void
    @State private var search = ""
    @State private var selected: UUID?
    private var projects: [ProjectRecord] {
        state.snapshot.projects.filter { project in
            search.isEmpty || project.path.localizedCaseInsensitiveContains(search) || usages(project).contains {
                $0.serviceNameSnapshot.localizedCaseInsensitiveContains(search) || $0.credentialAliasSnapshot.localizedCaseInsensitiveContains(search)
            }
        }.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }
    private var current: ProjectRecord? { projects.first { $0.id == selected } ?? projects.first }
    var body: some View {
        CatalogSplitView {
            CatalogSidebar(search: $search, placeholder: "搜索项目", onAdd: onAdd) {
                Text("项目 \(state.snapshot.projects.count)").fontWeight(.semibold)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(projects) { project in
                            Button { selected = project.id } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "folder").font(.system(size: 17)).frame(width: 22)
                                    Text(URL(fileURLWithPath: project.path).lastPathComponent).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
                                    .background(current?.id == project.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).focusEffectDisabled()
                                .help(URL(fileURLWithPath: project.path).lastPathComponent + "\n" + project.path)
                                .accessibilityLabel(URL(fileURLWithPath: project.path).lastPathComponent)
                        }
                    }
                }
            }
        } detail: {
            if let project = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Label(URL(fileURLWithPath: project.path).lastPathComponent, systemImage: "folder").font(.system(size: 25, weight: .semibold))
                        Text(shortPath(project.path)).foregroundStyle(.secondary).textSelection(.enabled)
                        if !FileManager.default.fileExists(atPath: project.path) { Label("路径不存在，历史记录保留", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.caption) }
                        HStack { Text("使用记录").font(.headline); Spacer(); Text("自动记录 · 只读").font(.caption).foregroundStyle(.secondary) }.padding(.top, 10)
                        ForEach(usages(project)) { usage in
                            let deleted = !state.snapshot.services.contains { $0.id == usage.serviceID } || (usage.credentialID != nil && !state.snapshot.credentials.contains { $0.id == usage.credentialID })
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(usage.serviceNameSnapshot).fontWeight(.medium)
                                    Text(usage.credentialAliasSnapshot).font(.caption).foregroundStyle(.secondary)
                                }
                                if deleted { Text("已删除").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(usage.lastUsedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                            Divider()
                        }
                    }.padding(32)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(search.isEmpty ? "还没有项目" : "没有匹配的项目", systemImage: "folder", description: Text(search.isEmpty ? "使用服务后，项目会自动记录在这里。" : "换个关键词试试。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func usages(_ project: ProjectRecord) -> [UsageRecord] { state.snapshot.usages.filter { $0.projectID == project.id }.sorted { $0.lastUsedAt > $1.lastUsedAt } }
    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
