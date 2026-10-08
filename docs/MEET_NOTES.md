# Meet議事録モード（Superwhisperなしで議事録を作る）

Slackハドル・Discord・LINEの音声／ビデオ通話・Zoom・Macの電話の通話音声を、ブラウザで開いたGoogle Meetにマイクとして流し込み、
Meetの「Take notes（Geminiのメモ）」で議事録を作るための使い方です。
GPT Call Mixerは音声を送る経路を作ります。対象プランのMeetでメモを開始すると、
MeetがGoogleドキュメントをDriveに保存します。Superwhisperや別のアップロードツールは不要です。
通常のMeet会議のメモと逐語的な文字起こしは別の機能です。

## 音の流れ

```text
Slack / Discord / LINE / Zoom / Macの電話（Web通話はSafariなど）
        │  Process Tap（アプリ単位で取り込み・相手の声）
物理マイク（自分の声）─┤
        ▼
GPT Call Mixer → Call（仮想マイク）
        ▼
ChromeのGoogle Meet（Take notes）
        ▼
GeminiのメモがGoogleドキュメントに保存
```

会話アプリ自体は普段どおり物理マイクとスピーカー（ヘッドホン）を使います。
macOSの既定入力は変更しません。

## 準備

1. `./script/build_gpt_call_mixer.sh --verify` でビルドします（既定でApple Silicon・Intel両対応のユニバーサル）。
2. READMEの手順でHALドライバ2本を `/Library/Audio/Plug-Ins/HAL/` に入れ、Macを再起動します。
3. Meetの主催アカウントが「Take notes」対象のGoogle WorkspaceエディションまたはGoogle AIプランであることを確認します。職場・学校のアカウントでは管理者の設定も必要です。対象プランは変更されるため、[Googleの公式ヘルプ](https://support.google.com/meet/answer/14754931?hl=ja)で確認してください。

## 使い方

1. 対象アプリの通話に参加します。LINEは音声・ビデオ通話のどちらでも使えます。ZoomはMacのデスクトップ版、電話はMac上で音声が出ている通話を使います。Web版を使う場合はMeetと別のブラウザ（Safariなど）で開きます。アプリ別の設定は [CALL_APPS.md](CALL_APPS.md) を参照してください。
2. ChromeでGoogle Meetを開きます。
   - 通常のMeet会議：自分だけの会議を作ります。
   - 対面会議モード：アカウントで利用できる場合はMeetのホームの「Take notes」を使えます。[公式手順](https://support.google.com/meet/answer/17020724?hl=ja&co=GENIE.Platform%3DDesktop)も参照してください。音声経路を設定してからメモを開始します。
3. `GPTCallMixer.app` を起動し「Meet議事録モード」にチェックを入れます。
   - 1. 物理マイク：普段のマイク
   - 2. Google Meetを開いているブラウザ：Google Chrome
   - 3. Meetへ流す会話アプリ：Slack、Discord、LINE、Zoom、または「電話 / FaceTime（共有通話音声）」
   - 候補が出ない場合は対象アプリで一度音声を再生し、「再検出」を押します。
4. 「開始」を押します。
5. Meetのマイクを `GPT Call Mixer → Call` にします。
   - 会議画面：設定 → 音声 → マイク
   - 対面会議モードなどで選べない場合：Chromeの `chrome://settings/content/microphone` で
     Chromeの既定マイクを `GPT Call Mixer → Call` にし、Meetの入力を開き直します。
     この選択はChrome内の他のサイトにも影響します。サイトごとの「マイクを許可」とは別の設定です。
     [Chromeの公式ヘルプ](https://support.google.com/chrome/answer/2693767?hl=ja)も参照してください。
6. Meetのタブ（スピーカー）はミュートします。会話アプリはヘッドホン推奨です。
7. Meet側で「Take notes」を開始し、入力メーターや字幕で自分と相手の両方の声が届くことを確認します。逐語的な記録も必要なら、通常の会議では利用可能な「文字起こし」を別途開始します。
8. 終わったらMeet側でメモを停止し、会議を終了してからミキサーを「停止」します。Meetが生成したドキュメントをDriveまたは通知メールで確認します。Chromeの既定マイクを変更した場合は、元の選択に戻します。

## 制約

- Process Tapはアプリ単位です。MeetとWeb通話を同じブラウザで開くと分離できません。選んだアプリの通知音や別の通話も含む場合があります。
- 通話アプリが新しい音声プロセスを作った場合（通話に入り直した等）は、停止→再検出→開始します。同じモード内では選んだアプリと物理マイクを維持します。
- Macの電話はFaceTimeなどとシステム通話サービスを共有します。他のApple通話を同時に使うと、その音声も含む場合があります。電話だけに分離する機能はありません。
- Take notesは1会議1言語です。Meet側の言語設定を日本語にしてください。
- 通常のMeetには1本の混合マイクとして届きます。元の会話アプリの参加者名は引き継がれず、話者分離の精度も未検証です。
- 音声経路は短い会話で確認できますが、メモ生成についてGoogleは15分以上の会議を推奨しています。短い会議ではメモが生成されないことがあります。
- 各通話アプリからMeetのメモ生成までの実会議テストと、長時間の安定性は未検証です。利用する環境で確認してください。
