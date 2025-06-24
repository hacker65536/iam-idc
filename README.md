# iam-idc.sh - AWS IAM Identity Center CLI Tool

AWS IAM Identity Center（旧AWS SSO）の管理を効率化するコマンドラインツールです。グループやユーザーの一覧表示、検索、インタラクティブな選択機能を提供します。

## 特徴

- 🚀 **高速並列処理**: 複数のAWS API呼び出しを並列実行で高速化
- 🎯 **インタラクティブ選択**: fzfを使った直感的なグループ選択
- 🔍 **柔軟な検索**: グループ名での部分一致検索
- 📊 **複数出力形式**: JSON、Text、Table形式に対応
- 🎨 **スピナーアニメーション**: 処理中の視覚的フィードバック
- 🔧 **デバッグモード**: 詳細な処理状況の表示

## 必要な環境

### 必須
- **AWS CLI v2**: AWS APIへのアクセス
- **Bash 4.0+**: スクリプト実行環境
- **jq**: JSON処理（推奨）

### オプション
- **fzf**: インタラクティブなグループ選択
- **column**: テキスト出力の整形

### インストール例（macOS）
```bash
# Homebrew経由
brew install awscli jq fzf

# AWS CLIの設定
aws configure sso
```

## インストール

```bash
# リポジトリをクローン
git clone <repository-url>
cd iam-idc

# 実行権限を付与
chmod +x iam-idc.sh

# パスに追加（オプション）
sudo ln -s $(pwd)/iam-idc.sh /usr/local/bin/iam-idc
```

## 使用方法

### 基本コマンド

#### グループ一覧の表示
```bash
# 全グループを表示
./iam-idc.sh list-groups

# 特定の文字列を含むグループを検索
./iam-idc.sh list-groups Admin
./iam-idc.sh list-groups Section
```

#### ユーザー一覧の表示
```bash
# グループIDを指定してユーザー一覧を表示
./iam-idc.sh list-users group-12345678

# グループ名を指定してユーザー一覧を表示
./iam-idc.sh list-users-in-group Section

# インタラクティブにグループを選択
./iam-idc.sh list-users-in-group
```

### オプション

#### AWS設定
```bash
# 特定のAWSプロファイルを使用
./iam-idc.sh list-groups --profile myprofile

# 特定のリージョンを指定
./iam-idc.sh list-groups --region us-east-1

# Identity Store IDを直接指定
./iam-idc.sh list-groups --identity-store-id d-1234567890
```

#### 出力形式
```bash
# JSON形式で出力
./iam-idc.sh list-groups --output json

# Table形式で出力
./iam-idc.sh list-groups --output table

# Text形式（デフォルト）
./iam-idc.sh list-groups --output text
```

#### その他のオプション
```bash
# デバッグモードで実行
./iam-idc.sh list-groups --debug

# カラム整形を有効化
./iam-idc.sh list-groups --format
```

## 出力例

### グループ一覧
```
a1b2c3d4-e5f6-7890-abcd-ef1234567890  DevelopmentTeam       15
b2c3d4e5-f6g7-8901-bcde-f23456789012  ProductionAdmins      8
c3d4e5f6-g7h8-9012-cdef-345678901234  SecurityAuditors      12

合計グループ数: 3
```

### ユーザー一覧
```
d4e5f6g7-h8i9-0123-defg-456789012345  john.doe@example.com         John Doe            john.doe@example.com
e5f6g7h8-i9j0-1234-efgh-567890123456  jane.smith@example.com       Jane Smith          jane.smith@example.com
f6g7h8i9-j0k1-2345-fghi-678901234567  bob.wilson@example.com       Bob Wilson          bob.wilson@example.com
```

## 高度な機能

### インタラクティブ選択（fzf）
fzfがインストールされている場合、グループを視覚的に選択できます：

```bash
./iam-idc.sh list-users-in-group
```

- `↑↓`キーでグループを選択
- `Enter`で決定
- `Esc`でキャンセル
- プレビューウィンドウでグループ詳細を表示

### 並列処理による高速化
- 最大30の並列プロセスでAWS API呼び出しを実行
- 大量のグループやユーザーでも高速処理
- バッチ処理によるシステムリソースの効率的利用

### ページネーション対応
- AWS APIの100件制限を自動的に回避
- 大規模なグループ（100名以上）でも正確なユーザー数を表示
- NextTokenを使用した完全なデータ取得

## パフォーマンス

### ベンチマーク例
```bash
# 6グループの処理時間
time ./iam-idc.sh list-groups Section
# 実行時間: 2.071秒
# CPU使用率: 202%（並列処理効果）
```

### 最適化機能
- **バッチ並列処理**: システム負荷を制御しながら高速化
- **効率的なファイル結合**: `find + sort + xargs`による高速処理
- **スピナーアニメーション**: 処理中の視覚的フィードバック

## トラブルシューティング

### よくある問題

#### AWS認証エラー
```bash
# AWS SSOの再認証
aws sso login --profile your-profile

# 認証状態の確認
aws sts get-caller-identity
```

#### Identity Store IDが見つからない
```bash
# 手動でIdentity Store IDを指定
./iam-idc.sh list-groups --identity-store-id d-1234567890

# AWS SSOインスタンスの確認
aws sso-admin list-instances
```

#### fzfが見つからない
```bash
# macOSの場合
brew install fzf

# Ubuntuの場合
sudo apt install fzf
```

### デバッグモード
詳細な処理状況を確認したい場合：

```bash
./iam-idc.sh list-groups --debug
```

## 開発・カスタマイズ

### コード構造
- **並列処理**: `get_group_user_count()`でページネーション対応
- **スピナー**: `show_spinner()`で視覚的フィードバック
- **AWS CLI統合**: `build_aws_command()`で共通化
- **エラーハンドリング**: 各段階での適切なエラー処理

### 拡張可能性
- 新しいコマンドの追加が容易
- 出力形式の追加サポート
- 他のAWSサービスとの統合

## ライセンス

MIT License

## 貢献

プルリクエストやイシューの報告を歓迎します。

## 更新履歴

### v1.0.0
- 基本的なグループ・ユーザー一覧機能
- 並列処理による高速化
- fzfインタラクティブ選択
- スピナーアニメーション
- ページネーション対応
- 複数出力形式サポート
