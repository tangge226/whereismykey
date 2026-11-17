import SwiftUI
import WhereKeyCore

struct ServiceEditor: View {
    @EnvironmentObject var state: AppState
    @State private var draft: ServiceDraft
    @State private var showValidation = false
    @State private var extractionMessage: String?
    let dismiss: () -> Void
    let keysOnly: Bool
    @State private var confirmDiscard = false

    init(initialDraft: ServiceDraft, keysOnly: Bool = false, dismiss: @escaping () -> Void) {
        _draft = State(initialValue: initialDraft)
        self.dismiss = dismiss
        self.keysOnly = keysOnly
        if initialDraft.id == nil && initialDraft.kind == .apiKey { _draft = State(initialValue: { var d = initialDraft; d.allowsIncomplete = true; return d }()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(keysOnly ? "管理 Key" : (draft.id == nil ? "添加服务" : "编辑服务")).font(.title2).fontWeight(.semibold)
                Spacer()
                Button("取消") { confirmDiscard = true }
                Button("保存") { Task { if await state.save(draft) { dismiss() } } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if keysOnly {
                        Text(draft.name).font(.headline)
                        apiKeyFields
                    } else {
                        if draft.id == nil {
                            Picker("保存方式", selection: $draft.kind) {
                                ForEach(ServiceKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                        LabeledContent("服务名称") { TextField("例如 图萃、OpenAI", text: $draft.name).textFieldStyle(.roundedBorder) }
                        if draft.kind == .apiKey {
                            ForEach($draft.credentials) { $credential in
                                SecureField(credential.existingSuffix.isEmpty ? "粘贴 Key（可稍后补充）" : "已保存 Key；留空保持不变", text: $credential.secret).textFieldStyle(.roundedBorder)
                            }
                            LabeledContent("服务地址") { TextField("https://…（可选）", text: $draft.baseURL).textFieldStyle(.roundedBorder) }
                        } else { curlFields }
                        DisclosureGroup("高级设置") {
                            VStack(alignment: .leading, spacing: 18) {
                                ServiceMetadataFields(draft: $draft)
                                if draft.kind == .apiKey { apiKeyFields }
                                ServiceCheckFields(draft: $draft)
                            }.padding(.top, 14)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: keysOnly ? 520 : 560)
        .interactiveDismissDisabled()
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $confirmDiscard) {
            Button("放弃修改", role: .destructive, action: dismiss)
            Button("继续编辑", role: .cancel) { }
        }
        .onChange(of: draft.name) { old, name in
            guard draft.id == nil else { return }
            let oldVariable = ServiceDraft.suggestedEnvironmentName(for: old)
            let variable = ServiceDraft.suggestedEnvironmentName(for: name)
            for index in draft.credentials.indices where draft.credentials[index].environmentVariable == oldVariable {
                draft.credentials[index].environmentVariable = variable
            }
            if draft.environmentVariable == oldVariable { draft.environmentVariable = variable }
        }
        .onChange(of: draft.kind) { _, kind in
            if kind == .apiKey && draft.credentials.isEmpty {
                draft.credentials = [CredentialDraft(environmentVariable: suggestedEnvironmentName())]
            } else if kind == .curl && draft.id == nil && draft.credentials.allSatisfy({ $0.secret.isEmpty && $0.existingSuffix.isEmpty }) {
                draft.credentials.removeAll()
            }
        }
    }

    private var apiKeyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keys").font(.headline)
                Spacer()
                Button { addCredential() } label: { Label("添加 Key", systemImage: "plus") }
            }
            ForEach($draft.credentials) { $credential in
                CredentialEditorRow(
                    credential: $credential,
                    isOnly: draft.credentials.count == 1,
                    onMakeDefault: { makeDefault(credential.id) },
                    onDelete: { removeCredential(credential.id) }
                )
            }
            if !keysOnly {
                LabeledContent("地址变量（可选）") { TextField("例如 OPENAI_BASE_URL", text: $draft.baseURLVariable).textFieldStyle(.roundedBorder) }
            }
        }
    }

    private var curlFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("原始 curl").font(.headline)
            TextEditor(text: $draft.curlTemplate)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 170)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            HStack {
                Button("提取检测到的 Token") { extractToken() }
                if let extractionMessage { Text(extractionMessage).font(.caption).foregroundStyle(.secondary) }
            }
            if !draft.credentials.isEmpty {
                Text("已提取的 Key").font(.headline).padding(.top, 4)
                ForEach($draft.credentials) { $credential in
                    CredentialEditorRow(
                        credential: $credential,
                        isOnly: draft.credentials.count == 1,
                        onMakeDefault: { makeDefault(credential.id) },
                        onDelete: { removeCredential(credential.id) }
                    )
                }
            }
        }
    }

    private func addCredential() {
        draft.credentials.append(CredentialDraft(alias: "key-\(draft.credentials.count + 1)", environmentVariable: suggestedEnvironmentName(), isDefault: draft.credentials.isEmpty))
    }

    private func removeCredential(_ id: UUID) {
        let wasDefault = draft.credentials.first(where: { $0.id == id })?.isDefault == true
        draft.credentials.removeAll { $0.id == id }
        if wasDefault, !draft.credentials.isEmpty { makeDefault(draft.credentials[0].id) }
    }

    private func makeDefault(_ id: UUID) {
        for index in draft.credentials.indices { draft.credentials[index].isDefault = draft.credentials[index].id == id }
    }

    private func extractToken() {
        let alias = draft.credentials.first?.alias ?? "default"
        guard let extracted = SafeCurl.extractFirstSecret(from: draft.curlTemplate, alias: alias) else {
            extractionMessage = "没有检测到 Bearer 或 API-Key Header"
            return
        }
        draft.curlTemplate = extracted.template
        if draft.credentials.isEmpty {
            draft.credentials = [CredentialDraft(alias: alias, environmentVariable: suggestedEnvironmentName(), secret: extracted.secret)]
        } else {
            draft.credentials[0].secret = extracted.secret
            draft.credentials[0].isDefault = true
        }
        extractionMessage = "已提取为 \(alias)"
    }

    private func suggestedEnvironmentName() -> String {
        ServiceDraft.suggestedEnvironmentName(for: draft.name)
    }
}

struct ServiceMetadataFields: View {
    @Binding var draft: ServiceDraft

    var body: some View {
        Picker("分类", selection: $draft.category) {
            ForEach(ServiceCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        LabeledContent("用途说明") {
            TextField("这个服务能做什么", text: $draft.summary, axis: .vertical).textFieldStyle(.roundedBorder)
        }
        LabeledContent("标签") {
            TextField("用逗号分隔，例如 自建、知识库", text: Binding(
                get: { draft.tags.joined(separator: ",") },
                set: { draft.tags = $0.components(separatedBy: CharacterSet(charactersIn: ",，")) }
            )).textFieldStyle(.roundedBorder)
        }
        LabeledContent("文档链接") {
            TextField("可留空", text: $draft.documentationURL).textFieldStyle(.roundedBorder)
        }
    }
}

struct ServiceCheckFields: View {
    @Binding var draft: ServiceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("检查方式", selection: $draft.checkMode) {
                ForEach(CheckMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("无需验证地址也能保存和使用 Key。自动检查只执行独立的 GET / HEAD 验证请求。")
                .font(.caption).foregroundStyle(.secondary)
            if draft.checkMode != .disabled {
                LabeledContent("验证地址") {
                    TextField("可留空；填写只读鉴权接口", text: $draft.checkURL).textFieldStyle(.roundedBorder)
                }
                Picker("验证鉴权", selection: $draft.authentication.kind) {
                    ForEach(AuthenticationKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if draft.authentication.kind == .header || draft.authentication.kind == .query {
                    LabeledContent("鉴权字段名") {
                        TextField(draft.authentication.kind == .header ? "例如 X-API-Key" : "例如 api_key", text: $draft.authentication.fieldName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Text("高级：独立验证 curl（优先于上述配置，用 {{key}} 代表当前 Key）")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.validationCurl)
                    .font(.system(.caption, design: .monospaced)).frame(minHeight: 75).padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                if draft.allowsLegacyCurlCheck && draft.kind == .curl {
                    Text("兼容旧服务：未配置独立验证请求时，手动检查仍执行原 curl；自动检查不会执行原 curl。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("有效状态码") { TextField("200-299", text: $draft.validationRule.acceptedStatusCodes).textFieldStyle(.roundedBorder) }
                LabeledContent("正文包含") { TextField("可留空", text: $draft.validationRule.bodyContains).textFieldStyle(.roundedBorder) }
                HStack {
                    TextField("JSON 路径，例如 data.status", text: $draft.validationRule.jsonPath).textFieldStyle(.roundedBorder)
                    TextField("期望值；留空表示只需存在", text: $draft.validationRule.jsonExpectedValue).textFieldStyle(.roundedBorder)
                }
                Stepper("超时：\(draft.validationRule.timeoutSeconds) 秒", value: $draft.validationRule.timeoutSeconds, in: 1...60)
            }
        }
    }
}

private struct CredentialEditorRow: View {
    @Binding var credential: CredentialDraft
    let isOnly: Bool
    let onMakeDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Button(action: onMakeDefault) {
                    Image(systemName: credential.isDefault ? "largecircle.fill.circle" : "circle")
                }.buttonStyle(.plain).help("设为默认")
                TextField("别名", text: $credential.alias).textFieldStyle(.roundedBorder).frame(width: 135)
                Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(isOnly || credential.isDefault).help("默认 Key 请先将其他项设为默认再删除")
            }
            DisclosureGroup("高级设置") {
                TextField("环境变量名", text: $credential.environmentVariable).textFieldStyle(.roundedBorder).padding(.top, 6)
            }.font(.caption).foregroundStyle(.secondary)
            SecureField(credential.existingSuffix.isEmpty ? "Key 值" : "留空则保持 ••••••\(credential.existingSuffix)", text: $credential.secret)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}
