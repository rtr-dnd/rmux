# 実装進捗

**最上部に「現在の焦点」と「次の具体アクション」を置く。その下が Phase 1 チェックリスト、未解決リスト、セッションログ（新しい順で追記）。**

---

## 現在の焦点

Phase 1 Step 1–Step 8 完了。残りは HUD / 摩擦 / 通知抑制 / サイドバー / 作成 UI / ローカライズ（Step 9–14）。

実装済み（ブランチ `rmux/phase1/data-model`）:
- **データモデル** — `WorkspaceMode` / `AsyncPhase` / `AsyncPhaseTransition` / `AsyncPhaseTransitionError` + `Workspace.transition(_:reason:)` + 派生ヘルパー 4 本。
- **永続化 v2** — `SessionWorkspaceSnapshot` に Async 6 フィールド、`applyAsyncPastDueCorrection(_:now:)` で past-due 復元補正。
- **Overlay** — `ReadyToSyncOverlay` / `SelfRunningOverlay` / `OverdueOverlay` / `SyncingActionBar` を `AsyncOverlayMount`（child window + 親連動 corner mask）で mount。
- **スケジュール sheet** — `ScheduleNextSyncSheet` + `ScheduledSync` 構造体。quick-pick + 30 分粒度 DatePicker。`.reschedule` を selfRunning 起点も受け付けるように拡張。
- **Sync 終了導線** — syncing 中は右上に「Sync を終える / 次回を予定…」pill、sheet 経由で `.endSyncing`。
- **AgentStateEmitter** — `.cmux/state.json` 自動書き込み（schemaVersion 1、atomic）、`CLAUDE.async.md` を初回 Async 化で seed。`$HOME` 保護ガード。
- **SyncSessionScheduler** — singleton。`TabManager.$tabs` / `Workspace.objectWillChange` を購読し、最近接 `nextSyncAt` に単一 `DispatchSourceTimer` を arm。発火で `.markAwaitingAttendance` + macOS 通知。
- **Claude Code hook** — `.cmux/prompt-hook.sh`（bash + jq、fallback あり）+ `.claude/settings.json` の `UserPromptSubmit` に idempotent merge。既存 user hook を保持。
- ツール: `scripts/add-swift-file.sh` で新規 Swift ファイルを `project.pbxproj` に登録。
- 単体テスト: `AsyncPhaseTransitionTests`(33) + `AsyncWorkspacePersistenceTests`(8) + `AgentStateEmitterTests`(11) = **52 ケース、全 pass**。

---

## 次の具体アクション

**`plan.md` §8 Step 9 — 経過時間 HUD** に着手。

1. 現状 `SyncingActionBar` はボタンのみ。ここに `TimelineView(.periodic(from: .now, by: 1))` で `HH:MM:SS / 予定 HH:MM:SS` を追加。
2. `syncOverrun > 0` のとき、数字を赤化＋約 1 Hz の点滅アニメーション。超過時間も併記（`+HH:MM:SS`）。
3. HUD を非表示にするトグルは作らない（spec §6.1.4 方針）。
4. `AsyncOverlayMount` の syncing 時の pill サイズを HUD の幅に合わせて調整。
5. 見た目の確認を tagged launch + `debug.rmux.cycle_async_phase` で行う。

---

## Phase 1 ステップ進捗（plan.md §8）

- [x] 1. データモデル（`WorkspaceMode` / `AsyncPhase` / 新規 `@Published` / 遷移集約メソッド + 32 unit tests）
- [x] 2. 永続化 v1→v2（`SessionWorkspaceSnapshot` 拡張、past-due 復元ハンドリング + 8 unit tests）
- [x] 3. overlay の殻（child window + portal 回避 + 親窓連動 corner mask）
- [x] 4. スケジュール設定モーダル（quick-pick + DatePicker、衝突チェック無し）
- [x] 5. Sync を終える導線（syncing 中は右上に pill）
- [x] 6. `AgentStateEmitter`（`.cmux/state.json` + `CLAUDE.async.md` + $HOME ガード + 11 unit tests）
- [x] 7. SyncSessionScheduler（最近接 `nextSyncAt` の単一 DispatchSourceTimer + macOS 通知）
- [x] 8. Claude Code hook 配布（`.cmux/prompt-hook.sh` + `.claude/settings.json` idempotent merge）
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

### 2026-04-24 (Phase 1 Step 3–8 実装)
- **Step 3**: 3 つの overlay (`ReadyToSyncOverlay` / `SelfRunningOverlay` / `OverdueOverlay`) を新設。cmux のターミナル portal が SwiftUI ZStack の上に描画される問題を回避するため、`AsyncOverlayMount` 経由で **親ウィンドウに結び付けた子 NSWindow** に `NSHostingView` を載せる方式に落とし着く。親ウィンドウと連動した bottom-corner mask、サイドバー有無による左下 corner の出し分けを実装。Debug メニュー + ⌃⌥⌘P + socket 経由 (`debug.rmux.cycle_async_phase`) の 3 経路でフェーズ循環。
- **Step 4**: `ScheduleNextSyncSheet` + `ScheduledSync` 構造体（Phase 3 で `calendarEventId` を生やすため値型に）。quick-pick（1h/3h/6h、7 日以内の 09:00/18:00）+ 30 分粒度 DatePicker。`.reschedule` transition を selfRunning 起点も受け付けるよう拡張 + 対応テスト追加。
- **Step 5**: syncing 時は `SyncingActionBar` pill（右上、全 4 角丸）を表示。クリックで `ScheduleNextSyncSheet` → `.endSyncing`。
- **Step 6**: `AgentStateEmitter` が Workspace.transition ごとに `.cmux/state.json` を atomic write。初回 Async 化時に `CLAUDE.async.md` をシード。$HOME cwd は安全のため書き込みスキップ（テスト汚染防止）。`AgentStateEmitterTests` 7 ケース pass。
- **Step 7**: `SyncSessionScheduler` singleton。AppDelegate.createMainWindow で TabManager を register。`TabManager.$tabs` + `Workspace.objectWillChange` を購読し最近接 `selfRunning.nextSyncAt` に単一 `DispatchSourceTimer` を arm。発火で `.markAwaitingAttendance` + `UNUserNotificationCenter` 通知（タイトル「Sync の時間です」）。
- **Step 8**: `.cmux/prompt-hook.sh`（bash + jq、jq 欠落時の fallback 付き）を実行権限付きで生成。`.claude/settings.json` の `hooks.UserPromptSubmit` に冪等 merge（既存の user hook を保持、rmux 自身の重複は検出してスキップ）。`AgentStateEmitterTests` に 4 ケース追加。
- Commits (順): `3daa937c` (pill) → `2d738217` (emitter) → `f87e23c1` (scheduler) → `fd28468b` (hook)、直前の `a8384b3d` (sheet) と `d3a5f220` (overlay mount) を含め 6 本。
- 全テスト: `AsyncPhaseTransitionTests`(33) + `AsyncWorkspacePersistenceTests`(8) + `AgentStateEmitterTests`(11) = 52 ケース、全 pass。

### 2026-04-23 (Phase 1 Step 2 実装 + Sources/Async/ リファクタ + pbxproj ツール)
- Step 2（永続化 v1→v2）: `SessionSnapshotSchema.currentVersion` を 2 に上げ、`supportedVersions = 1...2` を導入。`SessionWorkspaceSnapshot` に Async optional 6 フィールドを追加。`applyAsyncPastDueCorrection(_:now:)` が selfRunning + 過去 `nextSyncAt` を awaitingAttendance に書き換える。`Workspace.sessionSnapshot(...)` / `restoreSessionSnapshot(_:)` が Async 状態を往復。
- `AsyncWorkspacePersistenceTests`（8 ケース）を追加。全 pass。
- ツール: `scripts/add-swift-file.sh` + `.rb` を新設し、Homebrew cocoapods 同梱の `xcodeproj` Ruby gem 経由で `project.pbxproj` に新規 Swift ファイルを安全に登録できるようにした。CONVENTIONS.md §2 に手順を追記し、手編集禁止を明文化。
- Async 型を `Sources/Async/AsyncPhase.swift` と `Sources/Async/Workspace+AsyncPhase.swift` に分離。`@Published private(set)` は Swift の file-scope 制約で extension を別ファイルに出せないため、`private(set)` を外してコメント + テスト規約で保護（CONVENTIONS.md §2 に記載）。
- Commits: `f7e3e42f`（Sources/Async/ split）、`adf6dae4`（add-swift-file 導入）、`e06e01cc`（schema v2）。

### 2026-04-23 (Phase 1 Step 1 実装)
- Branch `rmux/phase1/data-model` を `ritar/rmux-docs` から分岐
- `Sources/Workspace.swift` に Async 関連の型定義（`WorkspaceMode` / `AsyncPhase` / `AsyncPhaseTransition` / `AsyncPhaseTransitionError`）、`Workspace` クラスへの `@Published private(set)` 状態フィールド 6 本、遷移集約メソッド `transition(_:reason:)`、派生ヘルパー 4 本を追加（+238 行）
- `cmuxTests/WorkspaceUnitTests.swift` に `AsyncPhaseTransitionTests`（32 ケース、+344 行）を追記。新規ファイル作成は project.pbxproj 編集を避けるため既存ファイルに統合
- `.claude/settings.local.json` の許可パターンを整備（中途 glob を廃し、プレフィックス + `:*` 形式で書き直し）。`git push:*` は deny、PR 作成・push は人間が行う運用に合意
- Commits: `0c41da2c`（data model）、`e63f6462`（unit tests）。`xcodebuild` での cmux フルビルド成功、`cmux-unit` scheme の対象テスト 32/32 pass

### 2026-04-23 (設計 + ハーネス整備)
- `docs-rmux/prompt.md`（原典ビジョン）を起点に、仕様と実装計画を構築。
- `spec.md` 作成: Normal / Async の 2 タイプ、Async の 4 フェーズ（preparing / syncing / self-running / awaiting-attendance）、用語（`Sync` / `Async` + 自走、同期/会議は不使用）、通知ポリシー（self-running 中の完全抑制）、経過時間 HUD（超過赤点滅）、「今すぐ Sync」の摩擦設計、Google Calendar 連携、エージェント連携（§7）。
- エージェント連携方式は初期案の **PTY stdin 注入を棄却**（Claude Code の TUI 常駐によるタイミング / 意味論リスクのため）。代わりに `.cmux/state.json` + 環境変数 + **Claude Code `UserPromptSubmit` hook** で決定。能動 push が要る機能は Phase 4 の MCP に回す。
- `plan.md` 作成: Phase 1 MVP の 14 ステップ + Phase 2–5 のロードマップ。Phase 1 ゴールは「1 プロジェクトで脳に優しいサイクルが回る」。衝突チェックを Phase 5 に、フルパス手入力摩擦を Phase 2 に送り、エージェント連携を MVP に含めた。
- ハーネス整備: `CLAUDE.md` に rmux ヘッダ追加、`docs-rmux/INDEX.md` / `CONVENTIONS.md` / `PROGRESS.md` / `agent-state.md` を新設。
- 次回は Phase 1 Step 1（データモデル）から着手。
