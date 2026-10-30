import Foundation

/// Credentials only travel to the fixed repository's GitHub API endpoints.
public enum PrivateUpdatePolicy {
    public static let feedURL = URL(string: "https://api.github.com/repos/flowtricks/opal-app/contents/updates/appcast.xml?ref=main")!
    public static let credentialCheckURL = URL(string: "https://api.github.com/repos/flowtricks/opal-app/contents/README.md?ref=main")!

    /// A release build may carry a read-only token in Info.plist (expanded from
    /// OPAL_UPDATE_TOKEN at build time). Unexpanded or empty values are ignored.
    public static func bundledToken(_ value: Any?) -> String? {
        guard let token = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, !token.contains("$("), !token.contains(where: { $0.isWhitespace }) else { return nil }
        return token
    }

    public static func isReleaseAsset(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "api.github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return false }
        let prefix = "/repos/flowtricks/opal-app/releases/assets/"
        guard url.path.hasPrefix(prefix) else { return false }
        let id = url.path.dropFirst(prefix.count)
        return !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func canInstall(cameraRequested: Bool, cameraRunning: Bool, captureBusy: Bool,
                                  recording: Bool, loopActive: Bool, testing: Bool,
                                  consumerActive: Bool, connectedWithUnknownDemand: Bool) -> Bool {
        !cameraRequested && !cameraRunning && !captureBusy && !recording && !loopActive &&
        !testing && !consumerActive && !connectedWithUnknownDemand
    }
}
