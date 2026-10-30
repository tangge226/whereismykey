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
    let dismiss: () -> Void

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
        .frame(width: 760, height: 680)
        .onAppear(perform: fillFromClipboardIfAvailable)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("粘贴批量导入").font(.title2).fontWeight(.semibold)
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消", action: dismiss)
        }
        .padding(18)
    }

    private var headerSubtitle: String {
        switch stage {
        case .paste: return "从笔记中识别 Key、URL 和 curl"
        case .review: return "逐条确认，不会一次性全部写入"
        case .complete: return "本次导入已处理完成"
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("粘贴你的笔记").font(.headline)
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
            Text("可以混合粘贴厂商名、内网服务名、Key、URL 和完整 curl。原文只在本次识别中使用，不会保存到项目或 metadata。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let parseMessage {
                Label(parseMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("开始识别") { recognize() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var reviewStep: some View {
        if items.indices.contains(currentIndex) {
            VStack(spacing: 0) {
                HStack {
                    Text("第 \(currentIndex + 1) / \(items.count) 个候选服务")
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
                    Button(currentIndex == items.count - 1 ? "创建" : "创建并继续") {
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
            Text("导入完成").font(.title2).fontWeight(.semibold)
            Text("已创建 \(createdCount) 个服务" + (skippedCount > 0 ? "，跳过 \(skippedCount) 个" : ""))
                .foregroundStyle(.secondary)
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

    private func recognize() {
        let parsed = NoteImportParser.parse(pastedText)
        guard !parsed.isEmpty else {
            parseMessage = "没有识别到可创建的 Key、URL 或 curl，请保留服务名和字段标记后重试。"
            return
        }
        items = parsed.map(ReviewItem.init)
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
        if state.snapshot.services.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "已有同名服务，请修改名称或跳过"
        }
        if draft.kind == .apiKey && draft.credentials.isEmpty { return "API Key 服务至少需要一个 Key" }
        for credential in draft.credentials {
            if credential.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Key 别名不能为空" }
            if credential.secret.isEmpty { return "请补全 Key 值" }
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
                LabeledContent("服务名称") {
                    TextField("服务名称", text: $item.draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                if item.draft.kind == .apiKey { apiFields } else { curlFields }

                if !item.automaticAdditions.isEmpty {
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
