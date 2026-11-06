import Foundation

/// A dictation failure the app can switch on, so it never has to match message text.
public struct DictationError: LocalizedError, Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        /// Permission refused.
        case microphoneDenied
        /// No usable input device, or its format is unavailable.
        case noMicrophone
        /// The input route changed mid-recording.
        case microphoneChanged
        /// start() before prepare(), or the model was unloaded.
        case modelsNotReady
        /// prepare() was superseded by a model switch.
        case modelChanged
        /// The operation was attempted in the wrong state.
        case busy
        case other
    }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var errorDescription: String? { message }
}
