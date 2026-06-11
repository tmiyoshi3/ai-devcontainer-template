# DevContainer Podman-in-Podman 要件定義

## 背景

macOS 上の VS Code で AI 駆動開発（Claude Code 等）を行う場合、AI が生成・実行するコードによるサプライチェーン攻撃のリスクがある。mac 上で直接開発すると、悪意あるコードが mac 内の他プロジェクトや認証情報（`~/.ssh`、`~/.aws` 等）にアクセスし、情報が漏洩する危険性がある。

影響範囲を最小化するため、開発環境を DevContainer 内に閉じ込める。

## 脅威モデル

1. **サプライチェーン攻撃:** AI が提案・実行する依存パッケージやコードに悪意あるコードが含まれるケース
2. **意図しないコマンド実行:** AI がホスト環境に影響を与えるコマンドを実行するケース
3. **情報漏洩:** 開発中のプロジェクトから mac 内の他プロジェクトや認証情報へのアクセス

## なぜ Podman-in-Podman か

DevContainer 内でアプリケーションコンテナを起動する必要がある（後述）。通常の方法ではホストの Podman ソケットを DevContainer にマウントし、ホスト側でコンテナを起動するが、この構成では DevContainer 内の侵害がホスト環境の侵害に直結する。

Podman-in-Podman 構成にすることで、DevContainer 内で起動したコンテナはすべて DevContainer 内に閉じ込められ、ホスト環境への影響を防ぐ。

## 要件

### R1: 開発環境の隔離

開発環境（コードベース、依存パッケージ、ビルド成果物）が DevContainer 内に閉じ込められていること。mac 上の他プロジェクトや認証情報にアクセスできないこと。

### R2: DevContainer 内でのコンテナビルド・起動

DevContainer 内で `podman build` / `podman run` が動作し、アプリケーションコンテナをビルド・起動できること。ホストの Podman ソケットを使用しないこと（Podman-in-Podman）。

### R3: ポートマッピング

DevContainer 内で起動したコンテナのポートを DevContainer 内からアクセスできること（`curl localhost:<port>`）。

### R4: ホストブラウザからのアクセス

DevContainer 内で起動したアプリケーションに、ホスト（mac）のブラウザからアクセスして動作確認できること。

### R5: Playwright MCP / E2E テスト

DevContainer 内で Playwright を使用した E2E テストが実行できること。また、AI 駆動開発で Playwright MCP を利用できること。

### R6: セキュリティ

- `--privileged` を使用しないこと
- ホストの Podman ソケットをマウントしないこと
- 必要最小限の権限（`--device=/dev/fuse`、`--device=/dev/net/tun`、`--security-opt=label=disable`）のみ付与すること
