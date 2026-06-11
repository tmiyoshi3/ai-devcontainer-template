# DevContainer (Podman-in-Podman)

ローカルPCのファイルシステムから隔離された開発環境。ホストのPodmanソケットをマウントしないため、DevContainer内からホストのファイルにアクセスする手段がない(わけじゃないだろうけどできる限り最小化)。  
起動したDevContainer内でpodman-in-podmanを利用でき、claude code(GCP Vertex経由)、playwright MCPの準備が整っている(つもり)。  

## 前提条件

- [Podman](https://podman.io/) がインストール済み (v5.0+推奨)
- VS Code + [Dev Containers 拡張機能](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
- VS Code の設定で `dev.containers.dockerPath` を `podman` に変更
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) がインストール済みで、以下の認証が完了していること（Claude Code を Vertex AI 経由で使用するため）:
  ```bash
  gcloud init
  gcloud auth application-default login
  ```

  環境変数に以下が必要  
  ```
  GCLOUD_QUOTA_PROJECT=*1
  ANTHROPIC_VERTEX_PROJECT_ID=*2
```
*1 gcloud auth application-default set-quota-project <ここに指定した値>  
*2 claude code設定手順で設定する環境変数


## 使い方

1. プロジェクトを VS Code で開く
2. コマンドパレット (`Cmd+Shift+P`) → **Dev Containers: Reopen in Container**
3. DevContainer 内のターミナルでコンテナを操作:

```bash
# Podman の動作確認
podman run --rm docker.io/library/busybox echo "OK"

# アプリコンテナのビルド・起動
podman build -t my-app -f Containerfile .
podman run -d -p 8080:80 my-app

# nginx を起動する例
podman run -d -p 8080:80 docker.io/library/nginx

# compose を使う場合
podman-compose up -d
```

## ファイル構成

```
.devcontainer/
  Containerfile             # DevContainerイメージのビルド定義
  devcontainer.json         # DevContainer設定 (runArgs等)
  containers.conf           # 内部Podmanのシステムレベル設定
  podman-containers.conf    # 内部Podmanのユーザーレベル設定
  storage.conf              # 内部Podmanのストレージ設定
```

## 構成の解説

### なぜこの構成が必要か

macOS上のPodman Desktop (podman machine) でDevContainerを起動し、その中でさらにPodmanを動かす
「Podman-in-Podman」構成では、以下の4つの問題が発生する:

| エラー | 原因 | 解決策 |
|--------|------|--------|
| `newuidmap: write to uid_map failed: Operation not permitted` | newuidmapにsetuidビットがない | `chmod u+s` + `shadow-utils`の再インストール |
| `newuidmap: write to uid_map failed: Invalid argument` | subuid/subgidの範囲が重複 | UID 10000開始の重複しない範囲を設定 |
| `unlinkat: operation not permitted` | overlay-on-overlayがカーネルに拒否される | fuse-overlayfsを使用 |
| `pasta failed: Failed to open() /dev/net/tun` | pastaが必要とする/dev/net/tunがない | slirp4netnsをデフォルトに変更 |

### ストレージドライバ

**overlay + fuse-overlayfs** を使用。

- `vfs`: 各レイヤーの完全コピーが必要で非常に遅い
- `native overlay`: カーネルのoverlayだがネストされたコンテナではoverlay-on-overlayが拒否される
- `overlay + fuse-overlayfs`: FUSE経由のユーザー空間overlay実装。COW (Copy-on-Write) をサポートし、vfsより大幅に高速

### ネットワークモード

**slirp4netns** を使用 (containers.confで設定)。

- `pasta` (Podman 5.xのデフォルト): `/dev/net/tun`が必要だがネストコンテナ内では利用不可
- `slirp4netns`: `/dev/net/tun`不要。TAP deviceをユーザー空間で作成しネットワーク変換を行う
- `host`: 分離なしだが最も確実 (必要に応じて`--network host`で個別に使用可能)

### devcontainer.json の runArgs

| 引数 | 目的 |
|------|------|
| `--userns=keep-id:uid=1000,gid=1000` | ホストUIDとコンテナUIDを一致させワークスペースのパーミッションを維持 |
| `--cap-add=SYS_ADMIN` | 内部Podmanがファイルシステムをマウントするために必要 |
| `--device=/dev/fuse` | fuse-overlayfsが必要とするFUSEデバイスを提供 |
| `--security-opt=label=disable` | SELinuxラベル分離を無効化 (マウント操作に必要) |
| `--security-opt=seccomp=unconfined` | seccompフィルタを無効化 (mount, unshare等のsyscallに必要) |

## 別プロジェクトへの導入

`.devcontainer/` ディレクトリごとコピーすればそのまま使える。プロジェクト固有のツール（Node.js、Python 等）が必要な場合は `Containerfile` の `dnf install` に追加する。

## トラブルシューティング

### ストレージドライバの確認
```bash
podman info --format '{{.Store.GraphDriverName}}'
# 期待値: overlay
```

### ネットワークモードの確認
```bash
podman info --format '{{.Host.NetworkBackend}}'
```

### ストレージのリセット
```bash
podman system reset --force
```

### fuse-overlayfsが遅い場合 (大量ファイルのCOPY)
storage.conf の `driver` を `"vfs"` に変更し、`[storage.options.overlay]` セクションをコメントアウト。

## セキュリティ上のポイント

- ホストのPodmanソケットをマウントしていない → ホストファイルシステムへの脱出不可
- プロジェクトディレクトリのみマウントされる
- DevContainer内のPodmanはrootlessで動作
- `podman-compose` で複数コンテナを起動してもすべてDevContainer内に閉じる
- `--privileged`は使用せず、必要最小限のcapabilityのみ付与

## 参考資料

- [Red Hat: How to use Podman inside of a container](https://www.redhat.com/en/blog/podman-inside-container)
- [Podman Desktop: Build & run in a DevContainer](https://podman-desktop.io/blog/develop-using-devcontainer)
- [Official Podman stable image source](https://github.com/containers/image_build/tree/main/podman)
- [Podman rootless networking](https://www.redhat.com/en/blog/container-networking-podman)
- [Podman rootless overlay support](https://www.redhat.com/en/blog/podman-rootless-overlay)
