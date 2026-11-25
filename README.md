# MyCATTLES

### 個人情報は、私自身が必要なものを判断する。

**MyCATTLES — 自分の情報を、自分で管理する。**

MyCATTLESは、Webサービスへの会員登録やアカウント管理において、**サービスごとに提供する情報を利用者自身が生成・管理する**ためのアプリケーションです。

私たちは日々、多くのWebサービスに個人情報を登録しています。しかし、すべてのサービスに同じ情報を提供する必要があるとは限りません。

MyCATTLESは、必要に応じて代替情報を生成し、サービスごとに登録内容を使い分けることで、個人情報の不要な共有を減らすことを目指しています。

---

## ダウンロード

Windows x64 版 v0.2.4 を公開しました。画面の案内と登録済み項目の編集を改善しました。Chrome拡張 MyCATTLES Bridge v1.1.1 では、アイコンとフォーム連携画面を見直しました。

[最新版をダウンロードする（GitHub Releases）](https://github.com/tillshift/MyCATTLES-Releases/releases/latest)

| 配布ファイル | 内容 |
|---|---|
| [MyCATTLES-Setup-0.2.4-win-x64.exe](https://github.com/tillshift/MyCATTLES-Releases/releases/download/v0.2.4/MyCATTLES-Setup-0.2.4-win-x64.exe) | Windows x64 版インストーラー |
| [MyCATTLES-Bridge-1.1.1-WebStore.zip](https://github.com/tillshift/MyCATTLES-Releases/releases/download/v0.2.4/MyCATTLES-Bridge-1.1.1-WebStore.zip) | Chrome拡張 v1.1.1 の手動導入用ZIP |
| [SHA256SUMS.txt](https://github.com/tillshift/MyCATTLES-Releases/releases/download/v0.2.4/SHA256SUMS.txt) | Windowsインストーラーの整合性確認用 |

Windowsアプリ単体でも利用できます。ブラウザとのフォーム連携機能を利用する場合は、Chrome拡張機能も導入してください。

## 主な機能

### サービスごとの登録情報管理

Webサービスごとにアカウント情報を管理できます。

生成した情報と実際に登録した情報を区別し、サービスにどのような情報を提供しているかを把握できます。

### 代替情報の生成

ユーザー名、パスワード、任意の文字列などについて、登録先に応じた情報の生成を支援します。

複数のサービスで同じ情報を使い回すことを減らすための機能です。

### 二段階認証（TOTP）

Windows アプリでサービスやアカウントごとに TOTP の設定を管理し、認証コードを生成・表示・コピーできます。MyCATTLES Bridge を使うと、対応する設定用 QR コードを Web ページから取り込めます。

### Chrome拡張機能との連携

Webページのフォームを解析し、MyCATTLESとの情報連携を支援します。

- フォームの入力項目を取得
- アプリ側で登録情報の候補を生成
- 対応するフォーム項目への入力を支援

※ Webサイトの構造によっては、一部項目の検出や自動入力に対応できない場合があります。

---

## インストール方法

### 1. Windowsアプリのインストール

1. [最新版のリリースページ](https://github.com/tillshift/MyCATTLES-Releases/releases/latest)を開きます。
2. `MyCATTLES-Setup-0.2.4-win-x64.exe` をダウンロードします。
3. インストーラーを実行します。
4. 画面の案内に従ってインストールします。

### 2. Chrome拡張機能の導入（任意）

通常は [Chrome ウェブストアから MyCATTLES Bridge を追加](https://chromewebstore.google.com/detail/mycattles-bridge/iomnjcehdaoifhnmjdbljikfdndccfja?hl=ja)します。

ZIP から手動で導入する場合は、以下の手順に従ってください。

1. `MyCATTLES-Bridge-1.1.1-WebStore.zip` をダウンロードして展開します。
2. Chromeで `chrome://extensions/` を開きます。
3. 「デベロッパーモード」を有効にします。
4. 「パッケージ化されていない拡張機能を読み込む」を選択します。
5. `manifest.json` があるフォルダーを指定します。

### 3. Chrome拡張機能との連携設定

拡張機能IDがインストーラーに登録されたIDと異なる場合、PowerShellで次のコマンドを実行してください。

```powershell
& "$env:LOCALAPPDATA\Programs\MyCATTLES\host\register_github_extension.ps1" -ExtensionId "Chromeに表示された拡張機能ID"
```

Chrome拡張機能の詳細画面からIDを確認できます。

詳しい導入手順や注意事項については、[v0.2.4のリリースノート](https://github.com/tillshift/MyCATTLES-Releases/releases/tag/v0.2.4)をご覧ください。

---

## 対応環境

| 項目 | 対応状況 |
|---|---|
| Windows x64 | 対応 |
| Google Chrome | 拡張機能による連携 |
| Android | 今後の開発対象 |
| iOS | 今後の開発対象 |

## セキュリティとプライバシー

MyCATTLESは、利用者自身が登録情報を管理し、サービスに提供する情報を選択できる環境を目指しています。

ただし、個人情報の漏洩防止、完全な匿名性、サービス提供者による個人の識別防止を保証するものではありません。

**Windowsのセキュリティ警告について**

現在のWindowsインストーラーは自己署名証明書を使用しています。そのため、Windows SmartScreenなどで警告が表示される場合があります。

配布元とダウンロードファイルの整合性を確認し、内容を理解したうえで実行を判断してください。

各リリースには、SHA256ハッシュ値を記載した `SHA256SUMS.txt` を同梱しています。

**不具合報告時のお願い**

パスワード、認証コード、氏名、住所などの個人情報や秘密情報を、公開Issueに投稿しないでください。

---

## 不具合報告・改善要望

不具合や改善要望は、GitHub Issuesで受け付けています。

**[不具合報告・改善要望を投稿する](https://github.com/tillshift/MyCATTLES-Releases/issues)**

報告時には、利用しているバージョン、発生した操作、期待した結果、実際の結果を記載してください。

## 今後の開発

MyCATTLESでは、利用者自身が個人情報を管理できる仕組みの拡充を目指しています。

今後の開発対象には、ブラウザ連携の改善、代替情報生成機能の拡充、匿名化支援機能、対応プラットフォームの追加などがあります。

機能の提供時期や実装内容は、開発状況により変更される場合があります。

## 開発支援のお願い

MyCATTLESの普及に向け、クラウドファンディングを通じた支援を募集しています。

**[CAMPFIRE — MyCATTLES開発支援プロジェクト](https://camp-fire.jp/projects/993289/view)**

プロジェクトの募集状況や支援条件については、CAMPFIREの掲載内容をご確認ください。

---

## About MyCATTLES (English)

MyCATTLES is a Windows application designed to help users generate and manage different registration information for different online services.

Its goal is to reduce unnecessary sharing and reuse of personal information while giving users greater control over what they provide to each service.

The current release supports Windows x64, with optional Google Chrome extension integration for web form assistance.

**[Download the latest release](https://github.com/tillshift/MyCATTLES-Releases/releases/latest)**

Note: MyCATTLES does not guarantee complete anonymity or protection against data breaches.

---

**Developed and published by TILLSHIFT.**
