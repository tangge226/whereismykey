import AppKit
import SwiftUI
import WhereKeyCore

struct BulkImportView: View {
    @EnvironmentObject private var state: AppState
    @State private var stage: Stage = .paste
    @State private var pastedText = ""
    @State private var items: [ReviewItem] = []
    @State private var currentIndex = 0
    @State private var parseMessage: String?
    @State private var isSaving = false
    @State private var isRecognizing = false
    let dismiss: () -> Void
    var manualAdd: () -> Void = {}

    private enum Stage { case paste, review, complete }
    fileprivate enum ReviewStatus { case pending, created, skipped }

    fileprivate struct ReviewItem: Identifiable {
        let id: UUID
        var draft: ServiceDraft
        let sourcePreview: String
        let automaticAdditions: [String]
        var status: ReviewStatus = .pending

        init(_ candidate: NoteImportCandidate) {
            id = candidate.id
            draft = candidate.draft
            sourcePreview = candidate.sourcePreview
            automaticAdditions = candidate.automaticAdditions
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stage {
            case .paste: pasteStep
            case .review: reviewStep
            case .complete: completionStep
            }
        }
        .frame(width: 620, height: stage == .paste ? 420 : 580)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("粘贴添加").font(.title2).fontWeight(.semibold)
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消", action: dismiss).disabled(isRecognizing || isSaving)
        }
        .padding(18)
    }

    private var headerSubtitle: String {
        switch stage {
        case .paste: return "粘贴网址或接入说明，自动填写服务配置"
        case .review: return "逐条确认，不会一次性全部写入"
        case .complete: return "本次导入已处理完成"
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("网址、接入说明、Key 或 curl").foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let value = NSPasteboard.general.string(forType: .string) { pastedText = value }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
            }
            TextEditor(text: $pastedText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            Text("接入方式自动识别，缺少 Key 也可先保存。含 Key 的内容仅在本机识别。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let parseMessage {
                Label(parseMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("手动添加", action: manualAdd).buttonStyle(.plain).foregroundStyle(.tint).disabled(isRecognizing)
                Spacer()
                if isRecognizing { ProgressView().controlSize(.small); Text("正在读取接入说明…").font(.caption) }
                Button("识别") { Task { await recognize() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRecognizing || pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var reviewStep: some View {
        if items.indices.contains(currentIndex) {
            VStack(spacing: 0) {
                HStack {
                    Text(items.count == 1 ? "已识别服务" : "第 \(currentIndex + 1) / \(items.count) 个服务")
                        .font(.headline)
                    Spacer()
                    Text(items[currentIndex].draft.kind.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ProgressView(value: Double(currentIndex), total: Double(max(items.count, 1)))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                CandidateReviewEditor(item: $items[currentIndex])

                Divider()
                HStack {
                    Button("重新粘贴") { resetToPaste() }
                        .disabled(items.contains(where: { $0.status == .created }))
                    Spacer()
                    if let issue = validationIssue(for: items[currentIndex].draft) {
                        Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                    Button("跳过") { skipCurrent() }
                    Button(currentIndex == items.count - 1 ? "添加服务" : "添加并继续") {
                        createCurrent()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || validationIssue(for: items[currentIndex].draft) != nil)
                }
                .padding(16)
            }
        }
    }

    private var completionStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)
            Text("服务已添加").font(.title2).fontWeight(.semibold)
            Text("已创建 \(createdCount) 个服务" + (skippedCount > 0 ? "，跳过 \(skippedCount) 个" : ""))
                .foregroundStyle(.secondary)
            if items.contains(where: { $0.status == .created && $0.draft.allowsIncomplete && ($0.draft.credentials.allSatisfy { $0.secret.isEmpty } || ($0.draft.requiresBaseURL && $0.draft.baseURL.isEmpty)) }) {
                Text("待补充的 Key 或服务地址，可在服务列表点击“补充”后填写。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("完成", action: dismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var createdCount: Int { items.filter { $0.status == .created }.count }
    private var skippedCount: Int { items.filter { $0.status == .skipped }.count }

    private func fillFromClipboardIfAvailable() {
        guard pastedText.isEmpty,
              let value = NSPasteboard.general.string(forType: .string),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pastedText = value
    }

    private func recognize() async {
        isRecognizing = true
        parseMessage = nil
        defer { isRecognizing = false }
        let parsed: [NoteImportCandidate]
        do { parsed = try await ServiceImportResolver().resolve(pastedText) }
        catch {
            parseMessage = "网址暂时无法读取。可复制开发者页面的接入说明，直接粘贴到这里重试。"
            return
        }
        guard !parsed.isEmpty else {
            parseMessage = "没有识别到可创建的 Key、URL 或 curl，请保留服务名和字段标记后重试。"
            return
        }
        items = parsed.map { candidate in
            var item = ReviewItem(candidate)
            if let pending = state.snapshot.services.first(where: { $0.setupMessage != nil && $0.name.caseInsensitiveCompare(item.draft.name) == .orderedSame }) {
                item.draft.id = pending.id
                if item.draft.baseURL.isEmpty { item.draft.baseURL = pending.baseURL }
                // An address-only pending service may already have a real Key.
                if !pending.credentialIDs.isEmpty, let existing = try? state.makeDraft(serviceID: pending.id) {
                    if item.draft.credentials.allSatisfy({ $0.secret.isEmpty }) { item.draft.credentials = existing.credentials }
                    else if let key = item.draft.credentials.first?.secret, var credential = existing.credentials.first {
                        credential.secret = key
                        item.draft.credentials = [credential] + existing.credentials.dropFirst()
                    }
                }
            }
            return item
        }
        currentIndex = 0
        parseMessage = nil
        pastedText = ""
        stage = .review
    }

    private func createCurrent() {
        guard items.indices.contains(currentIndex) else { return }
        isSaving = true
        let index = currentIndex
        Task {
            let saved = await state.save(items[index].draft)
            isSaving = false
            guard saved else { return }
            items[index].status = .created
            advance()
        }
    }

    private func skipCurrent() {
        guard items.indices.contains(currentIndex) else { return }
        items[currentIndex].status = .skipped
        advance()
    }

    private func advance() {
        if let next = items.indices.first(where: { $0 > currentIndex && items[$0].status == .pending }) {
            currentIndex = next
        } else {
            stage = .complete
        }
    }

    private func resetToPaste() {
        guard !items.contains(where: { $0.status == .created }) else { return }
        items = []
        currentIndex = 0
        stage = .paste
    }

    private func validationIssue(for draft: ServiceDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "请填写服务名称" }
        if state.snapshot.services.contains(where: { $0.id != draft.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "此服务已添加，可在列表中编辑；也可跳过此项"
        }
        if draft.kind == .apiKey && draft.credentials.isEmpty && !draft.allowsIncomplete { return "API Key 服务至少需要一个 Key" }
        for credential in draft.credentials {
            if credential.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Key 别名不能为空" }
            if credential.secret.isEmpty && !draft.allowsIncomplete && draft.id == nil { return "请补全 Key 值" }
            if credential.environmentVariable.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                return "环境变量名无效"
            }
        }
        if draft.kind == .curl && draft.curlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "curl 不能为空"
        }
        return nil
    }
}

private struct CandidateReviewEditor: View {
    @Binding var item: BulkImportView.ReviewItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.draft.name).font(.title2).fontWeight(.semibold)
                if !item.draft.summary.isEmpty { Text(item.draft.summary).foregroundStyle(.secondary) }
                if item.draft.id != nil { Label("将补充已添加的服务", systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.secondary) }

                ForEach($item.draft.credentials) { $credential in
                    SecureField(credential.existingSuffix.isEmpty ? "粘贴 Key（可稍后补充）" : "已保存 Key；留空保持不变", text: $credential.secret)
                        .textFieldStyle(.roundedBorder)
                }
                if item.draft.requiresBaseURL {
                    TextField("授权邮件中的服务地址（可稍后补充）", text: $item.draft.baseURL).textFieldStyle(.roundedBorder)
                }
                if item.draft.allowsIncomplete {
                    Label("还没有 Key 或服务地址？直接添加即可，之后点击“补充”。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if !item.automaticAdditions.isEmpty {
                    DisclosureGroup("接入方式已识别") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("自动识别与补全").font(.headline)
                        ForEach(item.automaticAdditions, id: \.self) { addition in
                            Label(addition, systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                DisclosureGroup("高级设置（通常无需修改）") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("服务名称", text: $item.draft.name).textFieldStyle(.roundedBorder)
                        ServiceMetadataFields(draft: $item.draft)
                        if item.draft.kind == .apiKey { apiFields } else { curlFields }
                        ServiceCheckFields(draft: $item.draft)
                    }.padding(.top, 8)
                }

                DisclosureGroup("查看脱敏原文") {
                    Text(item.sourcePreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var apiFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("API 地址") {
                TextField("可留空", text: $item.draft.baseURL).textFieldStyle(.roundedBorder)
            }
            if !item.draft.baseURL.isEmpty {
                LabeledContent("地址变量") {
                    TextField("例如 OPENAI_BASE_URL", text: $item.draft.baseURLVariable).textFieldStyle(.roundedBorder)
                }
            }
            Text("Keys").font(.headline)
            ForEach($item.draft.credentials) { $credential in
                ImportedCredentialRow(credential: $credential)
            }
        }
    }

    private var curlFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("安全 curl").font(.headline)
            TextEditor(text: $item.draft.curlTemplate)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 130)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            ForEach($item.draft.credentials) { $credential in
                ImportedCredentialRow(credential: $credential)
            }
        }
    }
}

private struct ImportedCredentialRow: View {
    @Binding var credential: CredentialDraft

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("别名", text: $credential.alias)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 135)
                TextField("环境变量名", text: $credential.environmentVariable)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("Key 值", text: $credential.secret)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
