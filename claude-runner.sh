#!/bin/bash
# Minimal task runner: spawns a fresh `claude -p` process per task file.
#
# Mode: 「プロジェクト内で作業」専用
#   - スクリプトを実行した cwd = プロジェクトルート
#   - メタ情報 (DESIGN.md, tasks/, logs/) は /tmp/runner-<ts>[-<slug>]/ に隔離
#   - symlink は $LINK_DIR/<sanitized cwd> に作る（プロジェクトを汚さない、cwd ごとに別名）
#   - claude は cwd=プロジェクト、--add-dir で workdir のメタを可視化
#   - 生成・修正対象はプロジェクト内のコード。配置はAIが判断
#
# Usage:
#   cd ~/myproject
#   claude-runner.sh plan [name]   — 対話claudeで壁打ち。DESIGN.md とタスクを合意
#   claude-runner.sh add  "<task>" — タスクファイルを追加
#   claude-runner.sh next          — ready な先頭1件を実行
#   claude-runner.sh run-all       — ready なものを並列実行（JOBS=並列度, 既定4）
#   claude-runner.sh show          — 状況表示（DESIGN/TODO/DONE/LOGS）
#   claude-runner.sh reset         — done→todo 戻す + Result削除 + ログ削除（DESIGN.md 維持）
#
# Env: MODEL, EFFORT, JOBS, STREAM (既定 1: stdout に流す。0 で抑制),
#      WORKDIR, LINK_DIR, CLAUDE_BIN

set -euo pipefail

DOC="${DOC:-DESIGN.md}"
TASKS_DIR="${TASKS_DIR:-tasks}"
TODO_DIR="$TASKS_DIR/todo"
DONE_DIR="$TASKS_DIR/done"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
JOBS="${JOBS:-4}"
LINK_DIR="${LINK_DIR:-$HOME/src/scripts/link}"
MODEL="${MODEL:-}"
EFFORT="${EFFORT:-}"
STREAM="${STREAM:-1}"

# Symlink name = sanitized invocation cwd. Each project gets its own symlink.
INVOKE_CWD="$(pwd)"
sanitize_path() {
  echo "$1" | sed 's|^/||; s|/|_|g'
}
LINK_PATH="$LINK_DIR/$(sanitize_path "$INVOKE_CWD")"

CLAUDE_FLAGS=(--dangerously-skip-permissions)
[ -n "$MODEL" ] && CLAUDE_FLAGS+=(--model "$MODEL")
[ -n "$EFFORT" ] && CLAUDE_FLAGS+=(--effort "$EFFORT")

SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# stream-json イベントを 1 行ずつ人間可読に整形するフィルタ。
# jq が無ければ raw JSONL をそのまま流す。
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=1
else
  HAS_JQ=0
fi
JQ_FILTER='
  if .type == "system" and .subtype == "init" then
    "[init] model=\(.model) cwd=\(.cwd)"
  elif .type == "assistant" then
    (.message.content // []) | .[] |
    if .type == "tool_use" then
      "[tool] \(.name) \(.input | tostring | gsub("\n"; " ") | .[0:240])"
    elif .type == "text" then
      "[text] \(.text | gsub("\n"; " ") | .[0:240])"
    elif .type == "thinking" then
      "[think] \(.thinking | gsub("\n"; " ") | .[0:240])"
    else empty end
  elif .type == "user" then
    (.message.content // []) | .[] |
    if .type == "tool_result" then
      "[result] \(.content | tostring | gsub("\n"; " ") | .[0:240])"
    else empty end
  elif .type == "result" then
    "[done] \(.duration_ms)ms turns=\(.num_turns) cost=$\(.total_cost_usd)"
  else empty end
'
fmt_stream() {
  if [ "$HAS_JQ" = "1" ]; then
    jq -r --unbuffered "$JQ_FILTER"
  else
    cat
  fi
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9ぁ-んァ-ヶー一-龠]+/-/g; s/^-+|-+$//g' \
    | cut -c1-30
}

next_task_num() {
  local max=0 n
  for f in "$TODO_DIR"/*.md "$DONE_DIR"/*.md; do
    [ -e "$f" ] || continue
    n=$(basename "$f" | grep -oE '^[0-9]+' || echo 0)
    (( n > max )) && max=$n
  done
  printf "%03d" $((max + 1))
}

task_deps() {
  local f="$1"
  grep -oE '<!-- *depends:[^>]*-->' "$f" 2>/dev/null \
    | sed -E 's/<!-- *depends: *//; s/ *-->//' \
    | tr -s ' \t,' '\n' \
    | grep -E '^[0-9]+$' || true
}

deps_done() {
  local f="$1" d
  while read -r d; do
    [ -z "$d" ] && continue
    ls "$DONE_DIR"/${d}-*.md >/dev/null 2>&1 || return 1
  done < <(task_deps "$f")
  return 0
}

ready_tasks() {
  local f
  for f in "$TODO_DIR"/*.md; do
    [ -e "$f" ] || continue
    deps_done "$f" && echo "$f"
  done
}

resolve_workdir() {
  if [ -n "${WORKDIR:-}" ]; then
    echo "$WORKDIR"
    return
  fi
  if [ -L "$LINK_PATH" ]; then
    readlink "$LINK_PATH"
    return
  fi
  echo ""
}

resolve_project() {
  local wd="$1"
  [ -f "$wd/.project" ] && cat "$wd/.project"
}

enter_workdir() {
  local wd proj
  wd=$(resolve_workdir)
  if [ -z "$wd" ]; then
    echo "Error: no workdir. Run '$0 plan' first, or set WORKDIR." >&2
    exit 1
  fi
  if [ ! -d "$wd" ]; then
    echo "Error: workdir not found: $wd" >&2
    exit 1
  fi
  proj=$(resolve_project "$wd")
  if [ -z "$proj" ] || [ ! -d "$proj" ]; then
    echo "Error: project not recorded or missing for workdir $wd (expected $wd/.project)" >&2
    exit 1
  fi
  export WORKDIR="$wd"
  export PROJECT="$proj"
  cd "$wd"
}

run_one() {
  local task_file="$1"
  local wd="$WORKDIR"
  local task_abs="$wd/$task_file"
  local doc_abs="$wd/$DOC"
  local done_abs="$wd/$DONE_DIR"
  local logs_dir="$wd/logs"
  mkdir -p "$logs_dir"
  local task_base
  task_base=$(basename "$task_file" .md)
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local log_abs="$logs_dir/${task_base}-${ts}.log"

  if [ ! -f "$task_abs" ]; then
    echo "✗ Missing: $task_abs" >&2
    return 1
  fi
  echo "▶ Running: $task_file (log: $log_abs)"

  local prompt
  prompt=$(cat <<EOF
継続中のプロジェクトのタスクを1つ担当します。

カレントディレクトリ ($PROJECT) がプロジェクトのルートです。
既存ファイルの読み書き・新規ファイル作成OK。プロジェクトのコードを目的に応じて修正してください。
メタファイル（DESIGN.md / タスク / 進捗）は $wd 配下にあり、--add-dir で読み書きアクセスがあります。

手順:
1. $doc_abs を読み、プロジェクト全体の目標・方針・未解決事項を把握する（読むだけ。書き換えない）。
2. $task_abs を読む。冒頭の "<!-- depends: NNN ... -->" に番号が列挙されていれば、
   $done_abs/NNN-*.md を全て読み、前段タスクの "## Result" を確認する。
3. $task_abs に既に "## Result" や "## Status: failed" がある場合は、前回の試行が失敗して
   再試行に回された記録。記述された失敗理由を踏まえて、今回はやり切ること。
   完了時にはそれらのセクションを最新の内容で上書きする（古いものを残さない）。
4. タスクを実行する。成果物の置き場所（プロジェクト内のどのパスに作るか、既存ファイルを修正するか等）
   はタスクの性質に応じて自分で判断する。
5. 「やり切る」原則: タスクの目的が達成されるまで諦めず、その場で解決する。
   - コマンドが失敗 → 原因を調べて自分で修正・再実行する
   - 生成物にバグ → その場で修正する
   - 依存パッケージ不足 → 自分でインストールする
   - 「別タスク扱い」「後で対応」「修正は範囲外」等の先送りは禁止
6. 完了扱いにする前に、必ず実行・動作確認まで行い、成功を確認する。
7. 動作確認まで含めて成功したら、$task_abs の末尾に "## Result" セクションを追加し、
   何をしたかと後続タスクが知るべき成果物（生成・変更したファイルパス、決定事項、I/F等）
   を1〜5行で簡潔に書く。
8. 真にこのタスク単独では解決不能（例: 外部リソース・権限不足）の場合のみ、
   "## Result" に加えて "## Status: failed" 行を末尾に書き、理由を簡潔に述べる。
   "後で別タスクで" とは書かない。
9. 重要: $doc_abs は触らない。自分のタスクファイル以外（$wd/$TASKS_DIR/ 配下の他ファイル）も触らない。
   要約重視、生ログ・思考過程は書かない。
10. 出力はファイル更新のみ。チャット返答は不要。
EOF
)
  {
    echo "=== task:     $task_file"
    echo "=== started:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=== project:  $PROJECT"
    echo "=== workdir:  $wd"
    echo "=== model:    ${MODEL:-(settings.json default)}"
    echo "=== effort:   ${EFFORT:-(settings.json default)}"
    echo "==="
  } > "$log_abs"

  local rc=0
  set +e
  if [ "$STREAM" = "1" ]; then
    ( cd "$PROJECT" && "$CLAUDE_BIN" -p --add-dir "$wd" \
        --output-format stream-json --verbose "${CLAUDE_FLAGS[@]}" "$prompt" ) 2>&1 \
      | fmt_stream \
      | tee -a "$log_abs" \
      | sed "s|^|[${task_base}] |"
    rc=${PIPESTATUS[0]}
  else
    ( cd "$PROJECT" && "$CLAUDE_BIN" -p --add-dir "$wd" \
        --output-format stream-json --verbose "${CLAUDE_FLAGS[@]}" "$prompt" ) 2>&1 \
      | fmt_stream >> "$log_abs"
    rc=${PIPESTATUS[0]}
  fi
  set -e

  {
    echo "==="
    echo "=== finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=== exit:     $rc"
  } >> "$log_abs"

  if [ "$rc" -eq 0 ]; then
    if grep -qiE '^##? *Status:? *(failed|failure)\b' "$task_abs" 2>/dev/null; then
      echo "✗ Failed (## Status: failed in Result): $task_file (kept in todo, log: $log_abs)" >&2
      return 1
    fi
    mv "$task_abs" "$done_abs/"
    echo "✓ Done: $(basename "$task_file") (log: $log_abs)"
  else
    echo "✗ Failed: $task_file (kept in todo, log: $log_abs)" >&2
    return 1
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  plan)
    name="${1:-}"
    project=$(pwd)
    ts=$(date +%Y%m%d-%H%M%S)
    slug=""
    [ -n "$name" ] && slug=$(slugify "$name")
    workdir="/tmp/runner-$ts${slug:+-$slug}"
    if [ -e "$workdir" ]; then
      echo "Error: $workdir already exists." >&2
      exit 1
    fi
    mkdir -p "$workdir/$TODO_DIR" "$workdir/$DONE_DIR"
    echo "$project" > "$workdir/.project"
    mkdir -p "$LINK_DIR"
    ln -sfn "$workdir" "$LINK_PATH"
    echo "Project: $project"
    echo "Workdir: $workdir"
    echo "Link:    $LINK_PATH -> $workdir"
    echo
    echo "対話モードで claude を起動します（cwd=${project}）。"
    echo "壁打ちで設計を詰め、合意できたら DESIGN.md と tasks/todo/NNN-*.md を ${workdir} に保存してください。"
    echo "終わったら /exit で抜けて、次に '$0 run-all' を実行できます。"
    echo
    sysprompt=$(cat <<EOF
あなたはユーザと一緒にプロジェクトの設計を「壁打ち」で詰めるパートナーです。

このセッションのカレントディレクトリ (${project}) がユーザのプロジェクトルートです。
既存コードを読みながら、何を変えるか / 何を作るかをユーザと詰めていきます。
プロジェクト外にメタディレクトリ (${workdir}) があり、--add-dir で読み書きアクセスが与えられています。
DESIGN.md とタスクファイルは全てこのメタディレクトリに保存します。

最初の発話でユーザに「何を作りたいか / 何を変えたいか」を聞き、対話で目標と方針を固めていきます。

役割と進め方:
- ユーザの要望を引き出し、不明点・選択肢・トレードオフを示しながら方針を固める
- 必要なら既存コードを読んで現状理解の助けにする
- 自分の判断で勝手にファイルを作らない。合意が取れたタイミングでのみ書く
- 合意が固まったら ${workdir}/${DOC} を作成・更新する。セクション:
  - ## Goal — 目標
  - ## Approach — 進め方の方針
  - ## Open Questions — 残った不明点
- ユーザが「タスクに分割して」「これで進めて」等と言ったら ${workdir}/${TODO_DIR}/NNN-slug.md にタスクを分割保存する
  - NNN は3桁ゼロ埋め連番（001から）
  - 1ファイル冒頭は「# タスク名」、その下に何をするかを簡潔に
  - 依存がある場合のみタスク名の直下に "<!-- depends: NNN NNN -->" を書く
  - 各タスクの実行プロセスは「${workdir}/${DOC} + 自タスクファイル + 依存タスクの ${workdir}/${DONE_DIR}/ ファイル」
    しか読まない前提。必要な情報が依存タスクの ## Result に乗るよう依存関係を設計する
  - 成果物（プロジェクト内のコード等）の置き場所はタスク担当AIが判断する前提で書く
    （既存ファイル修正・新規作成いずれも可）
  - 1タスクは1プロセスで完結し、可能な限り独立に分割する（並列化のため）

応答スタイル:
- 簡潔に。冗長な前置きや盛った装飾を避ける
- 中身に見合った長さで書く
EOF
)
    exec "$CLAUDE_BIN" "${CLAUDE_FLAGS[@]}" --add-dir "$workdir" --append-system-prompt "$sysprompt"
    ;;

  add)
    task="${1:?Usage: $0 add \"<task>\"}"
    enter_workdir
    num=$(next_task_num)
    slug=$(slugify "$task")
    [ -z "$slug" ] && slug="task"
    file="$TODO_DIR/$num-$slug.md"
    {
      echo "# $task"
      echo
      echo "$task"
    } > "$file"
    echo "Created: $WORKDIR/$file"
    ;;

  next)
    enter_workdir
    task_file=$(ready_tasks | sort | head -n1)
    if [ -z "$task_file" ]; then
      if ls "$TODO_DIR"/*.md >/dev/null 2>&1; then
        echo "No ready task (dependencies unmet)." >&2
        exit 1
      fi
      echo "No tasks in $TODO_DIR."
      exit 0
    fi
    run_one "$task_file"
    ;;

  run-all)
    enter_workdir
    while ls "$TODO_DIR"/*.md >/dev/null 2>&1; do
      ready=()
      while IFS= read -r line; do
        [ -n "$line" ] && ready+=("$line")
      done < <(ready_tasks | sort)
      if [ ${#ready[@]} -eq 0 ]; then
        echo "✗ Deadlock: todo has tasks but none are ready (check depends)." >&2
        exit 1
      fi
      echo "── Wave: ${#ready[@]} task(s), up to $JOBS in parallel ──"
      if ! printf '%s\n' "${ready[@]}" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT" _run-one {}; then
        echo "✗ run-all: 1+ task(s) failed this wave (kept in todo, see $WORKDIR/logs/)." >&2
        echo "  Re-run '$0 run-all' after fixing, or '$0 reset' to start over." >&2
        exit 1
      fi
    done
    echo "All tasks done."
    ;;

  _run-one)
    enter_workdir
    run_one "${1:?}"
    ;;

  reset)
    enter_workdir
    moved=0
    for f in "$DONE_DIR"/*.md; do
      [ -e "$f" ] || continue
      awk '/^## Result/{exit} {print}' "$f" > "$f.tmp"
      mv "$f.tmp" "$f"
      mv "$f" "$TODO_DIR/"
      moved=$((moved + 1))
    done
    removed_logs=0
    if [ -d logs ]; then
      for l in logs/*.log; do
        [ -e "$l" ] || continue
        rm -f "$l"
        removed_logs=$((removed_logs + 1))
      done
    fi
    echo "Reset: moved $moved task(s) done → todo (Result stripped), removed $removed_logs log file(s). DESIGN.md kept."
    ;;

  show)
    enter_workdir
    echo "Project: $PROJECT"
    echo "Workdir: $WORKDIR"
    echo
    echo "=== $DOC ==="
    if [ -f "$DOC" ]; then cat "$DOC"; else echo "(not created)"; fi
    echo
    echo "=== TODO ==="
    if ls "$TODO_DIR"/*.md >/dev/null 2>&1; then
      for f in "$TODO_DIR"/*.md; do
        deps=$(task_deps "$f" | tr '\n' ' ')
        ready=$(deps_done "$f" && echo "ready" || echo "blocked")
        printf "  [%s] %s%s\n" "$ready" "$(basename "$f")" \
          "$([ -n "$deps" ] && echo " (deps: $deps)")"
      done
    else
      echo "  (empty)"
    fi
    echo
    echo "=== DONE ==="
    if ls "$DONE_DIR"/*.md >/dev/null 2>&1; then
      ls "$DONE_DIR" | sed 's/^/  /'
    else
      echo "  (empty)"
    fi
    echo
    echo "=== LOGS (latest 20, newest first) ==="
    if [ -d logs ] && ls logs/*.log >/dev/null 2>&1; then
      ls -t logs/*.log | head -n 20 | sed 's|^|  |'
    else
      echo "  (empty)"
    fi
    ;;

  *)
    cat <<EOF >&2
Usage (cwd = project root):
  $0 plan [name]   — 対話claudeで壁打ち。DESIGN.md とタスクを合意して保存
  $0 add  "<task>" — タスクファイルを追加
  $0 next          — ready な先頭1件を実行
  $0 run-all       — ready なタスクを並列実行（JOBS=${JOBS}）
  $0 show          — 状況表示（DESIGN/TODO/DONE/LOGS）
  $0 reset         — done→todo 戻す + Result削除 + ログ削除（DESIGN.md 維持）

環境変数:
  MODEL=...        claude モデル上書き（例: sonnet, haiku）
  EFFORT=...       effort 上書き（low/medium/high/xhigh/max）
  JOBS=N           並列度（既定 4）
  STREAM=0         claude 出力を stdout に流すのを抑制（既定 1: [NNN-slug] プレフィックス付きで流れる）
  WORKDIR=PATH     workdir 直接指定（symlink バイパス）
  LINK_DIR=PATH    symlink 配置先（既定 ~/src/scripts/link）
  CLAUDE_BIN=PATH  claude バイナリ

メタ情報の場所:
  workdir: /tmp/runner-<ts>[-<slug>]/   (DESIGN.md, tasks/, logs/, .project)
  symlink: $LINK_DIR/<sanitized cwd> -> workdir
           (cwd=$INVOKE_CWD のとき: $LINK_PATH)

claude 呼び出し:
  cwd=プロジェクト、--add-dir workdir で双方アクセス可
  生成物の配置はタスクごとに AI が判断
EOF
    exit 1
    ;;
esac
