# レビュー観点テンプレ（claude-runner-support）

## このファイルの位置づけ

`claude-runner-support.sh plan` の壁打ちで claude がこれを読み、対象プロジェクト向けに整形した `review.md` を workdir に書く。

**`review.md` は ultracode の Workflow が消費する前提**で書く:

- 各 dimension = 1 つの finder agent としてパラレル展開される
- finding は adversarial verify を経て `review-result.md` に集約される
- aggregation を機械的にやるため、構造と出力スキーマを揃える

`review.md` を書くときは下記原則を守ること。

---

## review.md を書くときの原則

### 1. dimension は相互排他にする

同じ finding が 2 つ以上の dimension で上がらないように分ける。`process` 版の実運用で「dead i18n キー」が `self-review` / `dead-code` / `rename-completeness` の 3 観点から重複検出された事例があり、ultracode で fan-out するとそのまま冗長な agent コストになる。

各 dimension に **scope（何を見るか）** と **anti-scope（何は他に任せるか）** を必ず書く。

### 2. 粒度を揃える

1 dimension = 1 finder agent が扱える作業量にする。

- 大きすぎる例: 「self-review（全部見る）」 → 分割する
- 小さすぎる例: 単一ルール 1 件専用 → 関連する他に統合する

### 3. 出力スキーマを厳密に固定する

`review-result.md` の構造とフィールドを `review.md` 内で明示する。aggregation 側（Workflow）が parse できるよう、見出しと順序を機械的に守る。

---

## `review.md` の推奨構造

```markdown
# Review for <task title>

## Scope
- 対象差分: `git diff origin/main...HEAD` + uncommitted (`git diff` / `git status`)
- 対象言語: <list>
- 除外: 自動生成ファイル (`*.gen.*`, `*.pb.go`, `*_pb.ts`, etc.), vendored deps

## 厳守事項
- read-only（修正・コミット・push 禁止）
- **推測禁止**: コード逐語引用 + ルール逐語引用で裏付けが取れない finding は出さない
- **シェル実行**: grep / rg は AI 目視ではなくシェル実行で網羅確認する
- 質問は `## Questions` に集約（会話には出さない）

## Dimensions

<以下、各 dimension を ### で並べる。各 dimension は scope / anti-scope / 検出方法を持つ>

### <dimension-name>
- **scope**: <何を見るか 1-2 行>
- **anti-scope**: <何は他の dimension に任せるか>
- **検出方法**: <grep コマンド / 構造観察 / 参照ルールファイル>

### <dimension-name-2>
...

## 出力フォーマット

`review-result.md` を以下の構造で書く（順序固定）:

\`\`\`
# Review Result

## Summary
- verdict: 🟢 PASS / 🔴 FAIL    （critical=0 で PASS）
- 件数: critical N / warning N / info N / questions N
- 対象: 言語 / ファイル数

## Findings
重要度順 (critical → warning → info)。各 finding:
- dimension: <name>
- severity: critical / warning / info
- category: <短いタグ>
- file:line
- title: <1 行要約>
- detail: <数行説明>
- rule_reference: <参照ルールのパス>
- rule_quote: <短く中核部分の逐語引用>
- code_quote: <問題箇所の逐語引用>

## Questions
箇条書き。無ければ「なし」。
\`\`\`

verdict 判定: critical が 1 件以上 → 🔴 FAIL、0 件 → 🟢 PASS

severity 基準:
- **critical**: 確実なバグ / セキュリティ脆弱性 / データ損失 / リソースリーク / 新規実装に対応するテスト完全欠落
- **warning**: コーディングルール違反 / 層の責務逸脱 / silent failure / テスト網羅性不足
- **info**: 軽微な改善 / Tips
```

---

## Dimensions カタログ（取捨選択して使う）

`review.md` を書くときの叩き台。プロジェクト・差分の性質に応じて取捨・統合・追加する。**重複が出るなら統合する**。

### diff-bugs

- **scope**: diff の追加行 (`+`) のロジックエラーで、**コード単独で断定できる**もの。null deref / 型不一致 / off-by-one / loop 境界 / リソースリーク / 並行性 / silent failure / 例外握りつぶし
- **anti-scope**:
  - プロジェクトルールの逐語引用が必要なものは `rule-compliance`
  - 層責務の逸脱は `layer-responsibility`
  - cleanup（dead 化）は `dead-cleanup`
  - コメント rot は `comment-quality`
- **検出方法**: `git diff origin/main...HEAD` の `+` 行を関数単位で読む

### dead-cleanup

- **scope**: rename / delete に伴う dead 化。dead i18n キー / 未参照定数 / 旧スキーマ JSON / 削除済みフィールドを残すテストデータ / 未到達コード
- **anti-scope**: 元々 dead だった既存負債（差分外）は対象外。仕様変更が必要な dead は PdM 確認に回す（`## Questions` に書く）
- **検出方法**: 差分で削除されたシンボルを抽出し、残存参照を `rg` で網羅検索。`git diff origin/main...HEAD | grep -E '^-' | grep -oE '<シンボル>'` で削除分を拾い、残存を `rg <シンボル>` で確認

### comment-quality

- **scope**: WHY コメントの巻き添え削除 / 削除済みフィールドを参照する misleading コメント / proto コメント rot
- **anti-scope**: 関数の命名・責務分割は `layer-responsibility` / `diff-bugs`
- **検出方法**: 差分の `-` 行で削除されたコメント を確認し、当該コードが残存していれば WHY 喪失。残存コメントで削除済みシンボルを参照しているものを grep

### layer-responsibility

- **scope**: 層の責務逸脱。FE に BE ロジック / domain 層に SQL や HTTP / handler が usecase をスキップ / 集約境界の崩れ / 別集約への参照が ID 以外になっている
- **anti-scope**: 命名は `diff-bugs` / コメントは `comment-quality` / テスト網羅は `test-coverage`
- **検出方法**: 各層のファイルで import / 依存関係を確認。プロジェクト固有のレイヤー規約があれば `.claude/rules/` から引用

### test-coverage

- **scope**: 新規実装に対応するテスト欠落 / 削除した挙動に対するネガティブアサーション欠落 / 残存挙動の境界値テスト欠落
- **anti-scope**: テスト命名・assertion 精度のような品質は対象外
- **検出方法**: 実装ファイルとテストファイルの対応を `find` で確認。新規・大幅変更された関数 vs `_test.<ext>` の追加・更新

### rule-compliance

- **scope**: プロジェクト固有ルール (`.claude/rules/**` / コーディング規約 / ADR) との照合。各 finding は逐語引用ベース
- **適用条件**: ルールファイルが対象プロジェクトに存在するときのみ採用。無ければこの dimension は使わない
- **anti-scope**: ルールに依拠せず判断できる汎用バグは `diff-bugs` / dead は `dead-cleanup`
- **検出方法**: 適用ルールファイルを Read し、対象差分との突合を grep で確認

---

## ultracode で消費する想定

`review.md` は概ね以下の構造で Workflow に消費される:

```js
// 概念図 — 実際の Workflow はユーザが書く
const findings = await parallel(
  dimensions.map(d => () => agent(
    `${d.name}: scope=${d.scope} で diff をレビュー。anti-scope=${d.antiScope} は対象外。
     review.md の出力フォーマットに従い構造化 finding を返す`,
    { schema: FINDING_SCHEMA }
  ))
)
const verified = await parallel(
  findings.flat().map(f => () => agent(`refute: ${f.title}`, { schema: VERDICT_SCHEMA }))
)
const confirmed = verified.filter(v => v.real)
// → review-result.md
```

そのため `review.md` の dimensions が:

- 相互排他で（aggregation で dedup 不要）
- scope / anti-scope が明示で（agent が他の領域に踏み出さない）
- 出力スキーマが固定で（schema バリデーション可能）

書かれていることが重要。

---

## 観点追加 / 削除のチェックリスト

`review.md` を書き終わる前に確認:

- [ ] 各 dimension に scope と anti-scope が両方ある
- [ ] 2 つの dimension の scope が重なっていないか確認した
- [ ] 出力スキーマのフィールド名と順序が固定されている
- [ ] 差分にどの言語・どのファイルが含まれるか Scope に書いた
- [ ] 自動生成ファイル除外条件を書いた
