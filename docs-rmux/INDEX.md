# rmux: 開発者エントリポイント

Claude Code が新しいセッションで復帰したら **まずこれを読む**。ここから他のドキュメントへ誘導される。

---

## rmux とは

cmux (`manaflow-ai/cmux`) のフォーク。macOS ネイティブの Ghostty ベースターミナル上に、「**脳に優しいターミナル**」のレイヤを載せる。

中核アイデア: **Async workspace**（＝プロジェクト）ではエージェントが基本自走し、人間は定期的に開かれる **Sync session** だけ集中して対話する。Sync 以外の時間は進捗を見られず、通知もすべて抑制され、"次の Sync まで完全に忘れる" 運用を制度として強制する。

原典: `prompt.md`（28 行、日本語の短いビジョン）。

---

## 読む順（推奨）

1. **`prompt.md`** — 1 度目に読むビジョン。なぜこれを作るか
2. **`spec.md`** — 理想挙動の仕様書。4 フェーズ（preparing / syncing / self-running / awaiting-attendance）・通知ポリシー・エージェント連携・Google Calendar まで全部ここ
3. **`plan.md`** — Phase 1 MVP の実装計画（14 ステップ）と Phase 2–5 ロードマップ
4. **`CONVENTIONS.md`** — rmux 固有の規約（コード配置、用語、ローカライズ、コミット、pitfalls）
5. **`PROGRESS.md`** — いまどこまで進んでいて次に何をやるか（毎セッションで追記）
6. **`agent-state.md`** — Async workspace が cwd に書く `.cmux/state.json` の公開スキーマ

迷ったら上から順に読めば、どこからでも合流できる。

---

## 用語（短縮、詳細は `spec.md` §1.2）

| 用語 | 意味 |
| --- | --- |
| **Workspace** | cmux の既存概念。サイドバーに並ぶタブ 1 個 |
| **Normal workspace** | 現行 cmux のまま |
| **Async workspace** / Async | エージェントが基本自走、人間は時々参加 = プロジェクト |
| **Sync session** / Sync | 人間がエージェントと同期対話する時間枠 |
| **Self-running** / 自走中 | Sync と Sync の間 |
| **Awaiting attendance** / Overdue | 予定時刻は過ぎたが Sync がまだ開始されていない |
| **Preparing** / Ready to sync | Sync 開始直前、予定時間を決める画面 |
| **Planned duration** / 予定時間 | その Sync にかける時間宣言（30 分単位） |
| **Elapsed time** / 経過時間 | Sync 開始からの壁時計経過 |

UI ラベルは **英単語 `Sync` / `Async` + 日本語助詞**（`Sync 中`、`Sync を終える`、`次の Sync は X 後`）。`同期` `会議` は使わない。`自走` は自然な日本語として採用。

---

## 現在の Phase

**Phase 1 (MVP) — 「1 プロジェクトで脳に優しいサイクルが回る」**

達成条件: Async workspace を 1 個作り、 preparing → syncing → self-running → awaiting-attendance → preparing → ... の最小ループが、エージェント側（Claude Code）が各フェーズを認識している状態で成立する。

状態と次アクションは `PROGRESS.md` が一次情報源。

---

## Phase 2 以降のサマリ

- **Phase 2**: Self-running の信頼性と discipline（caffeinate / liveness 監視 / 自動再起動 / 「今すぐ Sync」フルパス手入力摩擦）
- **Phase 3**: Google Calendar 連携（Sync 予定を Google Calendar のイベントとして管理、空き時間ベースのスケジューリング）
- **Phase 4**: Sync session の密度強化 + エージェント双方向 MCP（稼働率レビュー / Permission 事前交渉 / 履歴 / 能動 push）
- **Phase 5**: 複数プロジェクト俯瞰（MenuBarExtra 拡張 / プロジェクト一覧 / カレンダービュー / Sync session 間の衝突チェック）

詳細は `plan.md` §11。

---

## 絶対に忘れないでほしいこと

- **spec を変えたら plan も見直す**。整合が崩れると後続セッションが混乱する
- **用語を勝手に直訳しない**。「同期」「会議」は禁句。`Sync` / `Async` は英単語のまま
- **ターミナルを絶対に unmount しない**。フェーズ別 UI は overlay で覆うだけ（`spec.md` §6.1）
- **Socket focus policy**: 自動でフォーカスを奪わない（cmux 既存規約、通知タップ時のみ OK）
- **ローカライズ**: user-facing string は全部 `Resources/Localizable.xcstrings` 経由で ja / en 両方
- **Reload タグ**: `rmux-<feature>`（bare `cmux DEV.app` 起動禁止 — cmux 既存規約）
- **コード識別子**: `cmux` のまま。`rmux` はドキュメントと新規ファイル / 新規キー名にだけ使う

---

## フォーク関係

- `origin` = `rtr-dnd/rmux`（開発先）
- `upstream` = `manaflow-ai/cmux`（本家）

`upstream` からの merge は `docs-rmux/` には触れないので通常無害。`CLAUDE.md` / `AGENTS.md` が上流更新された場合は、先頭の rmux ヘッダセクションを維持したままマージする（詳細は `CONVENTIONS.md`）。

---

## セッション開始時のチェックリスト

Claude Code がこの repo で新規セッションを始めるとき:

1. このファイル（`docs-rmux/INDEX.md`）を読む
2. `PROGRESS.md` の「現在の焦点」と「次の具体アクション」を確認
3. 該当する spec / plan のセクションだけピンポイントで読む（全読する必要は毎回ない）
4. 作業後は `PROGRESS.md` を更新（チェックボックスを進める、セッションログを新しい順で追記、未解決事項があれば「仕様の未解決」に書く）
