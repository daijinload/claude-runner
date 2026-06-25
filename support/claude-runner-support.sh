#!/bin/bash
# Minimal support runner: 対話 claude で work.md / review.md を作るだけ。
# 実装・レビューは「貼り付け用メッセージ」を表示し、ユーザが別窓 claude に貼って実行する。
#
# Mode: 「プロジェクト内で作業」専用
#   - スクリプトを実行した cwd = プロジェクトルート
#   - メタ情報 (work.md / review.md / review-result.md) は /tmp/runner-<ts>[-<slug>]/ に隔離
#   - symlink は $LINK_DIR/<sanitized cwd> に作る（プロジェクトを汚さない、cwd ごとに別名）
#
# Usage:
#   cd ~/myproject
#   claude-runner-support.sh plan [name]  — 対話claudeで壁打ち。work.md と review.md を作る
#   claude-runner-support.sh show         — 状況表示 + 貼り付け用メッセージ再表示
#   claude-runner-support.sh reset        — review-result.md / logs / work.md の Result 削除
#
# 実行モデル:
#   plan が終わると stdout に「実装用」「レビュー用」の貼り付けメッセージを 2 つ表示する。
#   ユーザは別窓で claude を起動して、それぞれをコピペして実行する。
#   実装は work.md 末尾に `## Result` が追記される。
#   レビューは workdir/review-result.md に結果が書き出される。
#
# Env: MODEL, EFFORT, WORKDIR, LINK_DIR, CLAUDE_BIN, REVIEW_SPEC

set -euo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LINK_DIR="${LINK_DIR:-$HOME/src/scripts/link}"
MODEL="${MODEL:-}"
EFFORT="${EFFORT:-}"
REVIEW_SPEC="${REVIEW_SPEC:-$(cd "$(dirname "$0")" && pwd)/claude-runner-support-review.md}"

WORK_FILE="work.md"
REVIEW_FILE="review.md"
REVIEW_RESULT_FILE="review-result.md"

INVOKE_CWD="$(pwd)"
sanitize_path() {
  echo "$1" | sed 's|^/||; s|/|_|g'
}
LINK_PATH="$LINK_DIR/$(sanitize_path "$INVOKE_CWD")"

CLAUDE_FLAGS=(--dangerously-skip-permissions)
[ -n "$MODEL" ] && CLAUDE_FLAGS+=(--model "$MODEL")
[ -n "$EFFORT" ] && CLAUDE_FLAGS+=(--effort "$EFFORT")

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9ぁ-んァ-ヶー一-龠]+/-/g; s/^-+|-+$//g' \
    | cut -c1-30
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

print_paste_messages() {
  local wd="$1"
  cat <<EOF

=== Work (実装) — 別窓の claude にコピペ ===
$wd/$WORK_FILE を読んで実装してください。完了したら同ファイル末尾に ## Result セクションを追記してください（変更点・生成物・残課題を簡潔に）。

=== Review (レビュー) — 別窓の claude にコピペ ===
$wd/$REVIEW_FILE を読んでレビューを実施し、結果を $wd/$REVIEW_RESULT_FILE に書き出してください。

=== ここまで ===
EOF
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
    mkdir -p "$workdir/logs"
    echo "$project" > "$workdir/.project"
    mkdir -p "$LINK_DIR"
    ln -sfn "$workdir" "$LINK_PATH"
    echo "Project: $project"
    echo "Workdir: $workdir"
    echo "Link:    $LINK_PATH -> $workdir"
    echo

    review_spec_block=""
    if [ -f "$REVIEW_SPEC" ]; then
      review_spec_block="レビュー観点のテンプレートとして $REVIEW_SPEC を参照できます（必要なら読んでプロジェクト向けに整形してください）。"
    fi

    echo "対話モードで claude を起動します（cwd=${project}）。"
    echo "壁打ちで設計を詰め、合意できたら ${workdir}/${WORK_FILE} と ${workdir}/${REVIEW_FILE} の 2 ファイルだけを保存してください。"
    echo "終わったら /exit で抜けてください。"
    echo
    sysprompt=$(cat <<EOF
あなたはユーザと一緒にプロジェクトの設計を「壁打ち」で詰めるパートナーです。

このセッションのカレントディレクトリ (${project}) がユーザのプロジェクトルートです。
既存コードを読みながら、何を変えるか / 何を作るかをユーザと詰めていきます。
プロジェクト外にメタディレクトリ (${workdir}) があり、--add-dir で読み書きアクセスが与えられています。
成果物は ${workdir}/${WORK_FILE} と ${workdir}/${REVIEW_FILE} の 2 ファイルだけ作ります。

最初の発話でユーザに「何を作りたいか / 何を変えたいか」を聞き、対話で目標と方針を固めていきます。

役割と進め方:
- ユーザの要望を引き出し、不明点・選択肢・トレードオフを示しながら方針を固める
- 必要なら既存コードを読んで現状理解の助けにする
- 自分の判断で勝手にファイルを作らない。合意が取れたタイミングでのみ書く

合意が固まったら ${workdir}/${WORK_FILE} に以下を書きます（背景・実装方針・実装手順を 1 ファイルに統合）:
  # <短いタイトル>

  ## Goal — このタスクの目標
  ## Background — 関連する既存コード・前提・制約
  ## Approach — 実装方針
  ## 実装手順 — 別窓の claude が読んで実行できる程度の粒度で
  ## Open Questions — 残った不明点（あれば）

別窓で実装担当 claude がこの ${WORK_FILE} を読んで実装し、末尾に ## Result を追記します。
そのため「読むだけで実装可能」な完結性を持たせてください（必要なファイルパス・コマンド・期待結果を明示）。

並行して ${workdir}/${REVIEW_FILE} にレビュー観点を書きます:
  # Review for <タイトル>

  ## Scope — レビュー対象 (差分の範囲、ファイル群)
  ## 観点 — チェックする項目を箇条書きで（${WORK_FILE} の内容に応じて必要なものを選定）
  ## 出力 — ${workdir}/${REVIEW_RESULT_FILE} に Summary / Findings / Questions の構成で書く旨を明示

${review_spec_block}

応答スタイル:
- 簡潔に。冗長な前置きや盛った装飾を避ける
- 中身に見合った長さで書く
EOF
)
    "$CLAUDE_BIN" "${CLAUDE_FLAGS[@]}" --add-dir "$workdir" --append-system-prompt "$sysprompt" || true

    echo
    echo "=== plan 終了 ==="
    if [ -f "$workdir/$WORK_FILE" ]; then
      echo "✓ $workdir/$WORK_FILE"
    else
      echo "✗ $workdir/$WORK_FILE が作られていません"
    fi
    if [ -f "$workdir/$REVIEW_FILE" ]; then
      echo "✓ $workdir/$REVIEW_FILE"
    else
      echo "✗ $workdir/$REVIEW_FILE が作られていません"
    fi
    print_paste_messages "$workdir"
    ;;

  show)
    enter_workdir
    echo "Project: $PROJECT"
    echo "Workdir: $WORKDIR"
    echo
    echo "=== $WORK_FILE ==="
    if [ -f "$WORK_FILE" ]; then
      echo "  exists ($(wc -l < "$WORK_FILE") lines)"
      if grep -q '^## Result' "$WORK_FILE"; then
        echo "  ## Result あり（実装完了）"
      else
        echo "  ## Result なし（未実装）"
      fi
    else
      echo "  (not created)"
    fi
    echo
    echo "=== $REVIEW_FILE ==="
    if [ -f "$REVIEW_FILE" ]; then
      echo "  exists ($(wc -l < "$REVIEW_FILE") lines)"
    else
      echo "  (not created)"
    fi
    echo
    echo "=== $REVIEW_RESULT_FILE ==="
    if [ -f "$REVIEW_RESULT_FILE" ]; then
      echo "  exists ($(wc -l < "$REVIEW_RESULT_FILE") lines)"
    else
      echo "  (not created)"
    fi
    print_paste_messages "$WORKDIR"
    ;;

  reset)
    enter_workdir
    removed_result=0
    if [ -f "$REVIEW_RESULT_FILE" ]; then
      rm -f "$REVIEW_RESULT_FILE"
      removed_result=1
    fi
    stripped_work=0
    if [ -f "$WORK_FILE" ] && grep -q '^## Result' "$WORK_FILE"; then
      awk '/^## Result/{exit} {print}' "$WORK_FILE" > "$WORK_FILE.tmp"
      mv "$WORK_FILE.tmp" "$WORK_FILE"
      stripped_work=1
    fi
    removed_logs=0
    if [ -d logs ]; then
      for l in logs/*.log; do
        [ -e "$l" ] || continue
        rm -f "$l"
        removed_logs=$((removed_logs + 1))
      done
    fi
    echo "Reset: review-result=${removed_result} work.md(stripped)=${stripped_work} logs=${removed_logs}"
    echo "       work.md / review.md は維持されています。"
    ;;

  *)
    cat <<EOF >&2
Usage (cwd = project root):
  $0 plan [name]  — 対話claudeで壁打ち。work.md と review.md を作って 2 ファイルだけ保存
  $0 show         — 状況表示 + 貼り付け用メッセージ再表示
  $0 reset        — review-result.md / logs / work.md の Result 削除（work.md / review.md は維持）

実行モデル:
  plan が終わると、別窓で claude に貼り付けるメッセージが 2 つ表示されます。
  - Work 用: work.md を読んで実装する → work.md 末尾に ## Result を追記
  - Review 用: review.md を読んでレビュー → review-result.md に書き出す
  show でいつでも再表示できます。

環境変数:
  MODEL=...        claude モデル上書き（例: sonnet, haiku）
  EFFORT=...       effort 上書き（low/medium/high/xhigh/max）
  WORKDIR=PATH     workdir 直接指定（symlink バイパス）
  LINK_DIR=PATH    symlink 配置先（既定 ~/src/scripts/link）
  CLAUDE_BIN=PATH  claude バイナリ
  REVIEW_SPEC=PATH plan の壁打ちで参照するレビュー観点テンプレ（既定: スクリプトと同じディレクトリの claude-runner-support-review.md）

メタ情報の場所:
  workdir: /tmp/runner-<ts>[-<slug>]/   (work.md, review.md, review-result.md, logs/, .project)
  symlink: $LINK_DIR/<sanitized cwd> -> workdir
           (cwd=$INVOKE_CWD のとき: $LINK_PATH)
EOF
    exit 1
    ;;
esac
