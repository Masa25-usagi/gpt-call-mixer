import SwiftUI

struct BridgeView: View {
    @ObservedObject var controller: BridgeController

    private let cardCornerRadius: CGFloat = 12
    private let cardPadding: CGFloat = 16
    private let sectionSpacing: CGFloat = 18

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Meet Voice Bridge")
                .font(.system(.largeTitle, weight: .semibold))
            Text("Google MeetとChatGPT Voiceのアプリ出力を、相互に独立した仮想マイクとして公開します。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("録音ファイルは作成せず、ヘルパー自身は音声バッファを読みません", systemImage: "waveform.badge.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                    .overlay {
                        if controller.isRunning {
                            Circle()
                                .strokeBorder(Color.green.opacity(0.35), lineWidth: 5)
                        }
                    }
                    .accessibilityLabel(controller.isRunning ? Text("動作中") : Text("停止中"))
                Text(controller.statusMessage)
                    .font(.headline)
                Spacer()
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(cardPadding)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    private func routePanel(_ source: BridgeSource) -> some View {
        let matched = controller.matchingProcesses(for: source)
        let route = controller.routes.first { $0.source == source }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.large)
                    .foregroundStyle(source == .meet ? Color.blue : Color.purple)
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
                Label("macOS 26ではBundle IDで待機するため、現在音声がなくても開始できます。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            } else {
                Text(processSummary(matched))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(cardPadding)
        .background(.background, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("初回の「システムオーディオ録音」許可", systemImage: "lock.shield")
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
            Text("「開始」でデバイスを作成し、ChatGPTまたはMeetが初めて入力を開くとmacOSが許可を求める場合があります。許可後に再起動を求められた場合は、このアプリだけを再起動してください。Mac本体の再起動は通常不要です。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("プライバシー設定を開く") {
                controller.openAudioCapturePrivacySettings()
            }
            .buttonStyle(.link)
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                controller.refresh()
            } label: {
                Label("再検出", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isBusy)

            Spacer()

            Button {
                controller.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .disabled(!controller.isRunning || controller.isBusy)

            Button {
                controller.start()
            } label: {
                Label("開始", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(controller.isRunning || controller.isBusy)
        }
        .controlSize(.large)
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
