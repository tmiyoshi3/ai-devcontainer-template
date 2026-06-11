# DevContainer で Claude Code を使うためのセットアップ

Claude Code を Vertex AI 経由で使用する。セットアップは DevContainer の設定で自動化済み。

## 前提条件（ホストマシン側）

DevContainer を起動する前に、ホストマシンで gcloud の認証を済ませておく必要がある。

```bash
gcloud init
gcloud auth application-default login
```

認証済みであれば、DevContainer 起動時にホストの `~/.config/gcloud` が読み取り専用でマウントされ、コンテナ内に自動コピーされる。

## 自動化されている内容

以下はすべて DevContainer のビルド・起動時に自動で行われる。手動実行は不要。

| 項目 | 方法 | 設定ファイル |
|------|------|-------------|
| gcloud CLI インストール | Containerfile でビルド時にインストール | `.devcontainer/Containerfile` |
| Claude Code CLI インストール | Containerfile でビルド時にインストール | `.devcontainer/Containerfile` |
| jq インストール | Containerfile でビルド時にインストール（ADC設定用） | `.devcontainer/Containerfile` |
| gcloud 認証情報の引き継ぎ | ホストの `~/.config/gcloud` を読み取り専用マウント → コンテナ内にコピー | `.devcontainer/devcontainer.json`, `.devcontainer/setup-claude.sh` |
| ADC quota project 設定 | コピーした ADC に `GCLOUD_QUOTA_PROJECT` 環境変数の値を自動設定 | `.devcontainer/setup-claude.sh` |
| 環境変数の設定 | `devcontainer.json` の `containerEnv` で定義 | `.devcontainer/devcontainer.json` |

### 設定される環境変数

- `CLAUDE_CODE_USE_VERTEX=1`
- `CLOUD_ML_REGION=global`
- `ANTHROPIC_VERTEX_PROJECT_ID=${localEnv:ANTHROPIC_VERTEX_PROJECT_ID}`

## 仕組みの詳細

### gcloud 認証情報のマウントとコピー

ホストの認証情報を安全にコンテナ内で使うため、以下の方式を採用している。

1. `devcontainer.json` の `mounts` でホストの `~/.config/gcloud` を `/home/podman/.config/gcloud-host` に**読み取り専用**でマウント
2. `postCreateCommand` で `setup-claude.sh` を実行し、マウントされた設定を `/home/podman/.config/gcloud` にコピー（書き込み可能）
3. コピーした ADC ファイルに quota project (`GCLOUD_QUOTA_PROJECT` 環境変数の値) を jq で追加

読み取り専用マウントなので、コンテナ内からホストの認証ファイルが変更されることはない。

### ホストに gcloud 設定がない場合

`setup-claude.sh` がマウント元のディレクトリを検出できない場合、手動認証の手順がターミナルに表示される。
その場合はコンテナ内で以下を実行する：

```bash
gcloud init
gcloud auth application-default login
gcloud auth application-default set-quota-project <your-quota-project>
```

## 動作確認

DevContainer 起動後、以下で正常にセットアップされたか確認できる。

```bash
gcloud version                    # gcloud CLI が使えること
gcloud auth list                  # ホストの認証が引き継がれていること
claude --version                  # Claude Code がインストール済みであること
echo $CLAUDE_CODE_USE_VERTEX      # 環境変数が設定されていること
```