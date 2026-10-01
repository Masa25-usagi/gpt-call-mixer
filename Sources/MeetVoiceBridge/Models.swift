import CoreAudio
import Foundation

struct AudioProcessSnapshot: Identifiable, Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let executablePath: String
    let isRunningOutput: Bool

    var id: AudioObjectID { objectID }
}

enum BridgeSource: String, CaseIterable, Identifiable, Sendable {
    case meet
    case chatGPT

    var id: String { rawValue }

    var sourceLabel: String {
        switch self {
        case .meet: "Google Chrome / Meet"
        case .chatGPT: "ChatGPT"
        }
    }

    var destinationLabel: String {
        switch self {
        case .meet: "ChatGPT"
        case .chatGPT: "Google Meet"
        }
    }

    var deviceName: String {
        switch self {
        case .meet: "MVB Meet → ChatGPT"
        case .chatGPT: "MVB ChatGPT → Meet"
        }
    }

    var aggregateUID: String {
        switch self {
        case .meet: "jp.local.meetvoicebridge.meet-to-chatgpt"
        case .chatGPT: "jp.local.meetvoicebridge.chatgpt-to-meet"
        }
    }

    var knownBundleIDs: [String] {
        switch self {
        case .meet:
            [
                "com.google.Chrome",
                "com.google.Chrome.helper",
                "com.google.Chrome.helper.renderer"
            ]
        case .chatGPT:
            [
                "com.openai.codex",
                "com.openai.codex.helper",
                "com.openai.codex.helper.renderer"
            ]
        }
    }
}

struct BridgeRouteState: Identifiable, Equatable, Sendable {
    let source: BridgeSource
    let aggregateDeviceID: AudioObjectID
    let tappedProcessCount: Int
    let bundleIDs: [String]

    var id: BridgeSource { source }
}

enum ProcessMatcher {
    static func matches(_ process: AudioProcessSnapshot, source: BridgeSource) -> Bool {
        let bundleID = process.bundleID.lowercased()
        let name = process.name.lowercased()
        let path = process.executablePath.lowercased()

        switch source {
        case .meet:
            return bundleID == "com.google.chrome"
                || bundleID.hasPrefix("com.google.chrome.")
                || path.contains("/google chrome.app/")
                || name == "google chrome"
                || name.hasPrefix("google chrome helper")
        case .chatGPT:
            return bundleID == "com.openai.codex"
                || bundleID.hasPrefix("com.openai.codex.")
                || path.contains("/chatgpt.app/")
                || name == "chatgpt"
                || name.hasPrefix("codex")
        }
    }

    static func matching(
        _ processes: [AudioProcessSnapshot],
        source: BridgeSource
    ) -> [AudioProcessSnapshot] {
        processes
            .filter { matches($0, source: source) }
            .sorted {
                if $0.isRunningOutput != $1.isRunningOutput {
                    return $0.isRunningOutput && !$1.isRunningOutput
                }
                return $0.pid < $1.pid
            }
    }
}

struct BridgeFailure: LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var description: String { message }
}
