import AppKit
import CoreAudio
import Darwin
import Foundation

enum CoreAudioProperties {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func processObjectIDs() throws -> [AudioObjectID] {
        try objectIDArray(
            objectID: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
    }

    static func deviceObjectIDs() throws -> [AudioObjectID] {
        try objectIDArray(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDevices
        )
    }

    static func defaultInputDeviceID() -> AudioObjectID {
        (try? scalar(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioObjectID(kAudioObjectUnknown)
        )) ?? AudioObjectID(kAudioObjectUnknown)
    }

    static func processPID(_ objectID: AudioObjectID) throws -> pid_t {
        try scalar(
            objectID: objectID,
            selector: kAudioProcessPropertyPID,
            defaultValue: pid_t(-1)
        )
    }

    static func processBundleID(_ objectID: AudioObjectID) -> String {
        (try? string(objectID: objectID, selector: kAudioProcessPropertyBundleID)) ?? ""
    }

    static func processIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
        let raw: UInt32 = (try? scalar(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput,
            defaultValue: UInt32(0)
        )) ?? 0
        return raw != 0
    }

    static func deviceUID(_ objectID: AudioObjectID) -> String {
        (try? string(objectID: objectID, selector: kAudioDevicePropertyDeviceUID)) ?? ""
    }

    static func deviceName(_ objectID: AudioObjectID) -> String {
        (try? string(objectID: objectID, selector: kAudioObjectPropertyName)) ?? ""
    }

    static func deviceUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        try? scalar(
            objectID: objectID,
            selector: selector,
            scope: scope,
            defaultValue: UInt32(0)
        )
    }

    static func deviceInputStreamIDs(_ objectID: AudioObjectID) -> [AudioObjectID] {
        (try? objectIDArray(
            objectID: objectID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )) ?? []
    }

    static func deviceInputChannelCount(_ objectID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let audioBufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, audioBufferList) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(audioBufferList)
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    static func processName(pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName,
           !name.isEmpty {
            return name
        }

        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "PID \(pid)" }
        return String(cString: buffer)
    }

    static func executablePath(pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    static func osStatusDescription(_ status: OSStatus) -> String {
        let unsigned = UInt32(bitPattern: status)
        let bytes = [
            UInt8((unsigned >> 24) & 0xff),
            UInt8((unsigned >> 16) & 0xff),
            UInt8((unsigned >> 8) & 0xff),
            UInt8(unsigned & 0xff)
        ]
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
            ? " ('\(String(bytes: bytes, encoding: .ascii) ?? "????")')"
            : ""
        return "\(status)\(fourCC)"
    }

    private static func objectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            throw BridgeFailure("Core Audio一覧のサイズ取得に失敗: \(osStatusDescription(status))")
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values)
        guard status == noErr else {
            throw BridgeFailure("Core Audio一覧の取得に失敗: \(osStatusDescription(status))")
        }
        return values
    }

    private static func scalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw BridgeFailure("Core Audioプロパティ \(selector) の取得に失敗: \(osStatusDescription(status))")
        }
        return value
    }

    private static func string(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw BridgeFailure("Core Audio文字列 \(selector) の取得に失敗: \(osStatusDescription(status))")
        }
        return value as String
    }
}

enum ProcessDiscovery {
    static func discover() throws -> [AudioProcessSnapshot] {
        guard #available(macOS 14.2, *) else {
            throw BridgeFailure("Process TapにはmacOS 14.2以降が必要です。")
        }

        return try CoreAudioProperties.processObjectIDs().compactMap { objectID in
            guard let pid = try? CoreAudioProperties.processPID(objectID), pid > 0 else {
                return nil
            }
            return AudioProcessSnapshot(
                objectID: objectID,
                pid: pid,
                bundleID: CoreAudioProperties.processBundleID(objectID),
                name: CoreAudioProperties.processName(pid: pid),
                executablePath: CoreAudioProperties.executablePath(pid: pid),
                isRunningOutput: CoreAudioProperties.processIsRunningOutput(objectID)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.pid < rhs.pid
        }
    }
}
