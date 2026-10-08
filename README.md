# GPT Call Mixer

ソースバージョン: **0.3.0**。変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照してください。

Google Meet・Slack・Discord・LINEの音声／ビデオ通話・Zoom・Macの電話とChatGPT音声の間に、物理マイクも混ぜて送るmacOS用のローカル音声ミキサーです。これらの会話音声をGoogle Meetへ送る議事録モードも使えます。

| 仮想デバイス | 送る音声 |
| --- | --- |
| `GPT Call Mixer → ChatGPT` | 物理マイク + 通話アプリの音声 |
| `GPT Call Mixer → Call` | 物理マイク + ChatGPT側の音声 |

相手へ送る経路から相手自身の音声を除くミックスマイナス方式です。物理スピーカーへのモニターにも対応します。音声を録音・保存する機能や、APIキーを使った外部AI接続はありません。接続先のMeetやChatGPTなどはそれぞれ音声を処理します。

この公開リポジトリにはソースと架空データのテストを収録しています。個人の会話、録音、設定、スクリーンショット、ビルド済みアプリ、既存の作業履歴は含めていません。

## 必要なもの

- macOS 14.2以降とXcode開発環境。
- ビルドスクリプトは既定でApple Silicon（`arm64`）とIntel（`x86_64`）のユニバーサルバイナリを作ります。Intelのみにする場合は `GPT_CALL_MIXER_ARCHS=x86_64` を指定します。Apple Siliconでの動作は実機で確認してください。
- 仮想デバイスを使うには付属のCore Audio HALドライバ2本の導入が必要です。

## ビルド

```bash
./script/build_gpt_call_mixer.sh --verify
```

アプリ、ドライバ2本、リングバッファ・音声プロセス分類・モード切替のテストをビルドし、アドホック署名を検証します。モード切替のテストは架空の音声エンジンと隔離した設定を使い、音声を取り込みません。ドライバのインストール、アプリ起動、管理者権限の取得、Core Audioの再起動は行いません。

成果物は `dist/GPTCallMixer-local-build.zip`。展開すると `GPTCallMixer.app` と `Drivers/` が入っています。開発用コピーは `dist/GPTCallMixer.app` と `dist/GPTCallMixerDrivers/` にも生成します。アドホック署名のためDeveloper ID署名・公証済みの配布アプリではありません。

ビルド済みのv0.3.0ユニバーサルZIPは [GitHub Releases](https://github.com/Masa25-usagi/gpt-call-mixer/releases/tag/v0.3.0) に掲載しています。同じアドホック署名のローカルビルドで、アプリとドライバ2本が含まれます。SHA-256ファイルも添付しています。

## ドライバの導入と使用

ドライバはmacOSの `/Library/Audio/Plug-Ins/HAL/` に置く形式です。導入には管理者権限が必要で、既存の同名ドライバがある場合は先にバックアップしてください。次の例はビルド済みの2本をコピーします。実行後にMacを再起動してから使います。

```bash
sudo ditto dist/GPTCallMixerDrivers/GPTCallMixer-ChatGPT.driver /Library/Audio/Plug-Ins/HAL/GPTCallMixer-ChatGPT.driver
sudo ditto dist/GPTCallMixerDrivers/GPTCallMixer-Call.driver /Library/Audio/Plug-Ins/HAL/GPTCallMixer-Call.driver
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/GPTCallMixer-ChatGPT.driver /Library/Audio/Plug-Ins/HAL/GPTCallMixer-Call.driver
```

1. 通話アプリとChatGPTを起動します。Web音声を使う場合はMeetをChrome、ChatGPTをSafariのように別ブラウザに分けます。
2. `GPTCallMixer.app` で物理マイク、通話アプリ、ChatGPT側のアプリを選び、開始します。
3. ChatGPTのマイクを `GPT Call Mixer → ChatGPT`、Meetのマイクを `GPT Call Mixer → Call` にします。
4. 必要なマイク・システムオーディオ権限を許可し、短い音声で両方向を確認します。イヤホンを使うとスピーカーからの回り込みを減らせます。

会議AIなどから音声をMeetへ直接送る場合も、出力を `GPT Call Mixer → Call` にし、Meetのマイクを同じデバイスにします。`→ ChatGPT` は別の経路です。

## Meet議事録モード（会話アプリ → Google Meet）

アプリの「Meet議事録モード」にチェックを入れると、Slackハドル・Discord・LINE・Zoom・Macの電話の会話と物理マイクを `GPT Call Mixer → Call` に送ります。ChromeのGoogle Meetでこのデバイスをマイクにし、対象プランの「Take notes」を開始すると、Meetが議事録をGoogleドキュメントに保存します。macOSの既定入力は変更しません。手順と文字起こしの制約は [docs/MEET_NOTES.md](docs/MEET_NOTES.md)、アプリ別の設定は [docs/CALL_APPS.md](docs/CALL_APPS.md) を参照してください。

LINEは本体・LineCall・音声サービス、Zoomは本体・会議／キャプチャ用Helperを一つの候補にまとめます。Macの電話は、FaceTimeなどが使うシステム通話サービスも同じ候補に含め、「電話 / FaceTime（共有通話音声）」と表示します。電話だけの音声に分離できない場合があるため、他のApple通話は同時利用を避けてください。

v0.3.0のコードレビューと検証範囲は [docs/REVIEW_CALL_APPS.md](docs/REVIEW_CALL_APPS.md)、旧議事録モードのレビューは [docs/REVIEW_MEET_NOTES.md](docs/REVIEW_MEET_NOTES.md) に記載しています。

## 制約と終了時の挙動

- 取り込みはアプリ／音声プロセス単位です。同じブラウザのMeetタブとChatGPTタブを分離できません。他のタブの音も含まれる場合があります。
- 通話アプリやブラウザが新しい音声プロセスを追加した場合は、ミキサーを停止→再検出→開始します。再検出では同じモードで選んだアプリと物理マイクを維持します。
- 一時的に既定マイクを変更した場合、停止時に元の入力へ戻します。途中で利用者が別の入力に変更した場合は、その変更を維持します。
- HALドライバは常設のループバックデバイスで、ミキサーを停止してもデバイス自体は残ります。
- 長時間の安定性、すべての通話クライアント、Apple Siliconでの動作を保証するものではありません。

## 旧版と診断ツール

`Sources/MeetVoiceBridge` は旧版のProcess Tapヘルパーです。こちらは物理マイクを混ぜません。`./script/build_and_run.sh --verify` で旧版のビルドと自己テストを実行できます。

`Tools/ChromeMeter` はブラウザ内だけで入力のピークを表示する診断ページです。録音・保存・送信は行いません。

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory Tools/ChromeMeter
```

## ライセンス

HALドライバはAppleのNullAudioサンプルの構成を参考にしており、元の許諾文を [Driver/LICENSE.txt](Driver/LICENSE.txt) に保持しています。ビルドしたドライバにも同じ文書を同梱します。その他の独自コードには、このリポジトリで新たなライセンスを付与していません。
