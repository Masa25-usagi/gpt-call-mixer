import CoreAudio
import Foundation

enum SelfTestCommand {
    static func run() -> Bool {
        var failures: [String] = []
        var checks = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() {
                failures.append(message)
            }
        }

        let chrome = snapshot(
            objectID: 10,
            pid: 20,
            bundleID: "com.google.Chrome.helper.renderer",
            name: "Google Chrome Helper (Renderer)",
            path: "/Applications/Google Chrome.app/Contents/MacOS/helper",
            active: false
        )
        let chatGPT = snapshot(
            objectID: 11,
            pid: 30,
            bundleID: "com.openai.codex.helper",
            name: "Codex (Service)",
            path: "/Applications/ChatGPT.app/Contents/MacOS/helper",
            active: true
        )
        let unrelated = snapshot(
            objectID: 12,
            pid: 40,
            bundleID: "com.apple.Music",
            name: "Music",
            path: "/System/Applications/Music.app/Contents/MacOS/Music",
            active: true
        )

        check(ProcessMatcher.matches(chrome, source: .meet), "ChromeがMeet経路に一致しません")
        check(!ProcessMatcher.matches(chrome, source: .chatGPT), "ChromeがChatGPT経路へ混入します")
        check(ProcessMatcher.matches(chatGPT, source: .chatGPT), "ChatGPTがChatGPT経路に一致しません")
        check(!ProcessMatcher.matches(chatGPT, source: .meet), "ChatGPTがMeet経路へ混入します")
        check(!ProcessMatcher.matches(unrelated, source: .meet), "無関係なMusicがMeet経路へ混入します")
        check(!ProcessMatcher.matches(unrelated, source: .chatGPT), "無関係なMusicがChatGPT経路へ混入します")

        let chromeActive = snapshot(
            objectID: 13,
            pid: 50,
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            active: true
        )
        check(
            ProcessMatcher.matching([chrome, chromeActive], source: .meet).map(\.objectID) == [13, 10],
            "音声出力中プロセスが先頭に並びません"
        )

        check(
            BridgeSource.meet.aggregateUID != BridgeSource.chatGPT.aggregateUID,
            "2経路のAggregate Device UIDが重複しています"
        )

        let uuid = UUID(uuidString: "8C8F9430-9257-4F44-BBE6-C99DF07C37E6")!
        let description = AggregateDescriptionBuilder.make(
            source: .meet,
            tapUUID: uuid
        )
        check(
            description[kAudioAggregateDeviceIsPrivateKey] as? NSNumber == NSNumber(value: false),
            "Aggregate Deviceが公開設定ではありません"
        )
        check(description[kAudioAggregateDeviceSubDeviceListKey] == nil, "物理サブデバイスが混入しています")

        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        check(taps?.count == 1, "Aggregate DeviceのTap数が1ではありません")
        check(
            taps?.first?[kAudioSubTapUIDKey] as? String == uuid.uuidString,
            "Aggregate DeviceにTap UUIDが正しく入りません"
        )

        if failures.isEmpty {
            print("MeetVoiceBridge self-test: PASS (\(checks) checks)")
            return true
        }

        fputs("MeetVoiceBridge self-test: FAIL (\(failures.count)/\(checks))\n", stderr)
        for failure in failures {
            fputs("- \(failure)\n", stderr)
        }
        return false
    }

    private static func snapshot(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String,
        name: String,
        path: String,
        active: Bool
    ) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            name: name,
            executablePath: path,
            isRunningOutput: active
        )
    }
}
