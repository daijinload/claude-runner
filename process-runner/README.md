# claude-runner

タスク単位で `claude -p` を別プロセス起動する Bash ランナー。長セッションで `compact` が走るとコンテキストにノイズが乗って精度が落ちる問題を、毎タスクをまっさら状態で実行することで回避する。

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照。

## 前提

- bash 3.2 以上（macOS 標準でも動く）
- [`claude`](https://docs.anthropic.com/claude/docs/claude-code) CLI が PATH にある
- `jq` 推奨（無くてもログが raw JSONL になるだけで動く）
- /tmpとかシンボリックリンクとか macos or linux向けなのでwindowsだとそのままでは動かない
  - 所詮スクリプト一本なのでAIにwindows版を作ってもらうか windows on linuxや仮想環境推奨っす

## インストール

シェルスクリプト単体で動くのでどこかに置いて実行権限をつけてください。

```bash
# どこかにクローン
git clone <repo-url> claude-runner
cd claude-runner

# PATH の通った場所に置く
install -m 0755 process-runner.sh ~/.local/bin/
# または
cp process-runner.sh ~/src/scripts/ && chmod +x ~/src/scripts/process-runner.sh
```

## クイックスタート

```bash
cd ~/myproject

# 最初に対話モードでclaudeを立ち上げて仕様を策定。会話が決着すると DESIGN.md と タスクファイルが出来上がる。
# 出来るだけ分割したり並列作業できるように仕様と分割を吟味してださい。
# hogeの部分はフォルダが見やすいようにするための識別子で何を指定しても良い。
process-runner.sh plan hoge

# 出来上がったファイルなどの確認
process-runner.sh show

# タスクを依存順に実行（進捗が [NNN-slug] プレフィックス付きで stdout に流れる）
# 途中で落ちてもタスクの状態を見て引き継いで実行される
process-runner.sh run-all

# 一旦リセットして最初からやりたい場合に下記を実行する
process-runner.sh reset && process-runner.sh run-all
```

## サブコマンド

| コマンド | 動作 |
|---|---|
| `plan [name]` | 対話 claude を起動して壁打ち。DESIGN.md とタスクファイルを workdir に保存。対話を抜けた後、`REVIEW_SPEC` の md ファイルが存在し todo に実装タスクが 1 件以上あれば、その H2 セクション数ぶんの read-only レビュータスクを自動で todo に追加する。`name` は workdir 識別子（任意） |
| `add "<task>"` | タスクファイルを 1 件追加 |
| `next` | ready な先頭 1 件を実行 |
| `run-all` | ready なタスクを並列実行（`JOBS=並列度`、既定 20） |
| `show` | DESIGN.md / todo (ready/blocked) / done / logs (最新 20) を表示 |
| `reset` | done を全部 todo に戻す（`## Result` 以降を切り落とす）+ ログ削除。DESIGN.md は維持 |

## 環境変数

| 変数 | 用途 |
|---|---|
| `MODEL` | claude モデル上書き（例: `sonnet`, `haiku`） |
| `EFFORT` | effort 上書き（`low`/`medium`/`high`/`xhigh`/`max`） |
| `JOBS` | 並列度（既定 20） |
| `STREAM` | 既定 `1`: 整形済み claude 出力を `[NNN-slug]` プレフィックス付きで親 stdout に流す。`0` で抑制 |
| `WORKDIR` | workdir 直接指定（symlink バイパス） |
| `LINK_DIR` | symlink 配置先（既定 `~/src/scripts/link`） |
| `CLAUDE_BIN` | claude バイナリパス（既定 `claude`） |
| `REVIEW_SPEC` | `plan` 後に読むレビュー観点ファイル（既定: スクリプトと同じディレクトリの `process-runner-review.md`） |

未指定なら claude が `~/.claude/settings.json` の既定値を使う（ユーザ環境依存）。

## レビュー観点ファイル

`plan` の対話を抜けた後、`REVIEW_SPEC` の md ファイルを読み込み、その H2 (`## XXX`) セクション数ぶんの **read-only レビュータスク** を自動で todo に追加する。`run-all` で実装タスクが全部完了した後、各レビュータスクが並列で走り、結果を `<workdir>/reviews/review-<セクション名>.md` に書き出す（symlink `$LINK_DIR/<sanitized-cwd>/reviews/` 経由でアクセス可）。

仕様:
- `# H1` セクション = 全レビュータスク共通の前文として注入
- `## H2` セクション = 1 セクション = 1 並列レビュータスク
- `###` 以降は共通ルール内のサブ見出しとして使う
- 各レビュータスクは `depends` に実装タスク全部の番号を持つ（実装→レビューの順で消化される）
- 観点ファイルが無い／todo に実装タスクが 0 件のときは何もしない

リポジトリ同梱の `process-runner-review.md` は **サンプル 2 件 (`code-quality` / `dead-code`)** だけが入った最小テンプレ。`code-quality` は重厚な観点リスト、`dead-code` は数行で済む軽量チェックの例で、**H2 セクションの長さは自由**（1 観点 1 セクションに分けて並列で走らせるのがコンセプト）。プロジェクトの観点を H2 として書き足して使う。差替は単に md を編集するだけ（スクリプトには触らない）。

各レビュータスクは:
- コードの修正・コミット・push を一切しない (read-only)
- 質問は会話に出さず、出力ファイルの `## Questions` セクションに集約する（後でまとめて回答する運用）

## ファイル配置

実行時に生成されるもの:

```
/tmp/runner-<ts>[-<slug>]/   # workdir（プロジェクト外に隔離）
├── DESIGN.md                # 不変方針
├── tasks/
│   ├── todo/NNN-*.md        # 未実行（実装タスク + レビュータスク）
│   └── done/NNN-*.md        # 完了（末尾に ## Result）
├── reviews/                 # レビュー成果物の書き出し先
│   └── review-<section>.md  # 各レビュータスクの出力 (## Summary / ## Findings / ## Questions)
├── logs/NNN-slug-<ts>.log   # タスク実行ログ（試行ごと新規）
└── .project                 # プロジェクトの絶対パス

~/src/scripts/link/<sanitized-cwd> → workdir   # cwd ベース symlink（reviews/ もこの下でアクセス可）
```

`<sanitized-cwd>` は cwd の `/` を `_` に置換したもの（例: `/Users/foo/proj/bar` → `Users_foo_proj_bar`）。cwd ごとに異なるので複数プロジェクト併用で衝突しない。

## ライセンス

MIT — [LICENSE](./LICENSE) 参照
