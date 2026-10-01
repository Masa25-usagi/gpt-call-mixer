import AppKit
import Combine
import Foundation

@MainActor
final class BridgeController: ObservableObject {
    @Published private(set) var processes: [AudioProcessSnapshot] = []
    @Published private(set) var routes: [BridgeRouteState] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "未開始 — 「開始」するまで仮想入力は無音です"
    @Published private(set) var errorMessage: String?

    private let engine = CoreAudioBridgeEngine()

    init() {
        refresh()
    }

    func matchingProcesses(for source: BridgeSource) -> [AudioProcessSnapshot] {
        ProcessMatcher.matching(processes, source: source)
    }

    func refresh() {
        do {
            processes = try ProcessDiscovery.discover()
            errorMessage = nil
            if !isRunning {
                statusMessage = "対象プロセスを更新しました — 「開始」するまで仮想入力は無音です"
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "プロセス検出に失敗"
        }
    }

    func start() {
        guard !isBusy, !isRunning else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = "2つの仮想入力を作成中…"

        refresh()
        do {
            routes = try engine.start(processes: processes)
            isRunning = true
            statusMessage = "動作中 — 下記の入力デバイスを各アプリで選択してください"
        } catch {
            routes = []
            isRunning = false
            errorMessage = error.localizedDescription
            statusMessage = "開始できませんでした"
        }
        isBusy = false
    }

    func stop() {
        engine.stop()
        routes = []
        isRunning = false
        isBusy = false
        statusMessage = "停止しました。仮想入力を破棄しました"
    }

    func openAudioCapturePrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
