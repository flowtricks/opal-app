import XCTest
@testable import OpalCore

final class PrivateUpdatePolicyTests: XCTestCase {
    func testOnlyApprovedRepositoryAssetEndpointsReceiveCredentials() {
        XCTAssertTrue(PrivateUpdatePolicy.isReleaseAsset(URL(string: "https://api.github.com/repos/flowtricks/opal-app/releases/assets/12345")))
        for value in [
            "http://api.github.com/repos/flowtricks/opal-app/releases/assets/1",
            "https://api.github.com.evil.test/repos/flowtricks/opal-app/releases/assets/1",
            "https://api.github.com/repos/another/private/releases/assets/1",
            "https://api.github.com/repos/flowtricks/opal-app/releases/assets/",
            "https://api.github.com/repos/flowtricks/opal-app/releases/assets/1/extra",
            "https://api.github.com/repos/flowtricks/opal-app/releases/assets/1?redirect=elsewhere",
            "https://api.github.com/repos/flowtricks/opal-app/releases/assets/1#fragment",
            "https://user:pass@api.github.com/repos/flowtricks/opal-app/releases/assets/1",
            "https://api.github.com:8443/repos/flowtricks/opal-app/releases/assets/1",
            "https://github.com/flowtricks/opal-app/releases/download/v1/app.zip"
        ] { XCTAssertFalse(PrivateUpdatePolicy.isReleaseAsset(URL(string: value)), value) }
        XCTAssertFalse(PrivateUpdatePolicy.isReleaseAsset(nil))
    }

    func testAllCaptureWorkAndUnknownConsumerDemandBlockInstallation() {
        // Exhaust all combinations; only completely idle is safe.
        for mask in 0..<256 {
            let flags = (0..<8).map { mask & (1 << $0) != 0 }
            XCTAssertEqual(PrivateUpdatePolicy.canInstall(
                cameraRequested: flags[0], cameraRunning: flags[1], captureBusy: flags[2],
                recording: flags[3], loopActive: flags[4], testing: flags[5],
                consumerActive: flags[6], connectedWithUnknownDemand: flags[7]), mask == 0)
        }
    }

    func testOnlyExpandedBundledTokensAreUsed() {
        XCTAssertEqual(PrivateUpdatePolicy.bundledToken(" github_pat_abc123\n"), "github_pat_abc123")
        XCTAssertNil(PrivateUpdatePolicy.bundledToken("$(OPAL_UPDATE_TOKEN)"), "Unexpanded build setting")
        XCTAssertNil(PrivateUpdatePolicy.bundledToken(""), "Development builds have no token")
        XCTAssertNil(PrivateUpdatePolicy.bundledToken("two words"))
        XCTAssertNil(PrivateUpdatePolicy.bundledToken(nil))
        XCTAssertNil(PrivateUpdatePolicy.bundledToken(42))
    }
}
