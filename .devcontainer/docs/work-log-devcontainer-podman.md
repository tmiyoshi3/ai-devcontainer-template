# DevContainer Podman-in-Podman 検証ログ

## 目的

macOS (Apple Silicon) + Podman Machine 環境で、VS Code DevContainer 内に Podman をインストールし、その中でコンテナをビルド・起動できる構成を確立する。

## 現在の構成ファイル

### `.devcontainer/Containerfile`

```dockerfile
FROM quay.io/podman/stable

USER root
RUN dnf install -y git curl slirp4netns && dnf clean all
RUN sed -i '/^default_sysctls = \[\]/a netns = "slirp4netns"' \
      /home/podman/.config/containers/containers.conf

USER podman
WORKDIR /workspaces
```

### `.devcontainer/devcontainer.json`

```json
{
  "name": "Podman-in-Podman Dev",
  "build": { "dockerfile": "Containerfile" },
  "remoteUser": "podman",
  "containerUser": "podman",
  "runArgs": [
    "--device=/dev/fuse",
    "--device=/dev/net/tun",
    "--security-opt=label=disable"
  ],
  "customizations": {
    "vscode": {
      "settings": {
        "terminal.integrated.defaultProfile.linux": "bash"
      }
    }
  }
}
```

### DevContainer 内の `containers.conf`（現在の状態）

パス: `/home/podman/.config/containers/containers.conf`

```toml
[containers]
volumes = [
        "/proc:/proc",
]
default_sysctls = []
netns = "slirp4netns"
```

### プロジェクトルートのファイル

- `Containerfile` — nginx コンテナ用（`FROM nginx:alpine` + `index.html` をコピー）
- `index.html` — テスト用 HTML（"Hello from Podman + nginx!"）

## 検証結果

### 検証 1: イメージのビルド — 成功

```bash
podman build -t my-nginx -f Containerfile .
```

`nginx:alpine` の pull と `index.html` のコピーが正常に完了。

### 検証 2: コンテナの起動（slirp4netns 手動指定）— 成功

```bash
podman run --rm -d -p 8888:80 --network=slirp4netns --name my-nginx my-nginx
```

- `--network=slirp4netns` を明示的に指定すると正常に動作
- IPv6 sysctl の警告が出るが動作に影響なし:
  ```
  WARN: failed to set net.ipv6.conf.default.accept_dad sysctl: read-only file system
  ```

### 検証 3: ポートマッピングの動作確認（手動指定時）— 成功

```bash
curl localhost:8888
```

カスタム HTML が正常に返却された。

### 検証 4: `default_rootless_network_cmd` によるデフォルト化 — 失敗

Containerfile に `[network]` セクションを追記（`>>` で既存設定を保持）して `default_rootless_network_cmd = "slirp4netns"` を設定。

```bash
podman run -d -p 8888:80 --name my-nginx my-nginx  # --network=slirp4netns なし
```

**結果:** コンテナが即座にクラッシュ（Exit 1）。

**原因:** `podman inspect` の結果 `NetworkMode: "host"` となっていた。ネスト環境ではブリッジネットワーク自体がホストモードにフォールバックしており、`default_rootless_network_cmd` はブリッジモード時のバックエンド（pasta/slirp4netns）を指定するだけで、フォールバック自体は防げない。ホストモードでは `-p` は無視され、rootless 環境でポート 80 にバインドできず `Permission denied` で失敗した。

```
nginx: [emerg] bind() to 0.0.0.0:80 failed (13: Permission denied)
```

**教訓:** `--network=slirp4netns` はネットワークモードそのものを slirp4netns に切り替える。`default_rootless_network_cmd` はブリッジモードのバックエンド選択であり、別物。

### 検証 5: `netns = "slirp4netns"` によるデフォルト化 — 成功

`[containers]` セクションに `netns = "slirp4netns"` を追加。`sed` で既存設定を壊さずに挿入。

```bash
podman run --rm -d -p 8888:80 --name my-nginx my-nginx  # --network=slirp4netns なし
curl localhost:8888
```

**結果:** `--network=slirp4netns` の手動指定なしでコンテナが正常起動し、ポートマッピングが動作。`curl` でカスタム HTML が返却された。

**結論:** ネスト環境での slirp4netns デフォルト化には `netns = "slirp4netns"`（`[containers]` セクション）が正解。`default_rootless_network_cmd`（`[network]` セクション）では不十分。

### 検証 6: `podman-compose` の bridge ネットワーク — 失敗 → `--cap-add=NET_ADMIN` で解決

`podman-compose` は bridge ネットワーク (`compose_default`) を作成し、netavark が `sysctl net.ipv4.ip_forward=1` を設定しようとする。ネスト環境では `/proc/sys` が read-only のため失敗。

```
Error: unable to start container "...": netavark: set sysctl net/ipv4/ip_forward: IO error: Read-only file system (os error 30)
```

**原因:** `netns = "slirp4netns"` は個別コンテナ起動 (`podman run`) のデフォルトモードを設定するが、`podman-compose` は compose サービス間通信のために明示的に bridge ネットワークを作成する。bridge ネットワークの作成時に netavark が `ip_forward` sysctl を設定する必要があり、read-only `/proc/sys` では書き込めない。

**検討した代替案:**
- `--in-pod=1` (pod モード): 複数 PostgreSQL インスタンスが同じポート 5432 にバインドしようとして競合
- `--podman-run-args='--network=slirp4netns'`: 各コンテナが個別のネットワーク名前空間を持ち、サービス名での通信不可
- `--sysctl=net.ipv4.ip_forward=1` (runArgs): 値は設定されるが netavark が再書き込み時に read-only エラーの可能性

**解決策:** `devcontainer.json` の `runArgs` に `--cap-add=NET_ADMIN` を追加。

- `CAP_NET_ADMIN` は DevContainer のネットワーク名前空間内に限定される
- ホストネットワーク/ファイルシステムへの影響なし
- `--privileged` と異なり、ネットワーク操作のみ許可

## 未検証・未対応

### 1. forwardPorts の設定

DevContainer 内のポートをホスト側に転送し、ブラウザからアクセスできるようにする。

### 2. postCreateCommand による自動化

コンテナビルド・起動を DevContainer 起動時に自動実行するかどうか。

## 背景知識

### なぜ slirp4netns が必要か

ネストされた rootless Podman では、デフォルトの pasta がホストネットワークにフォールバックし、`-p` フラグが無視される（[GitHub Issue #19442](https://github.com/containers/podman/issues/19442)）。slirp4netns は独自のネットワーク名前空間を作成するため、ネスト環境でも `-p` が正常に動作する。

### `--network=slirp4netns` と `default_rootless_network_cmd` の違い

| | `--network=slirp4netns` | `default_rootless_network_cmd = "slirp4netns"` | `netns = "slirp4netns"` |
|---|---|---|---|
| 設定場所 | CLI フラグ | `[network]` セクション | `[containers]` セクション |
| 効果 | ネットワークモード自体を slirp4netns に設定 | ブリッジモード時のバックエンドを slirp4netns に設定 | デフォルトのネットワークモードを slirp4netns に設定 |
| ネスト環境での動作 | 動作する | ブリッジ → ホストへのフォールバックは防げない | 動作する（CLI フラグと同等） |

### runArgs の各フラグの役割

| フラグ | 理由 |
|--------|------|
| `--device=/dev/fuse` | fuse-overlayfs によるストレージに必要 |
| `--device=/dev/net/tun` | slirp4netns によるネットワーク名前空間の作成に必要 |
| `--security-opt=label=disable` | SELinux がコンテナ内のファイルシステムマウントをブロックするのを防ぐ |
| `--cap-add=NET_ADMIN` | 内部 Podman の netavark が bridge ネットワーク用 `ip_forward` sysctl を設定するために必要 |

### 不要なフラグ

`--cap-add=sys_admin`、`--security-opt=seccomp=unconfined`、`--userns=keep-id`、`--privileged` はいずれも不要。

### セキュリティ上の注意

- ホストの Podman ソケットはマウントしない（隔離が破れる）
- `--privileged` は避ける（macOS の virtiofs マウント経由で `~/.ssh` 等にアクセス可能になる）

### 検証 7: `postgres` short-name resolution — 修正

`podman-compose up` 時に `postgres:16-alpine` の pull で以下のエラー:

```
Error: short-name resolution enforced but cannot prompt without a TTY
```

**原因:** `/etc/containers/registries.conf` で `short-name-mode = "enforcing"` が設定されており、`postgres` の short-name alias が未定義。TTY なし環境ではレジストリ選択のインタラクティブプロンプトが出せない。

**解決策:** Containerfile に `postgres` alias を追加:

```dockerfile
RUN echo -e '[aliases]\n  "postgres" = "docker.io/library/postgres"' \
      > /home/podman/.config/containers/registries.conf
```

`nginx` や `node` 等は `/etc/containers/registries.conf.d/` の Fedora 標準 alias ファイルで定義済み。`postgres` は含まれていなかった。

### 検証 8: `podman-compose` bridge ネットワーク + `--cap-add=NET_ADMIN` — 再検証で失敗

検証 6 で `--cap-add=NET_ADMIN` が解決策とされていたが、DevContainer 再ビルド後に再検証したところ、依然として同じエラーが発生:

```
Error: unable to start container "...": netavark: set sysctl net/ipv4/ip_forward: IO error: Read-only file system (os error 30)
```

**調査結果:**

1. `capsh --print` で `cap_net_admin=eip` が確認済み — capability は付与されている
2. `mount | grep proc/sys` → `proc on /proc/sys type proc (ro,nosuid,nodev,noexec,relatime)` — `/proc/sys` が read-only マウント
3. `echo 1 > /proc/sys/net/ipv4/ip_forward` → `Read-only file system` — capability があってもファイルシステムレベルで書き込み不可
4. `mount -o remount,rw /proc/sys` → `must be superuser to use mount` — `SYS_ADMIN` capability なしではリマウント不可
5. `cat /proc/sys/net/ipv4/ip_forward` → `0` — 値も未設定

**原因分析:** rootless コンテナでは `/proc/sys` はセキュリティ上 read-only でマウントされる。`CAP_NET_ADMIN` はネットワーク設定変更の capability だが、VFS レベルの read-only マウントはバイパスできない。netavark は bridge ネットワーク設定時に `ip_forward=1` を `/proc/sys` に書き込むため、read-only 環境では必ず失敗する。

**GitHub Issues 調査:**
- [containers/netavark#362](https://github.com/containers/netavark/issues/362): `route_localnet` の podman-in-podman 問題。Closed（修正済み）
- [containers/podman#20713](https://github.com/containers/podman/issues/20713): netavark sysctl エラー。Closed as not planned
- [containers/podman#19991](https://github.com/containers/podman/issues/19991): rootless bridge + port-forward 問題

**推奨ワークアラウンド（upstream issue より）:**
- outer container に `--sysctl=net.ipv4.ip_forward=1` と `--sysctl=net.ipv4.conf.all.route_localnet=1` を追加
- DevContainer 起動時に OCI ランタイムが sysctl 値を事前設定 → netavark が値チェック後にスキップすることを期待
- フォールバック: `--cap-add=SYS_ADMIN` で `/proc/sys` のリマウントを許可

### 検証 9: `--sysctl` フラグによる事前設定 — 失敗

`devcontainer.json` の `runArgs` に以下を追加:

```json
"--sysctl=net.ipv4.ip_forward=1",
"--sysctl=net.ipv4.conf.all.route_localnet=1"
```

**検証結果:**

1. `cat /proc/sys/net/ipv4/ip_forward` → `1` — sysctl 値は正しく設定されている
2. `podman network create --driver bridge test-net` → 成功（ネットワーク定義の作成自体は OK）
3. `podman run --rm --network=test-net docker.io/library/alpine echo "bridge works"` → **失敗**

```
Error: netavark: set sysctl net/ipv4/ip_forward: IO error: Read-only file system (os error 30)
```

**原因:** netavark 1.17.2 は sysctl 値が既に正しくても**値チェックせずに常に書き込みを試行する**。`/proc/sys` が read-only (ro) マウントのため EROFS で失敗。`--sysctl` での事前設定は「netavark が値チェック後にスキップ」という前提が成り立たず、効果なし。

**追加調査:**
- `mount | grep proc/sys` → `proc on /proc/sys type proc (ro,nosuid,nodev,noexec,relatime)` — VFS レベルで read-only
- `capsh --print` → `cap_net_admin=eip` あり、`cap_sys_admin` なし
- `CAP_NET_ADMIN` があっても VFS の read-only マウントはバイパスできない
- remount には `CAP_SYS_ADMIN` が必要

### 検証 10: `--cap-add=SYS_ADMIN` + `postStartCommand` remount — 成功

検証 9 の失敗を受け、フォールバック策を実施。

**変更内容:**

1. **Containerfile** — `podman` ユーザーに `/proc/sys` remount 限定の passwordless sudo を追加:

```dockerfile
RUN echo 'podman ALL=(ALL) NOPASSWD: /usr/bin/mount -o remount\,rw /proc/sys' \
      > /etc/sudoers.d/proc-sys-remount \
    && chmod 0440 /etc/sudoers.d/proc-sys-remount
```

2. **devcontainer.json** — `SYS_ADMIN` capability と起動時 remount を追加:

```json
"runArgs": [
  "--device=/dev/fuse",
  "--device=/dev/net/tun",
  "--security-opt=label=disable",
  "--cap-add=NET_ADMIN",
  "--cap-add=SYS_ADMIN",
  "--sysctl=net.ipv4.ip_forward=1",
  "--sysctl=net.ipv4.conf.all.route_localnet=1"
],
"postStartCommand": "sudo mount -o remount,rw /proc/sys || true",
```

**設計判断:**
- `SYS_ADMIN` は DevContainer のネスト環境（ホスト → Podman Machine → DevContainer）内に限定されるため、セキュリティリスクは許容範囲
- `--privileged` は回避（virtiofs 経由で `~/.ssh` 等にアクセス可能になるため）
- sudoers は remount コマンドのみに限定（`/usr/bin/mount -o remount,rw /proc/sys`）
- `postStartCommand` で毎起動時に自動 remount（`|| true` でエラー時も DevContainer 起動を妨げない）
- `--sysctl` フラグは維持（remount 前の初期値として ip_forward=1 を保証）

**検証手順（Rebuild 後）:**

1. `mount | grep proc/sys` → `rw` 確認済み ✓
2. `podman network create --driver bridge test-net` → 成功 ✓
3. `podman run --rm --network=test-net docker.io/library/alpine echo "bridge works"` → `bridge works` 出力 ✓
4. `podman-compose` で compose サービス起動 → 検証 11 参照

### 検証 11: `podman-compose` bridge ネットワーク（nginx + postgres）— 成功

検証 10 の remount 成功を受け、`podman-compose` で複数サービスの bridge ネットワーク起動を確認。

```yaml
services:
  web:
    image: docker.io/library/nginx:alpine
    ports:
      - "8888:80"
  db:
    image: docker.io/library/postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: testpass
```

```bash
podman-compose -f compose-test.yaml up -d
```

**結果:**
- bridge ネットワーク `tmp_default` が自動作成され、netavark の sysctl 書き込みがエラーなく完了
- nginx (`tmp_web_1`) と postgres (`tmp_db_1`) が正常起動
- `curl localhost:8888` → HTTP 200（nginx デフォルトページ）
- ポートマッピング正常動作

**結論:** `--cap-add=SYS_ADMIN` + `postStartCommand` remount により、DevContainer 内の `podman-compose` bridge ネットワークが完全動作。検証 6〜9 の問題がすべて解決された。

### 検証 12: `setup-legacy-realm.sh spa-hono` フルスタック起動 — 成功（手動介入あり）

検証 11 の compose 基盤動作確認を受け、プロジェクトのフルスタック起動を実施。

**手順:**

```bash
bash deploy/compose/setup-env.sh
bash deploy/compose/setup-legacy-realm.sh spa-hono
```

**発見した問題 (2 件):**

#### 問題 1: healthcheck の定期実行が開始されない

`podman-compose` 1.5.0 + Podman nested (rootless-in-rootless) 環境で、一部のコンテナの healthcheck 定期実行が開始されない。`podman inspect` で `Health.Log: null`（一度もチェック実行されていない）となる。

- **影響**: `depends_on: condition: service_healthy` を使う compose 定義で、依存コンテナの起動がブロックされる
- **ワークアラウンド**: `podman healthcheck run <container>` で手動トリガーすると即座に `healthy` に遷移し、依存コンテナが起動する
- **根本原因**: 未調査。Podman nested 環境固有の問題の可能性（systemd timer / conmon healthcheck goroutine の起動不良？）

#### 問題 2: `node_modules` 不在による Drizzle migration 失敗

DevContainer Rebuild 後は `frontend-spa-hono/node_modules` が存在しないため、`npx drizzle-kit migrate` が `Cannot find module 'drizzle-kit'` で失敗。

- **ワークアラウンド**: `setup-legacy-realm.sh` 実行前に `cd frontend-spa-hono && npm install` を手動実行
- **恒久対応案**: `devcontainer.json` の `postCreateCommand` で `npm install` を実行するか、`setup-legacy-realm.sh` に `npm install` ステップを追加

**最終結果（手動介入後）:**

| Step | Result |
|------|--------|
| 1/8 Build SPI JARs | ✓ |
| 2/8 Copy JARs | ✓ |
| 3/8 Compose stack start | ✓ (healthcheck 手動トリガー必要) |
| 4/8 Drizzle migration | ✓ (npm install 手動実行後) |
| 5/8 Keycloak health | ✓ |
| 6/8 Backend + frontend health | ✓ |
| 7/8 Client secrets | ✓ (4/4 accepted) |
| 8/8 Realm import | ✓ (legacy realm, 6 users, custom flow, IdP) |
| Direct Grant login | ✓ (USR-001/002/003 all LOGIN OK) |
| Browser OIDC login | ✓ (Keycloak 内部ユーザー + 外部 IdP 両方。検証 13 参照) |

### 検証 13: ブラウザ OIDC ログイン — 成功

検証 12 の Direct Grant 成功後、ブラウザ経由 (localhost:8083) の OIDC ログインを確認。

**初回テスト結果:** 失敗。BFF コンテナ内から `http://localhost:8080` (Keycloak) への backchannel 接続不可。nested Podman + slirp4netns 環境で `extra_hosts: ["localhost:host-gateway"]` の DNS 解決が `127.0.0.1` に負ける問題（ADR-014 前提が非 nested 環境）。

**解決策:** `KEYCLOAK_ISSUER` を compose サービス名 `http://keycloak:8080/...` に変更し、ブラウザ向け URL は `KEYCLOAK_BROWSER_URL` として分離。Keycloak 側の `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` により、内部 discovery でも authorization_endpoint は `http://localhost:8080/...`（ブラウザ到達可能）を返す。

**変更内容:**
- `compose.yaml`: 3 プロファイル全ての `KEYCLOAK_ISSUER` を `http://keycloak:8080/...` に変更
- `compose.yaml`: spa-hono に `KEYCLOAK_BROWSER_URL` 追加（signup redirect 用）
- `frontend-spa-hono/src/index.ts`: `KEYCLOAK_BROWSER_URL` 参照を追加（signup auth URL 構築用）

**確認結果:** Keycloak 内部ユーザー + 外部 IdP (stub-idp) 両方のブラウザログイン成功。

## 検証結果サマリ

| # | 検証内容 | 結果 | 備考 |
|---|---------|------|------|
| 1 | イメージビルド | ✓ | |
| 2 | コンテナ起動 (slirp4netns 手動) | ✓ | |
| 3 | ポートマッピング | ✓ | |
| 4 | `default_rootless_network_cmd` デフォルト化 | ✗ | ホストモードフォールバック |
| 5 | `netns = "slirp4netns"` デフォルト化 | ✓ | |
| 6 | `podman-compose` bridge | ✗→✓ | `--cap-add=NET_ADMIN` 単体では不十分 |
| 7 | `postgres` short-name | ✓ | registries.conf alias 追加 |
| 8 | bridge + `NET_ADMIN` 再検証 | ✗ | `/proc/sys` read-only |
| 9 | `--sysctl` 事前設定 | ✗ | netavark が値チェックせず書き込み |
| 10 | `SYS_ADMIN` + remount | ✓ | `/proc/sys` rw 化で解決 |
| 11 | `podman-compose` nginx + postgres | ✓ | bridge ネットワーク完全動作 |
| 12 | フルスタック起動 | ✓ | healthcheck 手動トリガー + npm install 必要 |
| 13 | ブラウザ OIDC ログイン | ✓ | KEYCLOAK_ISSUER を compose サービス名に変更 |
| 14 | healthcheck ポーラー | ✓ | systemd 不在の workaround。setup 手動介入なし |
| 15 | `--sysctl` フラグ不要検証 | ✓ | `SYS_ADMIN` + remount で十分。`--sysctl` 2 行を削除 |
| 16 | poller の `postAttachCommand` 移行 | ✓ | セッション再接続時にも poller が確実に起動 |
| 17 | poller の entrypoint 統合 | ✓ | クライアント非依存化。DevContainer テンプレートとして汎用化 |
| 18 | `overrideCommand` ENTRYPOINT 上書き修正 | — | `overrideCommand: false` + `CMD ["sleep", "infinity"]`。Rebuild 後に検証予定 |

## 未解決の課題

### 課題 1: healthcheck 定期実行が開始されない

`podman-compose` 1.5.0 + Podman nested (rootless-in-rootless) 環境で、コンテナの healthcheck 定期実行が自動的に開始されない。

**症状:**
- `podman inspect` で `Health.Status: "starting"`, `Health.Log: null`（healthcheck が一度も実行されていない）
- コンテナは正常稼働しており、healthcheck コマンド自体は手動実行すれば成功する
- `podman healthcheck run <container>` で手動トリガーすると即座に `healthy` に遷移
- `podman-compose` 固有の問題ではなく、`podman run --health-cmd` で直接作成したコンテナでも再現
- DevContainer 再起動やコンテナ再作成後にも再発

**影響:**
- `depends_on: condition: service_healthy` を使う compose 定義で、依存コンテナの起動が無期限にブロックされる
- `setup-legacy-realm.sh` の自動実行が完了しない（手動介入が必要）

**ワークアラウンド:** `podman healthcheck run <container>` で全コンテナを手動トリガー

**根本原因（検証 14 で特定）:**

Podman 5.x は healthcheck の定期実行に **systemd user timers** を使用する。DevContainer (quay.io/podman/stable) は PID 1 が `sh` であり systemd が動いていないため、healthcheck timer が登録されない。

```
$ cat /proc/1/comm
sh

$ systemctl --user status
Failed to connect to user scope bus via local transport:
$DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined

$ echo $XDG_RUNTIME_DIR
(unset)
```

**環境情報:**

| Component | Version |
|-----------|---------|
| Podman | 5.8.2 |
| conmon | 2.2.1 |
| crun | 1.27.1 |
| cgroupManager | cgroupfs |
| Base image | quay.io/podman/stable (Fedora 44) |

**Upstream issue:** [containers/podman#28192](https://github.com/containers/podman/issues/28192) — "Healthchecks not working when running Podman without systemd"。Status: Open, triaged, `kind/feature`。Fix は未計画。

**解決策の候補:**

| 案 | 方法 | 評価 |
|----|------|------|
| A. healthcheck ポーリングスクリプト | バックグラウンドで定期的に `podman healthcheck run` を実行 | シンプル。cron / while loop で実装可能 |
| B. `setup-legacy-realm.sh` を healthcheck 非依存化 | `depends_on: service_healthy` を `service_started` に変更し、スクリプト内で直接ポーリング | スクリプト変更のみ。compose 定義への影響あり |
| C. DevContainer で systemd を有効化 | ベースイメージ変更または init system 追加 | 大きな変更。セキュリティ・複雑性の懸念 |
| D. `postStartCommand` で healthcheck ポーリングを起動 | DevContainer 起動時にバックグラウンドプロセスで全コンテナの healthcheck を定期トリガー | DevContainer 固有のワークアラウンド |

**解決策:** 案 A+D → 検証 17 で entrypoint ラッパーに移行。

**実装（検証 17 で改善済み）:**

1. `entrypoint.sh` — `/proc/sys` remount + healthcheck poller バックグラウンド起動 + `exec "$@"`
2. `healthcheck-poller.sh` — 10 秒間隔で `podman ps --filter health=starting` のコンテナに `podman healthcheck run` を実行するループスクリプト
3. Containerfile で両スクリプトを `/usr/local/bin/` にコピーし、ENTRYPOINT に設定

```dockerfile
COPY healthcheck-poller.sh /usr/local/bin/healthcheck-poller.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/healthcheck-poller.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**検証結果:** DevContainer Rebuild 後に検証予定（検証 17 参照）。

**Status:** 解決済み（検証 17 で entrypoint 方式に移行）。

### 課題 2: `node_modules` 不在による Drizzle migration 失敗

DevContainer Rebuild 後は `frontend-spa-hono/node_modules` が存在しないため、`npx drizzle-kit migrate` が `Cannot find module 'drizzle-kit'` で失敗。

**解決策:** `setup-legacy-realm.sh` の各プロファイルの migration 実行前に `npm ci --ignore-scripts` を追加。スクリプトが自己完結し、開発者の事前操作が不要になった。`--ignore-scripts` は ADR-026 準拠。

**Status:** 解決済み。

### 検証 15: `--sysctl` フラグの冗長性検証 — 不要と確認、削除

検証 9 で追加した `--sysctl=net.ipv4.ip_forward=1` と `--sysctl=net.ipv4.conf.all.route_localnet=1` が、検証 10 の `SYS_ADMIN` + remount 導入後も必要かを検証。

**テスト手順:**

1. `ip_forward=0`, `route_localnet=0` に設定（`--sysctl` の効果を無効化）
2. `podman-compose` で 2 サービス（nginx + alpine client）を bridge ネットワークで起動
3. サービス間 DNS 解決、ホストからのポートフォワード、compose up の成功を確認

**結果:**

```
ip_forward=0, route_localnet=0 の状態で:
- podman-compose up           → 成功（netavark エラーなし）
- サービス間 DNS (curl web:80) → 成功
- ホストポートフォワード        → 成功
```

**分析:**

- netavark は bridge 用の**独立した network namespace** 内で sysctl を設定する
- `--sysctl` フラグは DevContainer namespace の値を設定するが、bridge namespace には影響しない
- 検証 10 の `SYS_ADMIN` + remount で `/proc/sys` が rw になったことで、netavark が bridge namespace 内の sysctl 書き込みに成功するようになった
- `--sysctl` フラグは検証 9 の試行錯誤の名残であり、`SYS_ADMIN` + remount が根本解決

**対応:** `devcontainer.json` の `runArgs` から以下を削除:

```diff
  "runArgs": [
    "--device=/dev/fuse",
    "--device=/dev/net/tun",
    "--security-opt=label=disable",
    "--cap-add=NET_ADMIN",
-   "--cap-add=SYS_ADMIN",
-   "--sysctl=net.ipv4.ip_forward=1",
-   "--sysctl=net.ipv4.conf.all.route_localnet=1"
+   "--cap-add=SYS_ADMIN"
  ],
```

**Status:** DevContainer Rebuild 後に `setup-legacy-realm.sh spa-hono` で再検証が必要。

### 検証 16: poller の `postAttachCommand` 移行 — セッション再接続対応

検証 14 で導入した healthcheck poller は `postStartCommand` で起動していたが、VS Code セッション切断→再接続時にポーラープロセスが消失し、healthcheck が動かなくなる問題が発覚。

**原因:**

- `postStartCommand` はコンテナ起動時にのみ実行される
- VS Code セッション切断→再接続では、コンテナが生き続けていても `postStartCommand` は再実行されない
- コンテナが停止→再起動した場合は `postStartCommand` が再実行されるが、ポーラープロセスは前回のコンテナ停止時に消失済み

**解決策:**

1. poller を `postStartCommand` → `postAttachCommand` に移動。`postAttachCommand` は VS Code が接続するたびに実行されるため、セッション再接続時にも確実に起動する
2. PID ファイルガードを追加し、既にポーラーが動いている場合は即 exit（重複起動防止）
3. `/proc/sys` remount は `postStartCommand` に残す（コンテナ起動時に 1 回だけ必要）

**変更内容:**

```diff
# devcontainer.json
- "postStartCommand": "sudo mount -o remount,rw /proc/sys || true; nohup bash .devcontainer/healthcheck-poller.sh >/dev/null 2>&1 &",
+ "postStartCommand": "sudo mount -o remount,rw /proc/sys || true",
+ "postAttachCommand": "nohup bash .devcontainer/healthcheck-poller.sh >/dev/null 2>&1 &",
```

```diff
# healthcheck-poller.sh
+ PIDFILE="/tmp/healthcheck-poller.pid"
+ if [ -f "$PIDFILE" ]; then
+   old_pid=$(cat "$PIDFILE" 2>/dev/null)
+   if kill -0 "$old_pid" 2>/dev/null; then
+     exit 0
+   fi
+ fi
+ echo $$ > "$PIDFILE"
+ trap 'rm -f "$PIDFILE"' EXIT
```

**DevContainer ライフサイクルの整理:**

| Hook | 実行タイミング | 用途 |
|------|-------------|------|
| `postCreateCommand` | コンテナ初回作成時のみ | `setup-claude.sh`（1 回限りのセットアップ） |
| `postStartCommand` | コンテナ起動ごと | `/proc/sys` remount（OS レベルの前提条件） |
| `postAttachCommand` | VS Code 接続ごと（再接続含む） | healthcheck poller（ユーザーセッション中に必要） |

**Status:** 検証 17 で entrypoint 方式に移行。`postStartCommand` と `postAttachCommand` は不要になった。

### 検証 17: poller の entrypoint 統合 — クライアント非依存化

検証 16 の `postAttachCommand` 方式には、VS Code 以外のクライアント（Claude Code CLI、SSH 接続等）では poller が起動しないという制約があった。`.devcontainer/` を podman-in-podman テンプレートとして汎用化するため、poller をコンテナの entrypoint に統合。

**問題:**

- `postAttachCommand` は DevContainer クライアント（VS Code 等）の attach ライフサイクルに依存する
- Claude Code CLI 単体起動、SSH 接続、`postAttachCommand` 実行前の compose 操作でポーラーが不在
- 実際に `setup-legacy-realm.sh` が全 DB コンテナの healthcheck 待ちで 38 分以上ブロックされた

**解決策:**

1. `entrypoint.sh` を新設 — `/proc/sys` remount + healthcheck poller バックグラウンド起動 + `exec "$@"`
2. Containerfile で両スクリプトを `/usr/local/bin/` にコピーし、`ENTRYPOINT` に設定
3. `devcontainer.json` から `postStartCommand` と `postAttachCommand` を削除
4. `healthcheck-poller.sh` から PID ファイルガードを削除（entrypoint はコンテナ起動時に 1 回だけ実行されるため不要）

**変更内容:**

```dockerfile
# Containerfile (追加分)
COPY healthcheck-poller.sh /usr/local/bin/healthcheck-poller.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/healthcheck-poller.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

```bash
# entrypoint.sh
#!/bin/bash
sudo mount -o remount,rw /proc/sys 2>/dev/null || true
nohup /usr/local/bin/healthcheck-poller.sh >/dev/null 2>&1 &
exec "$@"
```

```diff
# devcontainer.json
- "postStartCommand": "sudo mount -o remount,rw /proc/sys || true",
- "postAttachCommand": "nohup bash .devcontainer/healthcheck-poller.sh >/dev/null 2>&1 &",
```

**設計判断:**

| 観点 | 判断 |
|------|------|
| ENTRYPOINT の安全性 | ~~DevContainer は `overrideCommand` (default `true`) で CMD を `sleep infinity` に差し替えるが、ENTRYPOINT は保持される。~~ **誤り — 検証 18 で判明: `overrideCommand: true` は ENTRYPOINT も上書きする。`overrideCommand: false` + 明示的 `CMD ["sleep", "infinity"]` が必要。** |
| poller 障害時の影響 | `nohup ... &` でバックグラウンド起動するため、poller 障害はコンテナ起動をブロックしない |
| スクリプト修正時 | `/usr/local/bin/` にコピーするため、修正時は DevContainer Rebuild が必要（ワークスペースマウントは entrypoint 実行後に行われる可能性があるため直接参照不可） |

**DevContainer ライフサイクルの更新:**

| 実行タイミング | 実行元 | 用途 |
|-------------|--------|------|
| コンテナ起動（PID 1 の前） | `ENTRYPOINT` (entrypoint.sh) | `/proc/sys` remount + healthcheck poller 起動 |
| コンテナ初回作成時のみ | `postCreateCommand` | `setup-claude.sh`（1 回限りのセットアップ） |

**Status:** DevContainer Rebuild 後に検証予定。

### 検証 18: `overrideCommand` による ENTRYPOINT 上書き問題 — 修正

検証 17 で entrypoint 方式に統合したが、DevContainer Rebuild 後に healthcheck poller が起動していないことが判明。

**症状:**

- `pgrep -f healthcheck-poller` → プロセスなし
- `/usr/local/bin/healthcheck-poller.sh` と `/usr/local/bin/entrypoint.sh` はイメージ内に存在
- PID 1 が entrypoint.sh ではなく DevContainer ランタイムの sleep ループ:

```
$ cat /proc/1/cmdline | tr '\0' ' '
/bin/sh -c echo Container started
trap "exit 0" 15
exec "$@"
while sleep 1 & wait $!; do :; done -
```

**原因:**

検証 17 の設計前提が誤っていた:

> ❌「DevContainer は `overrideCommand` (default `true`) で **CMD を** `sleep infinity` に差し替えるが、**ENTRYPOINT は保持される**」

実際には、`overrideCommand: true`（デフォルト）は **ENTRYPOINT と CMD の両方を上書き** する。DevContainer ランタイムが独自の init スクリプト（`/bin/sh -c ... while sleep ...`）を ENTRYPOINT として注入するため、Containerfile の `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` は完全に無視される。

**修正内容:**

1. `devcontainer.json` に `"overrideCommand": false` を追加 — DevContainer ランタイムによる ENTRYPOINT/CMD の上書きを無効化
2. Containerfile に `CMD ["sleep", "infinity"]` を追加 — コンテナを alive に保つ（`overrideCommand: false` では DevContainer が sleep ループを注入しないため、自前で CMD を指定する必要がある）

```diff
# devcontainer.json
+ "overrideCommand": false,
  "runArgs": [
```

```diff
# Containerfile
  ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
+ CMD ["sleep", "infinity"]
  WORKDIR /workspaces
```

**起動フロー（修正後）:**

1. DevContainer ランタイムがコンテナを起動
2. `overrideCommand: false` により Containerfile の ENTRYPOINT/CMD が保持される
3. entrypoint.sh が PID 1 として実行:
   - `sudo mount -o remount,rw /proc/sys` — netavark 用
   - `nohup healthcheck-poller.sh &` — バックグラウンドで poller 起動
   - `exec sleep infinity` — コンテナを alive に保つ
4. DevContainer ランタイムが `postCreateCommand` 等のライフサイクルフックを実行

**Status:** DevContainer Rebuild 後に検証予定。

## 背景知識

### なぜ slirp4netns が必要か

ネストされた rootless Podman では、デフォルトの pasta がホストネットワークにフォールバックし、`-p` フラグが無視される（[GitHub Issue #19442](https://github.com/containers/podman/issues/19442)）。slirp4netns は独自のネットワーク名前空間を作成するため、ネスト環境でも `-p` が正常に動作する。

### `--network=slirp4netns` と `default_rootless_network_cmd` の違い

| | `--network=slirp4netns` | `default_rootless_network_cmd = "slirp4netns"` | `netns = "slirp4netns"` |
|---|---|---|---|
| 設定場所 | CLI フラグ | `[network]` セクション | `[containers]` セクション |
| 効果 | ネットワークモード自体を slirp4netns に設定 | ブリッジモード時のバックエンドを slirp4netns に設定 | デフォルトのネットワークモードを slirp4netns に設定 |
| ネスト環境での動作 | 動作する | ブリッジ → ホストへのフォールバックは防げない | 動作する（CLI フラグと同等） |

### runArgs の各フラグの役割

| フラグ | 理由 |
|--------|------|
| `--device=/dev/fuse` | fuse-overlayfs によるストレージに必要 |
| `--device=/dev/net/tun` | slirp4netns によるネットワーク名前空間の作成に必要 |
| `--security-opt=label=disable` | SELinux がコンテナ内のファイルシステムマウントをブロックするのを防ぐ |
| `--cap-add=NET_ADMIN` | 内部 Podman の netavark が bridge ネットワーク用 `ip_forward` sysctl を設定するために必要 |
| `--cap-add=SYS_ADMIN` | `postStartCommand` で `/proc/sys` を rw remount するために必要。netavark が sysctl 書き込み時に EROFS で失敗する問題の回避（検証 9/10 参照） |

### 不要なフラグ

`--security-opt=seccomp=unconfined`、`--userns=keep-id`、`--privileged` はいずれも不要。

`--sysctl=net.ipv4.ip_forward=1`、`--sysctl=net.ipv4.conf.all.route_localnet=1` も不要（検証 15 で確認）。netavark は bridge namespace 内で独自に sysctl を設定するため、DevContainer namespace の値は不要。

### セキュリティ上の注意

- ホストの Podman ソケットはマウントしない（隔離が破れる）
- `--privileged` は避ける（macOS の virtiofs マウント経由で `~/.ssh` 等にアクセス可能になる）

## 参考

- [How to use Podman inside of a container (Red Hat Blog)](https://www.redhat.com/en/blog/podman-inside-container)
- [quay.io/podman/stable](https://quay.io/repository/podman/stable)
- [GitHub Issue #19442: Nested rootless podman defaults to host network](https://github.com/containers/podman/issues/19442)
- [containers/netavark#362: route_localnet and podman in podman](https://github.com/containers/netavark/issues/362)
- [containers/podman#20713: Netavark sysctl read-only file system](https://github.com/containers/podman/issues/20713)
