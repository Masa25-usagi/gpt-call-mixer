import AppKit
import CoreAudio
import Darwin
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MeetVoiceBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = BridgeController()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            Darwin.exit(SelfTestCommand.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--diagnose") {
            DiagnosticCommand.run()
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        WindowGroup("Meet Voice Bridge") {
            BridgeView(controller: controller)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

enum DiagnosticCommand {
    static func run() {
        print("MeetVoiceBridge diagnostic (read-only)")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        do {
            let processes = try ProcessDiscovery.discover()
            print("Core Audio processes: \(processes.count)")
            for source in BridgeSource.allCases {
                let matching = ProcessMatcher.matching(processes, source: source)
                print("\n[\(source.sourceLabel)] matches=\(matching.count)")
                if matching.isEmpty {
                    print("  (none; macOS 26 bundle-ID restore can still create the route)")
                }
                for process in matching {
                    let activity = process.isRunningOutput ? "active" : "idle"
                    print("  object=\(process.objectID) pid=\(process.pid) \(activity) bundle=\(process.bundleID) name=\(process.name)")
                }
            }

            print("\nExisting MeetVoiceBridge devices:")
            let ownUIDs = Set(BridgeSource.allCases.map(\.aggregateUID))
            let ownDevices = try CoreAudioProperties.deviceObjectIDs().filter {
                ownUIDs.contains(CoreAudioProperties.deviceUID($0))
            }
            if ownDevices.isEmpty {
                print("  (none)")
            } else {
                for deviceID in ownDevices {
                    printDevice(deviceID, prefix: "  ")
                }
            }

            let defaultInputID = CoreAudioProperties.defaultInputDeviceID()
            print("\nDefault input:")
            printDevice(defaultInputID, prefix: "  ")
        } catch {
            fputs("diagnostic error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }


    private static func printDevice(_ deviceID: AudioObjectID, prefix: String) {
        let alive = CoreAudioProperties.deviceUInt32(
            deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        ) ?? UInt32.max
        let hidden = CoreAudioProperties.deviceUInt32(
            deviceID,
            selector: kAudioDevicePropertyIsHidden
        ) ?? UInt32.max
        let canDefault = CoreAudioProperties.deviceUInt32(
            deviceID,
            selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: kAudioObjectPropertyScopeInput
        ) ?? UInt32.max
        let streams = CoreAudioProperties.deviceInputStreamIDs(deviceID)
        let channels = CoreAudioProperties.deviceInputChannelCount(deviceID)
        print(
            "\(prefix)id=\(deviceID) name=\(CoreAudioProperties.deviceName(deviceID)) uid=\(CoreAudioProperties.deviceUID(deviceID)) alive=\(alive) hidden=\(hidden) canDefaultInput=\(canDefault) streams=\(streams.count) channels=\(channels)"
        )
    }
}
