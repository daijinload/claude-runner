# claude-runner

タスク単位で `claude -p` を別プロセス起動する Bash ランナー。長セッションで `compact` が走るとコンテキストにノイズが乗って精度が落ちる問題を、毎タスクをまっさら状態で実行することで回避する。

- タスク分割 + `<!-- depends: -->` での依存解決
- Wave 方式の並列実行（`xargs -P`）
- 試行ごとログ保存（claude の stream-json を `jq` で整形）
- 進捗ストリームをターミナルにリアルタイム出力（既定オン）
- `reset` で done を todo に巻き戻して何度でもやり直し

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照。

## 前提

- bash 3.2 以上（macOS 標準でも動く）
- [`claude`](https://docs.anthropic.com/claude/docs/claude-code) CLI が PATH にある
- `jq` 推奨（無くてもログが raw JSONL になるだけで動く）

## インストール

```bash
# どこかにクローン
git clone <repo-url> claude-runner
cd claude-runner

# PATH の通った場所に置く
install -m 0755 claude-runner.sh ~/.local/bin/
# または
cp claude-runner.sh ~/src/scripts/ && chmod +x ~/src/scripts/claude-runner.sh
```

## クイックスタート

```bash
cd ~/myproject

# 対話 claude で壁打ち。DESIGN.md とタスクファイルを保存
claude-runner.sh plan some-feature

# 状況確認
claude-runner.sh show

# 依存解決して並列実行（進捗が [NNN-slug] プレフィックス付きで stdout に流れる）
claude-runner.sh run-all

# git reset 後など、同じタスクをもう一度走らせたいとき
claude-runner.sh reset && claude-runner.sh run-all
```

## サブコマンド

| コマンド | 動作 |
|---|---|
| `plan [name]` | 対話 claude を起動して壁打ち。DESIGN.md とタスクファイルを workdir に保存。`name` は workdir 識別子（任意） |
| `add "<task>"` | タスクファイルを 1 件追加 |
| `next` | ready な先頭 1 件を実行 |
| `run-all` | ready なタスクを並列実行（`JOBS=並列度`、既定 4） |
| `show` | DESIGN.md / todo (ready/blocked) / done / logs (最新 20) を表示 |
| `reset` | done を全部 todo に戻す（`## Result` 以降を切り落とす）+ ログ削除。DESIGN.md は維持 |

## 環境変数

| 変数 | 用途 |
|---|---|
| `MODEL` | claude モデル上書き（例: `sonnet`, `haiku`） |
| `EFFORT` | effort 上書き（`low`/`medium`/`high`/`xhigh`/`max`） |
| `JOBS` | 並列度（既定 4） |
| `STREAM` | 既定 `1`: 整形済み claude 出力を `[NNN-slug]` プレフィックス付きで親 stdout に流す。`0` で抑制 |
| `WORKDIR` | workdir 直接指定（symlink バイパス） |
| `LINK_DIR` | symlink 配置先（既定 `~/src/scripts/link`） |
| `CLAUDE_BIN` | claude バイナリパス（既定 `claude`） |

未指定なら claude が `~/.claude/settings.json` の既定値を使う（ユーザ環境依存）。

## ファイル配置

実行時に生成されるもの:

```
/tmp/runner-<ts>[-<slug>]/   # workdir（プロジェクト外に隔離）
├── DESIGN.md                # 不変方針
├── tasks/
│   ├── todo/NNN-*.md        # 未実行
│   └── done/NNN-*.md        # 完了（末尾に ## Result）
├── logs/NNN-slug-<ts>.log   # タスク実行ログ（試行ごと新規）
└── .project                 # プロジェクトの絶対パス

~/src/scripts/link/<sanitized-cwd> → workdir   # cwd ベース symlink
```

`<sanitized-cwd>` は cwd の `/` を `_` に置換したもの（例: `/Users/foo/proj/bar` → `Users_foo_proj_bar`）。cwd ごとに異なるので複数プロジェクト併用で衝突しない。

## ライセンス

MIT — [LICENSE](./LICENSE) 参照
