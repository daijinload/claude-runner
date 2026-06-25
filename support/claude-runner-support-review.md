# レビュー観点テンプレ（claude-runner-support）

このファイルは `claude-runner-support.sh plan` の対話で参照される **観点テンプレ** のサンプル。plan の壁打ちで claude がここを読み、プロジェクトに合わせた `review.md` を workdir に生成する。

process 版（`process/claude-runner-process-review.md`）と違い、support 版では **1 セッションで全観点をまとめて見る** 想定。1 ファイル (`review-result.md`) に結果を書き出すので、観点を箇条書きで並べる構造にしている。

## 厳守事項

- **一切の推測を許さない。** 詳細に調査し、全ての指摘は明確な裏付け（コード逐語引用 + ルール逐語引用）まで確認する。
- **修正・コミット・push は禁止**（read-only）。発見だけして `review-result.md` に書く。
- **質問は会話に出さず、出力ファイルの `## Questions` セクションに全て集約**する。
- **grep/rg 系の確認は必ずシェルで実行**してシステム的に網羅確認する。

## レビュー対象差分

- `git diff origin/main...HEAD`（origin/main 分岐後の全コミット）
- + uncommitted 変更（`git diff` / `git status` で検出される未コミット分も含める）

差分が大きい場合は `git diff --stat` でファイル一覧 → 該当ファイル単位で `git diff` を見る。

## 観点（plan で取捨選択）

plan の壁打ちで、これらから対象プロジェクト・対象差分に合うものを選んで `review.md` の `## 観点` セクションに転記する（全部入れる必要はない）。

### code-quality
- 命名: 関数 / 変数 / 型が役割を表しているか
- 責務: 1 関数 / 1 ファイルの責務が肥大していないか
- エラーハンドリング: silent failure / catch して握りつぶしがないか

### dead-code
- 削除した参照に対して dead な定数・i18n キー・テストデータが残っていないか

### duplicate-code
- 同じロジックが複数ファイルにコピペされていないか

### コメント品質
- WHY コメントの巻き添え削除がないか
- 削除済みフィールドを参照する古いコメント (misleading) が残っていないか

### テスト網羅性
- 新規実装に対応するテストの欠落
- 削除した挙動に対するネガティブアサーション欠落

## 出力フォーマット

`review-result.md` を以下の構成で書く:

```
# Review Result

## Summary
- verdict: 🟢 PASS / 🔴 FAIL
- 件数: critical N / warning N / info N
- 対象: <言語・ファイル数>

## Findings
重要度順 (critical → warning → info)。各 finding:
- severity / category / file:line / title
- detail
- 根拠ルール（参照したルール / ガイドラインの位置）
- 根拠引用（短く中核部分）
- コード引用（問題箇所の逐語引用）

## Questions
途中で確認したいことを箇条書きで全て書く。無ければ「なし」。
```

verdict 判定:
- critical が 1 件以上 → 🔴 **FAIL**
- 0 件 → 🟢 **PASS**

severity 判定基準:
- **critical**: 確実なバグ / セキュリティ脆弱性 / データ損失リスク / リソースリーク / 新規実装ファイルに対応するテストファイル完全欠落
- **warning**: コーディングルール違反 / 層の責務逸脱 / エラーハンドリング不備 / テスト網羅性不足
- **info**: 軽微な改善 / Tips
