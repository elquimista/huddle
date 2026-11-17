import Foundation
import MatrixRustSDK

extension Error {
    /// A message fit to show in the UI, instead of the SDK's debug descriptions.
    var userMessage: String {
        switch self {
        case let error as ClientError:
            switch error {
            case .MatrixApi(let kind, _, let message, _):
                switch kind {
                case .forbidden: return "Incorrect username or password."
                case .limitExceeded: return "Too many attempts. Wait a moment and try again."
                case .unknownToken: return "Your session has expired. Sign in again."
                case .connectionFailed, .connectionTimeout: return "Couldn't reach the server. Check your connection."
                default: return message
                }
            case .Generic(let message, _): return message
            case .ContentScanner(_, let info): return info
            }
        case let error as ClientBuildError:
            switch error {
            case .InvalidServerName: return "That doesn't look like a valid server name."
            case .ServerUnreachable, .WellKnownLookupFailed, .WellKnownDeserializationError:
                return "Couldn't find a Matrix homeserver at that address."
            case .SlidingSync, .SlidingSyncVersion: return LoginError.slidingSyncUnsupported.localizedDescription
            case .WellKnownLookupDisabled(let message), .Sdk(let message),
                 .EventCache(let message), .Generic(let message): return message
            }
        case let error as RecoveryError:
            switch error {
            case .SecretStorage: return "That recovery key isn't right. Check it and try again."
            case .Client(let source): return source.userMessage
            case .BackupExistsOnServer, .Import: return "Couldn't restore your encryption keys. Try again."
            }
        case let error as OAuthError:
            switch error {
            case .Cancelled: return LoginError.cancelled.localizedDescription
            case .NotSupported(let message), .MetadataInvalid(let message),
                 .CallbackUrlInvalid(let message), .Generic(let message): return message
            }
        default:
            return localizedDescription
        }
    }
}
