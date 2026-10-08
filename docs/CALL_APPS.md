# LINE・Zoom・Macの電話の設定

v0.3.0では、LINEの音声／ビデオ通話・Zoom・Macの電話を通常ミキサーとMeet議事録モードの両方で選べます。Macで再生される音声が対象です。iPhone側だけで行っている通話や、映像・画面共有は転送しません。

## アプリごとの選択

| 会話アプリ | GPT Call Mixerの候補 | 音声プロセスの扱い |
| --- | --- | --- |
| LINE（Macデスクトップ版） | LINE（アプリ全体・音声／ビデオ通話） | LINE本体、LineCall、音声／メディアサービス、LINE用WebKitをまとめます |
| Zoom Workplace（Macデスクトップ版） | Zoom（アプリ全体・会議） | 本体とZoomMeeting・CptHost・caphostなどをまとめます |
| Macの電話 | 電話 / FaceTime（共有通話音声） | 電話本体、FaceTime、avconferenced・callservicesdなどの共有通話サービスをまとめます |

通話への参加後にミキサーの「再検出」を押します。音声処理用のHelperは、通話を始めるまで現れないことがあります。Macの電話アプリ自体はmacOS Tahoe 26以降で利用します。旧macOSではFaceTime経由のMac通話が同じ共有音声グループに入る場合があります。

電話の候補は、電話アプリを閉じていても待機中の共有サービスによって表示されます。FaceTimeなど、同じサービスを使う他のApple通話も同時に行うと音声が混ざる場合があります。電話だけを識別して分離することはできません。

## Meetで議事録を作る

1. LINE・Zoom・電話を普段どおり使い、物理マイクとヘッドホンを選んで通話に参加します。
2. ChromeでGoogle Meetを開き、GPT Call Mixerの「Meet議事録モード」をONにします。
3. 「1. 物理マイク」に普段のマイク、「2. Google Meetを開いているブラウザ」にChrome、「3. Meetへ流す会話アプリ」に対象アプリを選びます。
4. 「開始」を押し、Meetのマイクを `GPT Call Mixer → Call` に設定します。Meetのスピーカー／タブはミュートします。
5. Meetでメモを開始します。会話アプリ側のマイクは物理マイクのままにします。macOSの既定入力も変更しません。

会話アプリが「システム既定」のマイクを使っている場合は、システムの入力が普段の物理マイクになっていることを確認してください。Meet側のプランやメモ保存の詳細は [MEET_NOTES.md](MEET_NOTES.md) を参照してください。

## ChatGPT Voiceと双方向に話す

1. 「Meet議事録モード」をOFFにし、「2. 通話側の音声プロセス」でLINE・Zoom・電話のいずれかを選びます。
2. 「3. GPT Voice側の音声プロセス」にChatGPT / Codex、またはChatGPT Web Voiceを開いた別ブラウザを選びます。
3. ミキサーを開始します。ChatGPTの入力を `GPT Call Mixer → ChatGPT`、通話アプリの入力を `GPT Call Mixer → Call` にします。通話アプリのスピーカーはヘッドホンにします。

LINEは「設定 → 通話 → 基本」のマイク／スピーカー、Zoomは「設定 → オーディオ」または会議のオーディオ選択から変更します。各アプリで「システム既定」を使うと、ChatGPT用の一時的な既定入力切替の影響を受けるため、通話側のマイクを明示的に `→ Call` にしてください。

このMacの電話アプリ（macOS 26.6.2）では、メニューバーの「ビデオ → マイク → GPT Call Mixer → Call」で入力を選べることを確認しています。「ビデオ → 出力」は普段のヘッドホンにします。入力を選べない環境ではChatGPT音声を通話相手へ送る双方向接続は使えませんが、物理マイクを維持するMeet議事録モードは同じ手順で設定できます。

音声フィルターが混合音声を消してしまう場合は、通話アプリのマイクテストで確認し、ノイズ抑制などを調整します。新しい音声プロセスが現れたときは、停止→再検出→開始してください。再検出は同じモードで選んだアプリを維持し、開始時にも現在の音声プロセスを調べ直します。

## 検証範囲

プロセス分類、両モードの選択／受け渡し、既定マイクの維持・復元、再検出後の選択維持は自動テストで検証しています。実際の通話相手への送信、相手の音声取り込み、Meetのメモ生成、長時間通話は未検証です。短い通話で両方の声が届くことを確認してから使ってください。

## 公式設定資料

- [LINE：音声通話・ビデオ通話をする](https://help.line.me/line/?contentId=20000270&lang=ja)
- [Zoom：デスクトップアプリの設定](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060612)
- [Zoom：会議中のオーディオ設定](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062674)
- [Apple：MacのFaceTime・メール・メッセージ・電話](https://support.apple.com/ja-jp/guide/mac-studio/apd828c43bd3/mac)
