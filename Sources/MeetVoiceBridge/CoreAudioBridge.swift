import CoreAudio
import Foundation
import OSLog

struct AggregateDescriptionBuilder {
    static func make(
        source: BridgeSource,
        tapUUID: UUID
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: source.deviceName,
            kAudioAggregateDeviceUIDKey: source.aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: NSNumber(value: false),
            kAudioAggregateDeviceIsStackedKey: NSNumber(value: false),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: NSNumber(value: true)
                ]
            ]
        ]
    }
}

private struct RouteHandle {
    let state: BridgeRouteState
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
}

final class CoreAudioBridgeEngine {
    private let logger = Logger(
        subsystem: "jp.local.meetvoicebridge",
        category: "CoreAudioBridge"
    )
    private var handles: [RouteHandle] = []

    var isRunning: Bool { !handles.isEmpty }

    func start(processes: [AudioProcessSnapshot]) throws -> [BridgeRouteState] {
        guard #available(macOS 14.2, *) else {
            throw BridgeFailure("Process TapにはmacOS 14.2以降が必要です。")
        }

        stop()
        try removeStaleAggregateDevices()

        do {
            for source in BridgeSource.allCases {
                handles.append(try createRoute(source: source, processes: processes))
            }
        } catch {
            stop()
            throw error
        }

        return handles.map(\.state)
    }

    func stop() {
        guard #available(macOS 14.2, *) else {
            handles.removeAll()
            return
        }

        for handle in handles.reversed() {
            let aggregateStatus = AudioHardwareDestroyAggregateDevice(handle.aggregateDeviceID)
            if aggregateStatus != noErr {
                logger.error(
                    "Aggregate Device破棄失敗: \(CoreAudioProperties.osStatusDescription(aggregateStatus), privacy: .public)"
                )
            }

            let tapStatus = AudioHardwareDestroyProcessTap(handle.tapID)
            if tapStatus != noErr {
                logger.error(
                    "Process Tap破棄失敗: \(CoreAudioProperties.osStatusDescription(tapStatus), privacy: .public)"
                )
            }
        }
        handles.removeAll()
    }

    deinit {
        stop()
    }

    @available(macOS 14.2, *)
    private func createRoute(
        source: BridgeSource,
        processes: [AudioProcessSnapshot]
    ) throws -> RouteHandle {
        let matching = ProcessMatcher.matching(processes, source: source)
        let processIDs = matching.map(\.objectID)

        let tapDescription: CATapDescription
        if processIDs.isEmpty {
            tapDescription = CATapDescription()
            tapDescription.isMixdown = true
            tapDescription.isMono = false
        } else {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
        }

        tapDescription.name = "\(source.deviceName) Process Tap"
        tapDescription.uuid = UUID()
        tapDescription.isExclusive = false
        tapDescription.isPrivate = false
        tapDescription.muteBehavior = .unmuted

        var bundleIDs = Set(source.knownBundleIDs)
        bundleIDs.formUnion(matching.map(\.bundleID).filter { !$0.isEmpty })

        if #available(macOS 26.0, *) {
            tapDescription.bundleIDs = bundleIDs.sorted()
            tapDescription.isProcessRestoreEnabled = true
        } else if processIDs.isEmpty {
            throw BridgeFailure(
                "\(source.sourceLabel) のCore Audioプロセスがまだありません。音声を一度再生してから再試行してください。"
            )
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw BridgeFailure(
                "\(source.sourceLabel) のProcess Tap作成に失敗しました（\(CoreAudioProperties.osStatusDescription(status))）。システムオーディオ録音の許可を確認してください。"
            )
        }

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggregateDescription = AggregateDescriptionBuilder.make(
            source: source,
            tapUUID: tapDescription.uuid
        )
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw BridgeFailure(
                "\(source.deviceName) の公開入力デバイス作成に失敗しました（\(CoreAudioProperties.osStatusDescription(status))）。"
            )
        }

        let actualUID = CoreAudioProperties.deviceUID(aggregateDeviceID)
        guard actualUID == source.aggregateUID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw BridgeFailure(
                "\(source.deviceName) のUID検証に失敗しました（実値: \(actualUID)）。"
            )
        }

        logger.info(
            "Route作成: \(source.deviceName, privacy: .public), device=\(aggregateDeviceID, privacy: .public), processes=\(matching.count, privacy: .public)"
        )

        return RouteHandle(
            state: BridgeRouteState(
                source: source,
                aggregateDeviceID: aggregateDeviceID,
                tappedProcessCount: matching.count,
                bundleIDs: bundleIDs.sorted()
            ),
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID
        )
    }

    private func removeStaleAggregateDevices() throws {
        let ownUIDs = Set(BridgeSource.allCases.map(\.aggregateUID))
        for deviceID in try CoreAudioProperties.deviceObjectIDs() {
            let uid = CoreAudioProperties.deviceUID(deviceID)
            guard ownUIDs.contains(uid) else { continue }
            let status = AudioHardwareDestroyAggregateDevice(deviceID)
            guard status == noErr else {
                throw BridgeFailure(
                    "以前のMeetVoiceBridgeデバイスを破棄できませんでした（\(CoreAudioProperties.osStatusDescription(status))）。他のMeetVoiceBridgeを終了してください。"
                )
            }
        }
    }
}
