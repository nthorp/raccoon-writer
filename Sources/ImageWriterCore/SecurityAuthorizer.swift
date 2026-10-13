import Foundation
import Security

/// Shows the admin dialog through Security.framework, in the app's own process, so
/// the dialog names the app. The app still never runs as root: authopen does the open.
public struct SecurityAuthorizer: DeviceAuthorizer {
    static let prompt = "\(AppInfo.displayName) needs your password to erase and write the selected drive."

    public init() {}

    public func authorize(devicePath: String) throws -> any DeviceAuthorization {
        // Must match authopen's request exactly; `-o 2` (O_RDWR) makes it ask for readwrite.
        let right = Self.rightName(devicePath: devicePath)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        var reference: AuthorizationRef?
        let status = right.withCString { rightName in
            Self.prompt.withCString { promptText in
                kAuthorizationEnvironmentPrompt.withCString { promptKey in
                    var rightItem = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptKey,
                        valueLength: strlen(promptText),
                        value: UnsafeMutableRawPointer(mutating: promptText),
                        flags: 0
                    )
                    return withUnsafeMutablePointer(to: &rightItem) { rightItems in
                        withUnsafeMutablePointer(to: &promptItem) { promptItems in
                            var rights = AuthorizationRights(count: 1, items: rightItems)
                            var environment = AuthorizationEnvironment(count: 1, items: promptItems)
                            return AuthorizationCreate(&rights, &environment, flags, &reference)
                        }
                    }
                }
            }
        }
        guard status == errAuthorizationSuccess, let reference else {
            if let reference {
                AuthorizationFree(reference, [.destroyRights])
            }
            throw Self.error(for: status)
        }

        var external = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(reference, &external)
        guard externalStatus == errAuthorizationSuccess else {
            AuthorizationFree(reference, [.destroyRights])
            throw Self.error(for: externalStatus)
        }
        let bytes = withUnsafeBytes(of: external.bytes) { Array($0) }
        return SecurityAuthorization(reference: reference, externalForm: bytes)
    }

    static func rightName(devicePath: String) -> String {
        "sys.openfile.readwrite.\(devicePath)"
    }

    static func error(for status: OSStatus) -> DeviceOpenError {
        switch status {
        case errAuthorizationCanceled:
            return .userCancelled
        case errAuthorizationDenied:
            return .permissionDenied
        default:
            return .authorizationFailed(status: status)
        }
    }
}
