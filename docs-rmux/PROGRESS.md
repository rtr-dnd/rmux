# 実装進捗

**最上部に「現在の焦点」と「次の具体アクション」を置く。その下が Phase 1 チェックリスト、未解決リスト、セッションログ（新しい順で追記）。**

---

## 現在の焦点

Phase 1 の設計（spec.md / plan.md）が固まり、ハーネス（INDEX.md / CONVENTIONS.md / 本書 / agent-state.md）を整備した段階。**コード実装はこれから着手**。

---

## 次の具体アクション

**`plan.md` §8 Step 1 — データモデルの追加** から始める。

1. `Sources/Workspace.swift` に以下を追加:
   - `enum WorkspaceMode: String, Codable { case normal, async }`
   - `enum AsyncPhase: String, Codable { case preparing, syncing, selfRunning, awaitingAttendance }`
   - `@Published var mode: WorkspaceMode = .normal`
   - `@Published var asyncPhase: AsyncPhase? = nil`
   - `@Published var nextSyncAt: Date? = nil`
   - `@Published var syncStartedAt: Date? = nil`
   - `@Published var plannedDuration: TimeInterval? = nil`
   - `@Published var lastSyncEndedAt: Date? = nil`
2. 遷移集約メソッド `func transition(to newPhase: AsyncPhase, reason: String)` を生やす（不変条件バリデーション、`plan.md` §2.2）
3. `var remainingUntilSync / overdueDuration / elapsedSinceSyncStart / syncOverrun` の computed property を追加（`plan.md` §2.3）
4. ビルド確認: `./scripts/reload.sh --tag rmux-async-data-model`
5. UI には何も出ない状態でビルドが通ればこのステップは完了

このステップでは永続化も UI もまだ触らない（ステップ 2, 3 で別途）。

---

## Phase 1 ステップ進捗（plan.md §8）

- [ ] 1. データモデル（`WorkspaceMode` / `AsyncPhase` / 新規 `@Published` / 遷移集約メソッド）
- [ ] 2. 永続化 v1→v2（`SessionWorkspaceSnapshot` 拡張、past-due 復元ハンドリング）
- [ ] 3. Preparing / Self-running / Awaiting overlay の殻（文言とボタンだけ、ZStack 組み込み、dev ショートカットで各フェーズにセット）
- [ ] 4. スケジュール設定モーダル（§6.7、衝突チェックなし）
- [ ] 5. Sync を終える導線（syncing 中だけ出るボタン → モーダル → self-running）
- [ ] 6. `AgentStateEmitter`（環境変数 + state.json + `CLAUDE.async.md` 配布。hook はまだ）
- [ ] 7. SyncSessionScheduler（最近接 `nextSyncAt` のタイマー + macOS 通知）
- [ ] 8. Claude Code hook 配布（`.claude/settings.json` マージ + `.cmux/prompt-hook.sh`）
- [ ] 9. 経過時間 HUD（syncing pill、超過赤点滅）
- [ ] 10. 「今すぐ Sync」確認ダイアログ（yes/no 1 枚）
- [ ] 11. 通知抑制（`TerminalNotificationStore` ゲート）
- [ ] 12. サイドバー行表示（`TabItemView`、Equatable 注意）
- [ ] 13. 新規 Async workspace 作成 UI（Normal / Async + 今すぐ / 後で）
- [ ] 14. ローカライズ（ja / en）

各ステップ完了時に上記チェックを埋め、セッションログに 1–2 行で記録する。

---

## 仕様の未解決 / 揺れ

（発見次第ここに追記。決着したら `spec.md` に昇格させて当該項目を削除。）

- **`preparing` のキャンセル時の「前のフェーズ」保持**: plan.md §10 で指摘。簡易ルール（self-running なら self-running に、awaiting なら awaiting に戻す）で足りる想定だが、実装時に再確認
- **`Overdue` の日本語 UI**: 現状そのまま英字。実機で見て違和感があれば `開始待ち` 等に差し替える判断が要る
- **Hook スクリプトの `jq` 未インストール時 fallback**: plan.md §5.3.4 で触れているが具体的な最低出力形式を決めていない
- **テキスト注入のタイミング（削除済）**: Hook アプローチに切り替えたので解消
- **`.cmux/state.json` の書き込み競合**: 複数 rmux プロセス / tagged ビルドで同じ cwd を触るケース。MVP は単一プロセス想定でいいが、どこまで防御するか
- **`awaiting-attendance` 長時間放置後の macOS 通知リマインド**: spec §5.1 に「追加のリマインド通知（頻度はロードマップ）」とだけあり具体決めていない

---

## セッションログ

新しいものを上に追記。

### 2026-04-23 (設計 + ハーネス整備)
- `docs-rmux/prompt.md`（原典ビジョン）を起点に、仕様と実装計画を構築。
- `spec.md` 作成: Normal / Async の 2 タイプ、Async の 4 フェーズ（preparing / syncing / self-running / awaiting-attendance）、用語（`Sync` / `Async` + 自走、同期/会議は不使用）、通知ポリシー（self-running 中の完全抑制）、経過時間 HUD（超過赤点滅）、「今すぐ Sync」の摩擦設計、Google Calendar 連携、エージェント連携（§7）。
- エージェント連携方式は初期案の **PTY stdin 注入を棄却**（Claude Code の TUI 常駐によるタイミング / 意味論リスクのため）。代わりに `.cmux/state.json` + 環境変数 + **Claude Code `UserPromptSubmit` hook** で決定。能動 push が要る機能は Phase 4 の MCP に回す。
- `plan.md` 作成: Phase 1 MVP の 14 ステップ + Phase 2–5 のロードマップ。Phase 1 ゴールは「1 プロジェクトで脳に優しいサイクルが回る」。衝突チェックを Phase 5 に、フルパス手入力摩擦を Phase 2 に送り、エージェント連携を MVP に含めた。
- ハーネス整備: `CLAUDE.md` に rmux ヘッダ追加、`docs-rmux/INDEX.md` / `CONVENTIONS.md` / `PROGRESS.md` / `agent-state.md` を新設。
- 次回は Phase 1 Step 1（データモデル）から着手。
