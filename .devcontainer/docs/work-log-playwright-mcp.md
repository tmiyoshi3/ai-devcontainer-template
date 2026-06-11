# Work Log

## DevContainer で Playwright MCP を使えるようにする（2026-06-08 検証済み）

DevContainer 内で Claude Code の Playwright MCP を動作させるためのセットアップ記録。
別セッションでホスト側から DevContainer 設定を修正する際の参考資料。

---

### 結論: 正しい構成

**使うべきパッケージ**: `@playwright/mcp`（Microsoft 公式）
- `@executeautomation/playwright-mcp-server` はサードパーティ製。今回誤って使っていた
- 公式パッケージは自身の Playwright でブラウザを管理するため、バージョン不一致が起きない

**動作確認済みの `.mcp.json`**:
```json
{
  "mcpServers": {
    "playwright": {
      "command": "/usr/local/bin/npx",
      "args": ["@playwright/mcp@latest", "--headless", "--browser", "chromium"]
    }
  }
}
```

**必須オプション**:
- `--headless`: DevContainer 内にディスプレイがないため必須
- `--browser chromium`: デフォルトは `chrome`（Chrome for Testing）を探しに行くが、DevContainer には入っていない。Playwright 同梱の `chromium` を使う

---

### Containerfile の修正方針

現在の Containerfile には以下の問題がある。

#### 修正点 1: グローバルインストールするパッケージ

```dockerfile
# 現在（正しい — このまま維持）
RUN npm install -g @playwright/mcp@latest
```

これは正しい。変更不要。

#### 修正点 2: ブラウザインストール

```dockerfile
# 現在
RUN npx playwright install chromium

# 修正後（@playwright/mcp 同梱の playwright を使ってインストール）
RUN npx @playwright/mcp@latest install-browser chromium
```

`npx playwright install chromium` だとローカルの `playwright` パッケージ（別バージョン）が使われる可能性がある。`@playwright/mcp` には `install-browser` サブコマンドがあり、自身の Playwright バージョンでブラウザをインストールできる（cli.js のコード `process.argv.includes('install-browser')` で確認済み）。

もし `install-browser` が動かない場合の代替:
```dockerfile
# @playwright/mcp が依存する playwright のバージョンでインストール
RUN PLAYWRIGHT_VERSION=$(node -e "console.log(require('/usr/local/lib/node_modules/@playwright/mcp/node_modules/playwright-core/package.json').version)") && \
    npx -y playwright@${PLAYWRIGHT_VERSION} install chromium
```

#### 修正点 3: `.mcp.json` の生成

```dockerfile
# 現在
RUN echo '{"mcpServers":{"playwright":{"command":"npx","args":["-y","@playwright/mcp@latest"]}}}' \
    > /home/podman/.mcp.json

# 修正後
RUN echo '{"mcpServers":{"playwright":{"command":"/usr/local/bin/npx","args":["@playwright/mcp@latest","--headless","--browser","chromium"]}}}' \
    > /home/podman/.mcp.json
```

変更点:
- `npx` → `/usr/local/bin/npx`（絶対パス。Claude Code の MCP 起動時に PATH が通らないことがある）
- `--headless` 追加（ディスプレイなし環境）
- `--browser chromium` 追加（デフォルトの chrome は未インストール）
- `-y` 削除（グローバルインストール済みなので不要）

#### 変更不要: OS 依存パッケージ

Chromium 向けの dnf install は現状のままでOK:
```
nspr nss nss-util atk at-spi2-atk cups-libs libdrm mesa-libgbm
libxkbcommon alsa-lib pango libXcomposite libXdamage libXrandr
libXtst libXScrnSaver gtk3
```

#### 変更不要: package.json の playwright

プロジェクトの `package.json` に `playwright@1.60.0` があるが、これは MCP とは無関係。MCP サーバーはグローバルインストールされた `@playwright/mcp` の中の playwright-core を使う。混同しないこと。

---

### 過去のトラブルと解決策（参考）

| 問題 | 原因 | 対処 |
|---|---|---|
| MCP サーバー接続 ENOENT | `npx` が相対パスで PATH 解決できない | `/usr/local/bin/npx` と絶対パス指定 |
| MCP スコープ競合 | `~/.claude.json` と `.mcp.json` に別パッケージが登録 | `claude mcp remove playwright -s local` で片方削除 |
| ブラウザバイナリ not found | MCP サーバーの Playwright バージョンとインストール済みブラウザのビルド番号不一致 | 公式パッケージなら `install-browser` で解決。サードパーティ製だとバージョン手動合わせが必要だった |
| headed モードで起動不可 | DevContainer にディスプレイなし | `--headless` オプション |
| `chrome` not found | `@playwright/mcp` のデフォルトブラウザは chrome | `--browser chromium` で Playwright 同梱 chromium を使用 |
| `--with-deps` 失敗 | sudo が必要 | Containerfile で `USER root` の段階で OS パッケージを dnf install。ブラウザバイナリは `USER podman` で |

---

### 検証方法

DevContainer 再ビルド後、コンテナ内で以下を確認:

1. `npx @playwright/mcp@latest --headless --browser chromium` が stdio で起動するか
2. Claude Code から Playwright MCP ツール（`browser_navigate`, `browser_take_screenshot` 等）が使えるか
3. `http://localhost:8888` のスクリーンショットが取得できるか
