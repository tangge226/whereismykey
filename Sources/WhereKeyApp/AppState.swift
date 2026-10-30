import AppKit
import Foundation
import WhereKeyCore

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot = MetadataState()
    @Published var errorMessage: String?
    @Published var offersRestart = false
    @Published var isChecking = false

    let repository: WhereKeyRepository
    private var server: IPCServer?
    private var didRunStartupAPIKeyCheck = false

    init() {
        do {
            let repository = try WhereKeyRepository()
            self.repository = repository
            self.snapshot = repository.snapshot()
        } catch {
            self.repository = try! WhereKeyRepository(metadataStore: MetadataStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("WhereKey-Recovery")))
            present(error)
        }
    }

    func start() {
        guard server == nil else { return }
        let repository = repository
        let server = IPCServer { [weak self] request in
            do {
                let response: IPCResponse
                switch request.action {
                case "catalog":
                    response = IPCResponse(ok: true, catalog: repository.catalog())
                case "describe":
                    guard let service = request.service else { throw WhereKeyError.invalidInput("缺少服务名称") }
                    response = IPCResponse(ok: true, description: try repository.describe(service: service))
                case "prepareRun":
                    guard let service = request.service else { throw WhereKeyError.invalidInput("缺少服务名称") }
                    response = IPCResponse(ok: true, preparedRun: try repository.prepareRun(service: service, keyAlias: request.keyAlias, cwd: request.cwd ?? FileManager.default.currentDirectoryPath))
                case "call":
                    guard let service = request.service else { throw WhereKeyError.invalidInput("缺少服务名称") }
                    response = IPCResponse(ok: true, checkResult: try repository.call(service: service, keyAlias: request.keyAlias, cwd: request.cwd ?? FileManager.default.currentDirectoryPath))
                case "check":
                    guard let service = request.service else { throw WhereKeyError.invalidInput("缺少服务名称") }
                    response = IPCResponse(ok: true, checkResult: try repository.check(service: service, keyAlias: request.keyAlias))
                case "checkAll":
                    response = IPCResponse(ok: true, checkResults: repository.checkAll().map { NamedCheckResult(service: $0.0, result: $0.1) })
                default:
                    throw WhereKeyError.invalidInput("未知操作：\(request.action)")
                }
                DispatchQueue.main.async { self?.refresh() }
                return response
            } catch {
                return IPCResponse(ok: false, error: error.localizedDescription)
            }
        }
        do {
            try server.start()
            self.server = server
            if !didRunStartupAPIKeyCheck {
                didRunStartupAPIKeyCheck = true
                Task { await checkAPIKeys() }
            }
        } catch {
            present(error)
        }
    }

    func refresh() { snapshot = repository.snapshot() }

    func makeDraft(serviceID: UUID?) throws -> ServiceDraft {
        try repository.draft(for: serviceID)
    }

    func save(_ draft: ServiceDraft) async -> Bool {
        do {
            let id = try repository.save(draft)
            refresh()
            let state = repository.snapshot()
            if let service = state.services.first(where: { $0.id == id }) {
                Task { await check(service.name) }
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    func deleteService(_ id: UUID) {
        do { try repository.deleteService(id); refresh() }
        catch { present(error) }
    }

    func check(_ serviceName: String, keyAlias: String? = nil) async {
        isChecking = true
        do {
            _ = try await Task.detached { try self.repository.check(service: serviceName, keyAlias: keyAlias) }.value
            refresh()
        } catch { present(error) }
        isChecking = false
    }

    func checkAll() async {
        isChecking = true
        _ = await Task.detached { self.repository.checkAll() }.value
        refresh()
        isChecking = false
    }

    func checkAPIKeys() async {
        isChecking = true
        _ = await Task.detached { self.repository.checkAllAPIKeys() }.value
        refresh()
        isChecking = false
    }

    func projectPaths(serviceID: UUID, credentialID: UUID? = nil) -> [String] {
        repository.projectPaths(for: serviceID, credentialID: credentialID)
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        if let whereKeyError = error as? WhereKeyError,
           case .keychain(let status) = whereKeyError,
           status == -25293 {
            offersRestart = true
        } else {
            offersRestart = false
        }
    }

    func clearError() {
        errorMessage = nil
        offersRestart = false
    }

    func restartApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            present(error)
        }
    }
}
