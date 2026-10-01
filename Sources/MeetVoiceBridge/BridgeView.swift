import SwiftUI

struct BridgeView: View {
    @ObservedObject var controller: BridgeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusPanel
                ForEach(BridgeSource.allCases) { source in
                    routePanel(source)
                }
                privacyPanel
                controls
            }
            .padding(22)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 660)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.stop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meet Voice Bridge")
                .font(.system(size: 26, weight: .semibold))
            Text("Google MeetとChatGPT Voiceのアプリ出力を、相互に独立した仮想マイクとして公開します。")
                .foregroundStyle(.secondary)
            Label("録音ファイルは作成せず、ヘルパー自身は音声バッファを読みません", systemImage: "waveform.badge.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(controller.statusMessage)
                .font(.headline)
            Spacer()
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 42)
            }
        }
        .padding(.bottom, controller.errorMessage == nil ? 0 : 54)
    }

    private func routePanel(_ source: BridgeSource) -> some View {
        let matched = controller.matchingProcesses(for: source)
        let route = controller.routes.first { $0.source == source }

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(source == .meet ? .blue : .purple)
                Text("\(source.sourceLabel) → \(source.destinationLabel)")
                    .font(.headline)
                Spacer()
                Text(route == nil ? "未作成（無音）" : "Device ID \(route!.aggregateDeviceID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(route == nil ? Color.orange : Color.secondary)
            }

            Text(source.deviceName)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .textSelection(.enabled)

            Text("検出: \(matched.count)プロセス（音声出力中 \(matched.filter(\.isRunningOutput).count)）")
                .font(.callout)
                .foregroundStyle(.secondary)

            if matched.isEmpty {
                Text("macOS 26ではBundle IDで待機するため、現在音声がなくても開始できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(processSummary(matched))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("初回の「システムオーディオ録音」許可", systemImage: "lock.shield")
                .font(.headline)
            Text("「開始」でデバイスを作成し、ChatGPTまたはMeetが初めて入力を開くとmacOSが許可を求める場合があります。許可後に再起動を求められた場合は、このアプリだけを再起動してください。Mac本体の再起動は通常不要です。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("プライバシー設定を開く") {
                controller.openAudioCapturePrivacySettings()
            }
            .buttonStyle(.link)
        }
    }

    private var controls: some View {
        HStack {
            Button("再検出") {
                controller.refresh()
            }
            .disabled(controller.isBusy)

            Spacer()

            Button("停止") {
                controller.stop()
            }
            .disabled(!controller.isRunning || controller.isBusy)

            Button("開始") {
                controller.start()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(controller.isRunning || controller.isBusy)
        }
    }

    private func processSummary(_ processes: [AudioProcessSnapshot]) -> String {
        processes.prefix(8).map { process in
            let active = process.isRunningOutput ? "●" : "○"
            let bundle = process.bundleID.isEmpty ? "bundle-idなし" : process.bundleID
            return "\(active) PID \(process.pid)  \(bundle)"
        }
        .joined(separator: "\n")
    }
}
