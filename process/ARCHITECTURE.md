# claude-runner — Architecture

## 全体像

```
                    plan (対話 claude)
                          │
                          ▼
        ┌─────────────────────────────────────┐
        │  workdir: /tmp/runner-<ts>[-<slug>] │
        │  ├── DESIGN.md (不変)               │
        │  ├── tasks/todo/NNN-*.md            │
        │  ├── tasks/done/NNN-*.md (## Result)│
        │  ├── logs/NNN-*-<ts>.log            │
        │  └── .project                       │
        └─────────────┬───────────────────────┘
                      │
            run-all (Wave 並列, xargs -P)
                      │
        ┌─────────────┴─────────────┐
        ▼                           ▼
  claude -p (task 001)        claude -p (task 002)   ...
    cwd=$PROJECT                cwd=$PROJECT
    --add-dir $WORKDIR          --add-dir $WORKDIR
        │                           │
        ▼                           ▼
  stream-json → jq → log     stream-json → jq → log
  + stdout (STREAM=1)        + stdout (STREAM=1)
```

## 中核となる設計判断

### DESIGN.md は不変方針

`plan` 確定後は read-only として扱い、どのタスクも書き換えない。複数タスクが並列で同じファイルを更新する状況を構造的に排除する。

タスクごとの結果は各タスクファイルの末尾に追記する `## Result` セクションで運ぶ。

### タスク間引き継ぎは `## Result` のみ

後続タスクは依存元 `tasks/done/NNN-*.md` の Result セクションだけを読んで前段の成果物を把握する。

```markdown
# 001 hello.js を作成

`hello.js` に "hello world" を出力するスクリプトを作る。

## Result
- 生成: /tmp/aaa/hello.js
- 実行: node hello.js → "hello world\n"
- 改善余地なし
```

依存タスクは Result から必要な情報（生成ファイルパス・I/F・決定事項）を拾う前提で設計する。生ログや思考過程は書かない。

### 依存記法

タスクファイル冒頭に HTML コメントで:

```markdown
# 002 hello.js をレビュー

<!-- depends: 001 -->

001 で作成したスクリプトをレビューする。
```

数値が無ければ依存なし＝即 ready。

### Wave 方式の並列実行

`run-all` は次のループで進む:

1. `tasks/todo/` の中で依存が全部 done のもの = ready 集合を計算
2. `xargs -n1 -P $JOBS` で並列起動（既定 4 並列）
3. **そのバッチが全部終わるまで待つ**（バリア）
4. 完了したものを `done/` へ移動、次の ready を再評価
5. todo が空になるまで繰り返し

非最適だが実装が単純。完了通知ベースの即時起動は将来課題。

### 失敗マーカー

AI が真に解決不能と判断した場合のみ `## Status: failed` を Result に書く。`claude-runner-process.sh` は `grep` で検出して `done/` に移さず todo に残す。再試行時は AI に「前回失敗の記録」として読ませる。

### 実行ログ (stream-json + jq)

claude を `-p --output-format stream-json --verbose` で起動し、流れてくる JSONL を `jq` で整形して `$WORKDIR/logs/<task-base>-<ts>.log` に保存する。1 イベント 1 行:

```
[init] model=claude-opus-4-7 cwd=/path/to/project
[tool] Bash {"command":"pwd","description":"..."}
[result] /tmp
[text] /tmp
[done] 5116ms turns=2 cost=$0.110672
```

ツール呼び出し / テキスト応答 / コストが追えるので、進捗観察と事後デバッグに使える。試行ごとに新規ファイル（上書きしない）なので再試行履歴も全部残る。ファイル冒頭にヘッダ（task / project / model / effort / 開始時刻）、末尾に終了時刻と exit code。

`jq` が無ければ raw JSONL をそのまま記録する（`fmt_stream` 関数の fallback）。

`STREAM` は既定 `1`。ログ書き込みに加えて整形済みストリームを `[NNN-slug] ...` プレフィックス付きで親 stdout にも流す（`tee` + `sed`、claude の rc は `PIPESTATUS[0]` で取得）。並列実行時は時系列で混ざるがプレフィックスで識別可能。長い行が PIPE_BUF (4096B) を超えると分断され得る点だけ注意。

### claude 呼び出しの cwd 分離

- メタ操作（todo/done 移動・ready 判定）: cwd = workdir
- claude 起動: subshell で `cd $PROJECT && claude -p --add-dir $WORKDIR ...`
- 親 `run-all` は `WORKDIR` を export して `xargs` 経由の `_run-one` に伝播

claude は cwd をプロジェクトルートとして起動するので、プロジェクト内のコードをそのまま操作できる。一方で workdir のメタ情報（DESIGN.md / 依存タスクの Result）は `--add-dir` で読めるよう開いておく。

### plan 後のレビュータスク自動生成

`plan` の対話 claude を抜けた後、`REVIEW_SPEC` で指定された md ファイル（既定: スクリプトと同じディレクトリの `claude-runner-process-review.md`）を読み込み、その `## H2` セクション数ぶんの **read-only レビュータスク** を todo に自動追加する。

```
plan の対話終了
        │
        ▼
  generate_review_tasks
        │
        ├── 観点ファイル無し → skip（warn のみ）
        ├── todo に実装タスク 0 件 → skip
        └── 観点ファイルの ## XXX セクションを抽出
                │
                ▼
        各セクションごとに NNN-review-<slug>.md を todo に作成
        - depends: 実装タスク全部の番号
        - 本文: 観点ファイルの「## XXX セクションを読め」 + 出力先 (<workdir>/reviews/review-<slug>.md)
                │
                ▼
        run-all で実装 → レビューの順に消化
        レビュータスクは並列で書き出し
```

設計判断:
- 観点ファイルは **md 1 枚** に集約。`## H2` を増やせば次の plan からタスクが増える。スクリプト本体は触らない
- 出力先は workdir 直下 (`<workdir>/reviews/`) にまとめる。symlink (`$LINK_DIR/<sanitized-cwd>`) 経由でアクセス可能なので、タスク/ログ/レビュー成果物がすべて 1 箇所に集約される
- 質問は会話に出さず出力ファイルの `## Questions` に集約する規約。並列レビューの途中で人間が拘束されない
- 共通ルール内のサブ見出しは `### / ####` に降格して「全 `## ` = タスク」の単純規則を維持

reset との相性: タスク本文中の `## このタスクの ## Result` という見出し片は、awk `^## Result` が行頭固定なので副作用なく保持される（reset は追記された Result セクションだけを正しく剥がす）。

### symlink 名 = サニタイズした cwd

`/Users/foo/proj/bar` → `~/src/scripts/link/Users_foo_proj_bar` → workdir

cwd ベースで命名するので複数プロジェクトを併用しても衝突しない。プロジェクトのサブディレクトリから呼ぶと別名 symlink になるので、常に同じ cwd（プロジェクトルート）から呼ぶこと。

## プロンプト設計の方針

### plan の system prompt

- ユーザの要望を引き出し、不明点・選択肢・トレードオフを示しながら方針を固める
- 自分の判断で勝手にファイルを作らない。合意が取れたタイミングでのみ書く
- DESIGN.md は `## Goal` / `## Approach` / `## Open Questions` の 3 セクション
- タスクは 1 ファイル冒頭が `# タスク名`、依存があるときだけ `<!-- depends: NNN -->` を付ける
- 各タスクの実行プロセスは「DESIGN.md + 自タスクファイル + 依存タスクの Result」しか読まない前提
- 必要な情報が依存タスクの Result に乗るよう依存関係を設計する
- 成果物の配置はタスク担当 AI が判断する前提で書く（既存ファイル修正・新規作成いずれも可）

### run_one の per-task prompt

- 「やり切る」原則: コマンド失敗 → 自分で解決、生成物にバグ → その場で修正、別タスク扱い禁止
- 完了扱いにする前に必ず実行・動作確認
- 既存ファイル書き換え許可、生成物の配置はタスクの性質に応じて AI 判断
- DESIGN.md は触らない、他タスクファイルは触らない
- 冗長な説明・生ログは Result に書かない（1〜5 行で簡潔に）
- 再試行時: 既存の Result/Status を「前回失敗の記録」として読む。完了時に上書き
- 真に解決不能の場合のみ `## Status: failed` を Result に書く

## 制約・既知の落とし穴

- macOS bash 3.2 互換で書いてある（`mapfile` 不使用、`while read` で配列構築）
- heredoc 内で全角文字に隣接する変数参照は `${VAR}` で囲む（bash 3.2 のパースバグ回避）
- `awk` の `\b` は使わない（BSD awk で動かない）
- `claude` は `--dangerously-skip-permissions` 付きで起動するので、AI 確認なしで全操作が実行される
- AI が生成するタスク本文に旧プロンプトと矛盾する文言（例:「失敗は別タスク扱い」）が紛れることがある → 見つけたら編集
- `STREAM=1` の並列出力は時系列で混ざる（プレフィックスで識別はできる）
- workdir は `/tmp` に置くので OS の tmpfs クリーンアップで消える可能性がある。長期間保存したいなら `WORKDIR` を別の場所に
