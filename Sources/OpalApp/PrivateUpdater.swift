import AppKit
import Combine
import Security
import Sparkle
import OpalCore

/// Sparkle handles signed installation; this layer provides private GitHub access
/// and delays relaunches until all camera and recording work is idle.
@MainActor
final class PrivateUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "Connect this Mac to private updates."
    @Published private(set) var checking = false
    /// True when this Mac uses the token built into the release, not its own.
    @Published private(set) var usingBuiltInAccess = false
    @Published var automatic = UserDefaults.standard.object(forKey: "updates.automatic") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "updates.automatic")
            controller?.updater.automaticallyChecksForUpdates = automatic && connected
            controller?.updater.automaticallyDownloadsUpdates = automatic && connected
        }
    }
    private var controller: SPUStandardUpdaterController?
    private var credential: String?
    private weak var studio: StudioModel?
    private var pendingInstallation: (() -> Void)?
    private var idleTimer: AnyCancellable?
    private var attached = false
    private let service = "com.timothyricks.opal-app.private-updates"
    private let builtInToken = PrivateUpdatePolicy.bundledToken(Bundle.main.object(forInfoDictionaryKey: "OpalUpdateToken"))

    func attach(studio: StudioModel) {
        self.studio = studio
        guard !attached else { return }
        attached = true
        do {
            // A token saved on this Mac takes precedence over the built-in one.
            if let token = try readCredential() { try configure(token: token) }
            else { try useBuiltInAccess() }
        } catch {
            if (try? useBuiltInAccess()) == nil { status = "Unlock your Keychain or reconnect private updates in Settings." }
        }
    }

    func connect(token input: String) async -> Bool {
        guard !connecting, !checking else { return false }
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            status = "Enter a GitHub token with Contents: Read-only for flowtricks/opal-app."
            return false
        }
        connecting = true
        defer { connecting = false }
        status = "Verifying access to the private repository…"
        var request = URLRequest(url: PrivateUpdatePolicy.credentialCheckURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = "Access denied. Select flowtricks/opal-app and Contents: Read-only; approve the token in Flowtricks if required."
                return false
            }
            try saveCredential(token)
            try configure(token: token)
            return true
        } catch {
            status = "Could not connect. Check your connection and Keychain access, then try again."
            return false
        }
    }

    func disconnect() {
        // An in-flight signed install must not lose its request credentials.
        guard !checking, pendingInstallation == nil else { return }
        let result = SecItemDelete(keychainQuery() as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            status = "Keychain could not remove the connection. Try again after unlocking it."
            return
        }
        credential = nil; connected = false
        controller?.updater.automaticallyChecksForUpdates = false
        controller?.updater.automaticallyDownloadsUpdates = false
        controller?.updater.httpHeaders = [:]
        status = "Disconnected. Private updates are off on this Mac."
        try? useBuiltInAccess()
    }

    private func useBuiltInAccess() throws {
        guard let builtInToken else { return }
        try configure(token: builtInToken, builtIn: true)
    }

    func checkForUpdates() {
        guard connected, let controller, controller.updater.canCheckForUpdates else { return }
        checking = true
        status = "Checking private releases…"
        controller.checkForUpdates(nil)
    }

    private func configure(token: String, builtIn: Bool = false) throws {
        credential = token
        usingBuiltInAccess = builtIn
        if controller == nil {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            controller?.updater.httpHeaders = headers(token: token)
            connected = true
            controller?.updater.automaticallyChecksForUpdates = automatic
            controller?.updater.automaticallyDownloadsUpdates = automatic
            do { try controller?.updater.start() }
            catch {
                controller = nil; credential = nil; connected = false
                throw error
            }
        } else {
            controller?.updater.httpHeaders = headers(token: token)
            connected = true
            controller?.updater.automaticallyChecksForUpdates = automatic
            controller?.updater.automaticallyDownloadsUpdates = automatic
        }
        status = builtIn ? "Updates are set up. No sign-in is needed." : "Connected to private Flowtricks releases."
    }

    private func headers(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github.raw+json"]
    }

    func feedURLString(for updater: SPUUpdater) -> String? { PrivateUpdatePolicy.feedURL.absoluteString }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard connected, credential != nil else { throw updateError("Connect private updates in Settings first.") }
        checking = true
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard PrivateUpdatePolicy.isReleaseAsset(item.fileURL), item.deltaUpdates?.isEmpty != false else {
            throw updateError("The update does not point to an approved private release asset.")
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        // GitHub contents use raw JSON media type; release files use octet-stream.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if PrivateUpdatePolicy.isReleaseAsset(request.url), let credential {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        } else { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        status = "Downloading a signed update…"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Update \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { status = "You’re up to date." }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        checking = false
        if let error = error as NSError?, error.code != SUError.noUpdateError.rawValue {
            status = "Update check failed. Check your connection or renew the GitHub token in Settings."
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        postpone(install)
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock install: @escaping () -> Void) -> Bool {
        guard !safeToInstall else { return false }
        postpone(install)
        return true
    }

    private var safeToInstall: Bool {
        guard let studio else { return false }
        return PrivateUpdatePolicy.canInstall(
            cameraRequested: studio.cameraRequested,
            cameraRunning: studio.camera.isRunning || studio.c1.isRunning || studio.c1.isConnecting,
            captureBusy: studio.cameraBusy,
            recording: studio.recording || studio.recordingStarting || studio.recordingFinalizing,
            loopActive: studio.loop.isPlaying || studio.loop.isRecording || studio.loop.isFinalizing,
            testing: studio.transportTest.isRunning || studio.verifier.isRunning,
            consumerActive: studio.bridge.consumerActive,
            connectedWithUnknownDemand: studio.bridge.isConnected && studio.bridge.consumerDemand == nil)
    }

    private func postpone(_ install: @escaping () -> Void) {
        pendingInstallation = install
        status = "Update ready. It will install when the camera is off and recordings have finished, or when you quit."
        idleTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.safeToInstall, let install = self.pendingInstallation else { return }
            self.pendingInstallation = nil; self.idleTimer = nil
            install()
        }
    }

    private func updateError(_ message: String) -> NSError {
        NSError(domain: "OpalPrivateUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "flowtricks/opal-app", kSecUseDataProtectionKeychain as String: true]
    }
    private func readCredential() throws -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw updateError("Keychain unavailable")
        }
        return token
    }
    private func saveCredential(_ token: String) throws {
        let query = keychainQuery()
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw updateError("Keychain unavailable") }
    }
}
