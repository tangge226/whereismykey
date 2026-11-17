import SwiftUI
import WhereKeyCore

struct ServicesView: View {
    @EnvironmentObject var state: AppState
    let onEdit: (UUID) -> Void
    let onManageKeys: (UUID) -> Void
    let onAdd: () -> Void
    @State private var search = ""
    @State private var selected: UUID?
    @State private var pendingOnly = false
    @State private var pendingDelete: ServiceRecord?

    private func needsAttention(_ service: ServiceRecord) -> Bool {
        service.setupMessage != nil || ![HealthStatus.valid, .unchecked].contains(state.serviceStatus(service))
    }
    private var services: [ServiceRecord] {
        state.snapshot.services.filter { service in
            (!pendingOnly || needsAttention(service)) && (search.isEmpty || service.matches(search: search) ||
            state.snapshot.credentials.contains { $0.serviceID == service.id && $0.alias.localizedCaseInsensitiveContains(search) } ||
            state.projectPaths(serviceID: service.id).contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var current: ServiceRecord? { services.first { $0.id == selected } ?? services.first }

    var body: some View {
        CatalogSplitView {
            CatalogSidebar(search: $search, placeholder: "搜索服务", onAdd: onAdd) {
                HStack {
                    Button { pendingOnly = false } label: { Text("服务 \(state.snapshot.services.count)").fontWeight(.semibold) }.buttonStyle(.plain).focusEffectDisabled()
                    Spacer()
                    Button { pendingOnly.toggle() } label: {
                        Text(pendingOnly ? "查看全部" : "待处理 \(state.snapshot.services.filter(needsAttention).count)").font(.caption).foregroundStyle(.orange)
                    }.buttonStyle(.plain).focusEffectDisabled()
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(services) { service in
                            Button { selected = service.id } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: service.kind == .curl ? "terminal" : "square.stack.3d.up").font(.system(size: 17)).frame(width: 22)
                                    Text(service.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if needsAttention(service) { Circle().fill(.orange).frame(width: 7, height: 7) }
                                }.padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
                                    .background(current?.id == service.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).focusEffectDisabled()
                                .help("服务名称：" + service.name)
                                .accessibilityLabel(service.name)
                        }
                    }
                }
            }
        } detail: {
            if let service = current {
                ServiceInspector(service: service, onEdit: { onEdit(service.id) }, onManageKeys: { onManageKeys(service.id) }, onDelete: { pendingDelete = service }).id(service.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: search.isEmpty ? "key" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(search.isEmpty ? (pendingOnly ? "没有待处理服务" : "还没有服务") : "没有匹配的服务").font(.title2)
                    Text(search.isEmpty ? "粘贴网址或接入说明即可开始。" : "换个关键词，或粘贴添加新服务。 ").foregroundStyle(.secondary)
                    if !search.isEmpty || pendingOnly { Button("清空筛选") { search = ""; pendingOnly = false }.buttonStyle(.plain).focusEffectDisabled().foregroundStyle(.tint) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: state.lastSavedServiceID) { _, id in selected = id; search = ""; pendingOnly = false }
        .confirmationDialog("删除“\(pendingDelete?.name ?? "")”？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除服务", role: .destructive) { if let id = pendingDelete?.id { state.deleteService(id) }; pendingDelete = nil }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text("将删除此服务的配置与 Key，项目使用历史仍然保留。") }
    }
}

private struct ServiceInspector: View {
    @EnvironmentObject var state: AppState
    let service: ServiceRecord
    let onEdit: () -> Void
    let onManageKeys: () -> Void
    let onDelete: () -> Void
    @State private var projectsExpanded = false
    @State private var advancedExpanded = false
    private var credential: CredentialRecord? {
        let keys = state.snapshot.credentials.filter { $0.serviceID == service.id }
        return keys.first { $0.id == service.defaultCredentialID } ?? keys.first
    }
    private var restricted: Bool { state.serviceStatus(service) == .authorizationRequired }
    private var canCheck: Bool { service.setupMessage == nil && (service.kind != .curl || service.hasValidationRequest || !service.checkURL.isEmpty) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: service.kind == .curl ? "terminal" : "square.stack.3d.up").font(.system(size: 27))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text(service.name).font(.system(size: 25, weight: .semibold))
                            if let missing = service.setupMessage { Text(missing).font(.caption).foregroundStyle(.orange) }
                            else { StatusBadge(status: state.serviceStatus(service)) }
                        }
                        if !service.summary.isEmpty { Text(service.summary).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if state.isChecking { ProgressView().controlSize(.small) }
                    Button("验证连接") { Task { await state.check(service.name) } }.buttonStyle(.plain).focusEffectDisabled()
                        .disabled(!canCheck || restricted || state.isChecking || state.storageUnavailable)
                    Menu {
                        Button("编辑服务", action: onEdit)
                        Button("管理 Key", action: onManageKeys)
                        Divider()
                        Button("删除服务", role: .destructive, action: onDelete)
                    } label: { Image(systemName: "ellipsis").frame(width: 24) }.menuStyle(.borderlessButton).fixedSize().disabled(state.storageUnavailable)
                }
                VStack(spacing: 24) {
                    HStack {
                        Text("服务地址").foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                        Text(service.baseURL.isEmpty ? "未设置" : service.baseURL).textSelection(.enabled).lineLimit(2)
                        Spacer()
                    }
                    HStack {
                        Text("默认 Key").foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                        Text(credential?.maskedValue ?? (service.kind == .curl ? "无独立 Key" : "待补充")).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(credential == nil ? "添加 Key" : "更新 Key", action: onManageKeys).buttonStyle(.plain).foregroundStyle(.tint).disabled(state.storageUnavailable)
                    }
                }.padding(.top, 8)
                if restricted {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("需要本机访问许可", systemImage: "lock").fontWeight(.medium)
                        Text("macOS 暂时无法读取此 Key，允许访问后可继续验证。").font(.callout).foregroundStyle(.secondary)
                        Button("允许访问 Key") { Task { await state.authorize(service.name) } }.buttonStyle(.plain).focusEffectDisabled().foregroundStyle(.tint).disabled(state.isChecking || state.storageUnavailable)
                    }
                }
                if service.setupMessage != nil {
                    Button("补充连接信息", action: onEdit).buttonStyle(.borderedProminent).disabled(state.storageUnavailable)
                }
                DisclosureGroup("关联项目 \(state.projectPaths(serviceID: service.id).count)", isExpanded: $projectsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.projectPaths(serviceID: service.id).isEmpty { Text("暂无使用记录").foregroundStyle(.secondary) }
                        ForEach(state.projectPaths(serviceID: service.id), id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                }.padding(.top, 10)
                DisclosureGroup("高级设置", isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledContent("类型", value: service.kind.displayName)
                        LabeledContent("分类", value: service.category.displayName)
                        LabeledContent("检查方式", value: service.checkMode.displayName)
                        if !service.tags.isEmpty { LabeledContent("标签", value: service.tags.joined(separator: "、")) }
                        if let url = URL(string: service.documentationURL), ["https", "http"].contains(url.scheme ?? "") { Link("服务文档", destination: url) }
                        Button("编辑高级设置", action: onEdit).disabled(state.storageUnavailable)
                    }.padding(.top, 16)
                }
                Spacer(minLength: 80)
            }.padding(32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBadge: View {
    let status: HealthStatus
    private var color: Color {
        switch status {
        case .valid: return .green
        case .invalid: return .red
        case .unchecked: return .gray
        default: return .orange
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status == .authorizationRequired ? "访问受限" : status.displayName)
        }.font(.caption).foregroundStyle(color)
    }
}
