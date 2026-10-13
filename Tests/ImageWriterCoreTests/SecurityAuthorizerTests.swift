import Foundation
import Security
import Testing
@testable import ImageWriterCore

/// Never calls `authorize`, which would show a real dialog; only the pure parts.
struct SecurityAuthorizerTests {
    @Test func cancelAndDenialMapToTheExistingCases() {
        #expect(SecurityAuthorizer.error(for: errAuthorizationCanceled) == .userCancelled)
        #expect(SecurityAuthorizer.error(for: errAuthorizationDenied) == .permissionDenied)
    }

    @Test(arguments: [errAuthorizationInteractionNotAllowed, errAuthorizationInternal, errAuthorizationInvalidRef, OSStatus(-1)])
    func otherStatusesAreAuthorizationFailures(_ status: OSStatus) {
        #expect(SecurityAuthorizer.error(for: status) == .authorizationFailed(status: status))
    }

    @Test func rightMatchesWhatAuthopenAsksForWithORDWR() {
        #expect(SecurityAuthorizer.rightName(devicePath: "/dev/rdisk4") == "sys.openfile.readwrite./dev/rdisk4")
    }

    @Test func promptNamesTheApp() {
        #expect(SecurityAuthorizer.prompt.hasPrefix("ISO Sword "))
        #expect(!SecurityAuthorizer.prompt.contains("authopen"))
    }

    @Test func authorizationFailureDescriptionHasTheSystemMessageAndStatus() throws {
        let text = try #require(DeviceOpenError.authorizationFailed(status: errAuthorizationInternal).errorDescription)
        #expect(text.contains("OSStatus \(errAuthorizationInternal)"))
        #expect(!text.contains("unknown error"))
    }

    @Test func externalFormLengthMatchesTheFake() {
        #expect(FakeDeviceAuthorizer.sampleExternalForm.count == Int(kAuthorizationExternalFormLength))
        #expect(MemoryLayout<AuthorizationExternalForm>.size == Int(kAuthorizationExternalFormLength))
    }
}
