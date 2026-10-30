import SwiftUI
import WhereKeyCore

struct ProjectsView: View {
    @EnvironmentObject var state: AppState
    let search: String

    private var projects: [ProjectRecord] {
        state.snapshot.projects.filter { project in
            guard !search.isEmpty else { return true }
            if project.path.localizedCaseInsensitiveContains(search) { return true }
            return usages(for: project).contains {
                $0.serviceNameSnapshot.localizedCaseInsensitiveContains(search) || $0.credentialAliasSnapshot.localizedCaseInsensitiveContains(search)
            }
        }.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    var body: some View {
        if projects.isEmpty {
            ContentUnavailableView(search.isEmpty ? "还没有项目" : "没有匹配结果", systemImage: "folder", description: Text(search.isEmpty ? "第一次通过 wherekey run 或 wherekey call 使用服务后，项目会自动出现在这里。" : "换一个关键词试试。"))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("项目路径").frame(maxWidth: .infinity, alignment: .leading)
                        Text("使用的服务 / Key").frame(width: 310, alignment: .leading)
                        Text("最近使用").frame(width: 130, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                    ForEach(projects) { project in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(shortPath(project.path)).lineLimit(2)
                                if !FileManager.default.fileExists(atPath: project.path) { Label("路径不存在", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(usages(for: project)) { usage in
                                    let deleted = !state.snapshot.services.contains { $0.id == usage.serviceID } || (usage.credentialID != nil && !state.snapshot.credentials.contains { $0.id == usage.credentialID })
                                    HStack(spacing: 4) {
                                        Text("\(usage.serviceNameSnapshot) / \(usage.credentialAliasSnapshot)")
                                        if deleted { Text("已删除").font(.caption2) }
                                    }.foregroundStyle(deleted ? .secondary : .primary)
                                }
                            }.frame(width: 310, alignment: .leading)
                            Text(project.lastUsedAt, style: .relative).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    private func usages(for project: ProjectRecord) -> [UsageRecord] {
        state.snapshot.usages.filter { $0.projectID == project.id }.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
