import SwiftUI
import WhereKeyCore

struct ServiceEditor: View {
    @EnvironmentObject var state: AppState
    @State private var draft: ServiceDraft
    @State private var showValidation = false
    @State private var extractionMessage: String?
    let dismiss: () -> Void

    init(initialDraft: ServiceDraft, dismiss: @escaping () -> Void) {
        _draft = State(initialValue: initialDraft)
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.id == nil ? "添加服务" : "编辑服务").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("取消", action: dismiss)
                Button("保存") { Task { if await state.save(draft) { dismiss() } } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("服务类型", selection: $draft.kind) {
                        ForEach(ServiceKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)

                    LabeledContent("服务名称") {
                        TextField("例如 OpenAI、内网搜索", text: $draft.name).textFieldStyle(.roundedBorder)
                    }

                    if draft.kind == .apiKey { apiKeyFields }
                    else { curlFields }

                    DisclosureGroup("有效性检查（可选）", isExpanded: $showValidation) {
                        validationFields.padding(.top, 10)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 650, height: 650)
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
            Divider()
            LabeledContent("API 地址（可选）") { TextField("https://…", text: $draft.baseURL).textFieldStyle(.roundedBorder) }
            LabeledContent("地址变量（可选）") { TextField("例如 OPENAI_BASE_URL", text: $draft.baseURLVariable).textFieldStyle(.roundedBorder) }
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

    private var validationFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.kind == .apiKey {
                Text("验证 curl（用 {{key}} 代表当前 Key）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.validationCurl)
                    .font(.system(.caption, design: .monospaced)).frame(minHeight: 95).padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            } else {
                Text("使用上面的 curl 进行检查。").font(.caption).foregroundStyle(.secondary)
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
        let ascii = draft.name.uppercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(String(scalar)) : "_"
        }
        let normalized = String(ascii).replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? "WHEREKEY_API_KEY" : "\(normalized)_API_KEY"
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
                TextField("环境变量名", text: $credential.environmentVariable).textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(isOnly)
            }
            SecureField(credential.existingSuffix.isEmpty ? "Key 值" : "留空则保持 ••••••\(credential.existingSuffix)", text: $credential.secret)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}
