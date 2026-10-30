import SwiftUI
import WhereKeyCore

struct ServicesView: View {
    @EnvironmentObject var state: AppState
    let search: String
    let onEdit: (UUID) -> Void
    @State private var expanded = Set<UUID>()
    @State private var pendingDelete: ServiceRecord?

    private var services: [ServiceRecord] {
        state.snapshot.services
            .filter { service in
                search.isEmpty || service.name.localizedCaseInsensitiveContains(search) ||
                state.snapshot.credentials.filter { $0.serviceID == service.id }.contains { $0.alias.localizedCaseInsensitiveContains(search) } ||
                state.projectPaths(serviceID: service.id).contains { $0.localizedCaseInsensitiveContains(search) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if services.isEmpty {
            ContentUnavailableView(search.isEmpty ? "还没有服务" : "没有匹配结果", systemImage: search.isEmpty ? "key" : "magnifyingglass", description: Text(search.isEmpty ? "添加一个 API Key 或 curl 服务即可开始。" : "换一个关键词试试。"))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    ForEach(services) { service in
                        ServiceRow(service: service, isExpanded: expanded.contains(service.id), onToggle: {
                            if expanded.contains(service.id) { expanded.remove(service.id) } else { expanded.insert(service.id) }
                        }, onEdit: { onEdit(service.id) }, onDelete: { pendingDelete = service })
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .confirmationDialog("删除“\(pendingDelete?.name ?? "")”？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("删除服务", role: .destructive) {
                    if let id = pendingDelete?.id { state.deleteService(id) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { Text("服务和 Key 将无法继续调用；已有项目中的使用记录会保留。") }
        }
    }

    private var header: some View {
        HStack {
            Text("服务 / Key").frame(maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: 110, alignment: .leading)
            Text("使用项目").frame(width: 230, alignment: .leading)
            Text("操作").frame(width: 104, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
    }
}

private struct ServiceRow: View {
    @EnvironmentObject var state: AppState
    let service: ServiceRecord
    let isExpanded: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var credentials: [CredentialRecord] { state.snapshot.credentials.filter { $0.serviceID == service.id } }
    private var projects: [String] { state.projectPaths(serviceID: service.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 10)
                        Image(systemName: service.kind == .apiKey ? "key.horizontal.fill" : "terminal.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name).fontWeight(.medium)
                            Text(service.kind.displayName + (credentials.isEmpty ? "" : " · \(credentials.count) Keys")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                StatusBadge(status: state.repository.serviceStatus(service)).frame(width: 110, alignment: .leading)
                ProjectSummary(paths: projects).frame(width: 230, alignment: .leading)
                HStack(spacing: 4) {
                    Button { Task { await state.check(service.name) } } label: { Image(systemName: "checkmark.circle") }.help("检查")
                    Button(action: onEdit) { Image(systemName: "pencil") }.help("编辑")
                    Button(action: onDelete) { Image(systemName: "trash") }.help("删除")
                }.buttonStyle(.borderless).frame(width: 104, alignment: .trailing)
            }
            .padding(.vertical, 12)
            if isExpanded {
                if credentials.isEmpty {
                    HStack {
                        Text("curl 请求不包含单独提取的 Key").foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.leading, 54).padding(.bottom, 12)
                } else {
                    ForEach(credentials) { credential in
                        HStack {
                            HStack(spacing: 8) {
                                Text("└─").foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(credential.alias)
                                        if service.defaultCredentialID == credential.id { Text("默认").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.tint.opacity(0.12), in: Capsule()) }
                                    }
                                    Text("\(credential.maskedValue) · \(credential.environmentVariable)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            StatusBadge(status: credential.status).frame(width: 110, alignment: .leading)
                            ProjectSummary(paths: state.projectPaths(serviceID: service.id, credentialID: credential.id)).frame(width: 230, alignment: .leading)
                            Color.clear.frame(width: 104, height: 1)
                        }
                        .padding(.leading, 35).padding(.vertical, 8)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

struct StatusBadge: View {
    let status: HealthStatus
    private var color: Color {
        switch status {
        case .valid, .tlsUnverified: return .green
        case .invalid: return .red
        case .unchecked: return .gray
        }
    }
    private var title: String {
        switch status {
        case .valid, .tlsUnverified: return "可用"
        case .invalid: return "不可用"
        case .unchecked: return "检查中"
        }
    }
    var body: some View {
        Label(title, systemImage: "circle.fill").font(.caption).foregroundStyle(color).labelStyle(.titleAndIcon)
    }
}

private struct ProjectSummary: View {
    let paths: [String]
    var body: some View {
        if paths.isEmpty { Text("—").foregroundStyle(.tertiary) }
        else {
            Text(paths.prefix(2).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、") + (paths.count > 2 ? " 等 \(paths.count) 个" : ""))
                .font(.caption).lineLimit(2)
        }
    }
}
