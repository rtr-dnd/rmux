# 実装進捗

**最上部に「現在の焦点」と「次の具体アクション」を置く。その下が Phase 1 チェックリスト、未解決リスト、セッションログ（新しい順で追記）。**

---

## 現在の焦点

**Phase 1 (MVP) + Phase 1.5 (agent state + cwd 配布物の切り詰め) 完了。** rmux が cwd に置くファイルは `.claude/settings.local.json` のみ（gitignored）、それ以外は `$HOME` 配下。プロジェクトツリーに `CLAUDE.async.md` や `.cmux/` は置かない方針を確定。

実装済み（ブランチ `rmux/phase1/data-model`）:
- **データモデル** — `WorkspaceMode` / `AsyncPhase` / `AsyncPhaseTransition` / `AsyncPhaseTransitionError` + `Workspace.transition(_:reason:)` + 派生ヘルパー 4 本。
- **永続化 v2** — `SessionWorkspaceSnapshot` に Async 6 フィールド、`applyAsyncPastDueCorrection(_:now:)` で past-due 復元補正。
- **Overlay** — `ReadyToSyncOverlay` / `SelfRunningOverlay` / `OverdueOverlay` / `SyncingActionBar` を `AsyncOverlayMount`（child window + 親連動 corner mask）で mount。
- **スケジュール sheet** — `ScheduleNextSyncSheet` + `ScheduledSync` 構造体。quick-pick + 30 分粒度 DatePicker。`.reschedule` を selfRunning 起点も受け付けるように拡張。
- **Sync 終了導線** — syncing 中は右上に「Sync を終える / 次回を予定…」pill、sheet 経由で `.endSyncing`。
- **AgentStateEmitter** — `.cmux/state.json` 自動書き込み（schemaVersion 1、atomic）、`CLAUDE.async.md` を初回 Async 化で seed。`$HOME` 保護ガード。
- **SyncSessionScheduler** — singleton。`TabManager.$tabs` / `Workspace.objectWillChange` を購読し、最近接 `nextSyncAt` に単一 `DispatchSourceTimer` を arm。発火で `.markAwaitingAttendance` + macOS 通知。
- **Claude Code hook** — `.cmux/prompt-hook.sh`（bash + jq、fallback あり）+ `.claude/settings.json` の `UserPromptSubmit` に idempotent merge。既存 user hook を保持。
- **新規 Async workspace 作成 UI** — `NewAsyncWorkspaceFlow`（`Sources/Async/NewAsyncWorkspaceFlow.swift`）が File メニュー + Command Palette に「今すぐ Sync」「後で Sync…」の 2 動線を追加。後者は `ScheduleNextSyncSheet` をモーダル（親があれば sheet、無ければ独立 window）で提示し、確定で `.convertToAsync(initialPhase: .selfRunning, ...)`。
- **ローカライズ** — `async.*` / `menu.file.newAsyncWorkspace*` / `command.newAsyncWorkspace*` の全 34 キーを `Resources/Localizable.xcstrings` に en/ja で投入。コード側はすべて `String(localized: "key", defaultValue: "English")` に揃え、doc コメントを除くソース中の生 Japanese 文字列をゼロに。
- ツール: `scripts/add-swift-file.sh` で新規 Swift ファイルを `project.pbxproj` に登録。
- **Phase 1.5: agent state path + cwd 配布物の削ぎ落とし** — state.json を **workspace identity** に紐づけて `~/Library/Application Support/<bundleId>/workspaces/<workspaceId>/state.json` に書く。`Sources/Async/AgentStatePaths.swift` で path を一元管理 (テスト用に override 可能)。`prompt-hook.sh` は `~/.cmux/` の global 1 本。hook 登録は `.claude/settings.local.json`（gitignored）に切り替え — `settings.json`（team-shared、git 追跡）は触らない。`CMUX_STATE_FILE` env を全ターミナルに常時注入 (`Sources/GhosttyTerminalView.swift`)。`CLAUDE.async.md` の cwd 配布は廃止（per-turn hook で operating notes は完結、`docs-rmux/agent-state.md` がより詳細なリファレンス）。プロジェクトに残る rmux 痕跡は `.claude/settings.local.json` のみ。
- 単体テスト: `AsyncPhaseTransitionTests`(33) + `AsyncWorkspacePersistenceTests`(8) + `AgentStateEmitterTests`(12、Phase 1.5 で -1: `CLAUDE.async.md` 関連 2 本削除 + 「プロジェクトに rmux 書き込み物ゼロ」確認 1 本追加) = **53 ケース、全 pass**。

---

## 次の具体アクション

**Phase 1 MVP はコード上完了。** 次の候補:

1. **実機回帰** — File / Command Palette から「今すぐ Sync」「後で Sync…」を実行し、4 フェーズが期待通り回るか手動確認。日本語 UI と英語 UI の両方で目視。
2. **Phase 2 着手** — `plan.md` §9 以降。優先度の目安:
   - 「今すぐ Sync」でフルパス手入力による強摩擦（spec §6.1.6）
   - `awaitingAttendance` 放置時のリマインド通知頻度ポリシー
   - `ScheduleNextSyncSheet` に複数 Async workspace 間の衝突検出
3. **未解決リスト洗い出し** — 下の「仕様の未解決 / 揺れ」に残っている項目を拾い、決着する分は spec/plan に昇格。

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
- [x] 9. 経過時間 HUD（syncing pill、HH:MM:SS 形式、超過時 1 Hz blinking 赤）
- [x] 10. 「今すぐ Sync」確認ダイアログ（SwiftUI .alert で yes/no）
- [x] 11. 通知抑制（`TerminalNotificationStore.addNotification` で selfRunning/awaitingAttendance を early return）
- [x] 12. サイドバー行表示（TabItemView に precomputed 文字列バッジ、Equatable 維持）
- [x] 13. 新規 Async workspace 作成 UI（File メニュー + Command Palette に「今すぐ Sync」「後で Sync…」の 2 動線）
- [x] 14. ローカライズ（ja / en、`async.*` 34 キーを `Localizable.xcstrings` に投入）

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

### 2026-04-24 (ユーザフィードバック対応: Normal 退避 / 10分猶予 / Close→Revert)
- **Feedback 1 (syncing → Normal 直行)**: `SyncingActionBar` pill に「Normal に戻す」ボタンを追加（`bordered` スタイル、pill 幅を 400→520）。新 transition `.endSyncingAndRevert(at:)` を `AsyncPhaseTransition` に足し、`Workspace+AsyncPhase` で実装（syncing 限定、`lastSyncEndedAt = at` 更新、mode=.normal + async 状態 clear）。確認 alert 付き。ローカライズ 4 キー追加。単体テスト 2 本追加。
- **Feedback 2 (Overdue 10 分猶予)**: 仕様を書き換え — `selfRunning.nextSyncAt` 到達で直接 `awaitingAttendance` にせず、まず `preparing` へ（新 transition `.scheduledSyncArrived(at:)`）。`preparing` のまま 10 分経過で `awaitingAttendance` にエスカレート（`.markAwaitingAttendance` の source guard を `.selfRunning || .preparing` に拡張）。`SyncSessionScheduler` を二種類の pending fire（arrival / escalation）に対応、armed `PendingFireKind` を保持する形にリファクタ。エスカレーションは silent（到達時点で通知済み、二重通知を避ける）。`SessionPersistenceStore.applyAsyncPastDueCorrection` も同じ 10 分ルールで補正するよう更新。spec.md §3 / §3.1 / §4.6 / §4.7 / §5.1 / §8.1 を新セマンティクスに書き換え。
- **Feedback 3 (workspace 閉じ → Normal 化)**: `TabManager.closeWorkspace` の冒頭で Async workspace なら `revertToNormal` を呼び、その後 `AgentStateEmitter.discardState` で per-workspace state.json を削除。session persistence には normal として保存されるので再起動で Async のまま甦らない。ウィンドウ閉じは workspace 保持のまま（session 復元可能）のため特別処理なし。新単体テスト 1 本。
- **テスト結果**: AgentStateEmitterTests / AsyncPhaseTransitionTests / AsyncWorkspacePersistenceTests / SessionPersistenceTests 全 115 ケース pass（新 5 ケース: `testEndSyncingAndRevert*` ×2 / `testScheduledSyncArrived*` ×2 / `testMarkAwaitingAttendanceFromPreparing*` / `testClosingAsyncWorkspaceReverts*` / `testPastDue{Within,Beyond}Grace*` に差し替え）。

### 2026-04-24 (Phase 1.5 追加 — cwd tracking を常時アクティブに)
- **発見**: ユーザが `~/dev/arata-nakayama-website/` で作業中の workspace から「今すぐ Sync」→ 新 Async workspace が inherited cwd=arata-nakayama で作られ、そこに hook install → ターミナルで `cd ~/dev/loris-front/` しても hook が追従しない。
- **原因**: `armCwdRetryIfNeeded` が初回 transition 時に「cwd が empty / $HOME だったときだけ」sink を張る設計。inherited cwd が既に非 $HOME の場合は sink 未装着で、その後の cd 操作を検知できなかった。
- **修正**: `installCwdTracking`（旧 `armCwdRetryIfNeeded`）に改名し、convertToAsync 時に **常に** `$currentDirectory.dropFirst()` sink を装着。`.async` ライフタイム中は継続的に cwd 変化を追跡し、非 $HOME な cwd になるたびに `ensureClaudeCodeHook` + `writeState` を再実行。`revertToNormal` で subscription cancel。`settings.local.json` への write は idempotent なので、同じ cwd に戻ってきても no-op。
- **新テスト**: `testHookFollowsCwdChange` — workspace を project-a で convertToAsync → project-a/.claude/settings.local.json ができる → workspace.currentDirectory を project-b に変更 → XCTestExpectation + async loop で project-b/.claude/settings.local.json が書かれるのを最大 1 秒待機。AgentStateEmitterTests 13/13 pass。
- **手動アンブロック**: `~/dev/loris-front/.claude/settings.local.json` には現行ユーザ作業のため手動で hook entry を merge 済み（`permissions` 配列は保持）。

### 2026-04-24 (Phase 1.5 追加 — プロジェクト cwd への書き込みを最小化)
- **方針確定**: rmux は「人間とエージェントの対話作法」を実現する個人ツール。プロジェクトメンバー全員がこの作法に従う必要はない → rmux が書き込むファイルは **1 個たりとも git 管理下に入ってはいけない**。
- **`CLAUDE.async.md` 廃止**: `AgentStateEmitter.ensureTemplate(for:)` を削除、`asyncAgentTemplateContent` 本体と Workspace+AsyncPhase 両箇所の呼び出しを除去。operating notes は per-turn hook 出力（`[cmux] phase=...` + 行動ガイダンス）で完結。fuller doc が要るエージェントは `docs-rmux/agent-state.md` を参照。
- **hook 登録先を `.claude/settings.json` → `.claude/settings.local.json` に変更**: 前者は team-shared / git 追跡、ユーザ絶対パスを含む hook entry を置くと他人の環境で壊れる。後者は Claude Code の慣習で個人用 (gitignored)。`mergeClaudeSettings` の target path 変更のみ、マージロジック / 冪等チェック / 既存 user hook の保全は共通。
- **テスト**: `testEnsureTemplate*` 2 本削除、`testConvertToAsyncDoesNotPlantAnyFilesInProjectTree`（CLAUDE.md / CLAUDE.async.md / .cmux/ / settings.json が全部存在しないことを確認）を新設。`testConvertToAsyncMergesLocalSettingsPointingAtGlobalHook` は settings.local.json 先のアサートに更新 & settings.json が作られていないことも検証。12 ケース全 pass。
- **docs 更新**: `spec.md §7.2` に「大前提: rmux が書き込むものは一切 git 管理下に入らない」を明文化。`§7.3.1` と `§7.4` と `agent-state.md §2.3` を settings.local.json 前提に書き換え、`CLAUDE.async.md` 関連記述を削除。`CONVENTIONS.md §1 / §2` の古い `CLAUDE.async.md` / `Resources/AgentTemplates/` 言及を訂正。
- **テストリポジトリ cleanup**: `~/dev/ritar-portfolio-v2/CLAUDE.async.md` を削除（legacy 配布物）。

### 2026-04-24 (Phase 1.5 — agent state を workspace identity に変更)
- **発見**: 「今すぐ Sync」で新規 workspace 作って Claude を立ち上げたら、Claude が「自分は Async/self-running モード」と誤認。原因は `<cwd>/.cmux/state.json` が前セッションの stale データ (workspaceId が違う、phase が selfRunning 固定)、新 workspace の `currentDirectory` が空文字列だった瞬間に `writeState` が早期 return していたため上書きされず。
- **設計判断**: 「state.json を cwd に置く」前提自体が誤り。同じ cwd で複数 Async workspace を立てる、Normal と Async が混在する、過去 workspace を削除した後に同じ cwd を再利用する — どのケースでも壊れる。Identity を **workspace** に切り替え、発見メカニズムを **`CMUX_STATE_FILE` env var** に。
- **新パス**: `~/Library/Application Support/<bundleId>/workspaces/<workspaceId>/state.json`。`Sources/Async/AgentStatePaths.swift` を新設 (`scripts/add-swift-file.sh` で pbxproj 登録)、`stateRoot` / `globalHookDir` を static var にしてテスト時に override 可能。
- **AgentStateEmitter**: cwd 依存をやめて workspaceId キーで write。`$HOME` 安全ガードは template/settings 系の cwd-bound 関数だけに残す (state file は app support なので不要)。`discardState(forWorkspaceId:)` を追加 (将来の orphan sweep 用)。
- **Hook script**: `<cwd>/.cmux/prompt-hook.sh` を全廃し、`~/.cmux/prompt-hook.sh` の **global 1 本** に。`.claude/settings.json` は cwd 単位 (Claude Code 側の制約) のままその global path を登録。冪等マージは「グローバル絶対パスとの完全一致」で判定 (legacy `<cwd>/.cmux/prompt-hook.sh` エントリは敢えてマッチさせない — old build と並走する場合に both 入って良い、次回 cleanup で潰せる)。
- **Hook 内容**: `${CMUX_STATE_FILE:-.cmux/state.json}` の cwd fallback を撤去。`$CMUX_STATE_FILE` 未設定 / 不在 → 何も出力せず exit 0。Normal workspace でも CMUX_STATE_FILE は常に export するが、ファイルが無いので無害。
- **Env 注入**: `Sources/GhosttyTerminalView.swift:4421` の `CMUX_WORKSPACE_ID` の隣に `CMUX_STATE_FILE` を追加 (常時設定、Normal workspace でも入れる)。
- **CLAUDE.async.md**: cwd 配下のまま据え置き (人間が読み書きするドキュメントなので)。
- **テスト**: `AgentStateEmitterTests` 全面書き直し (per-workspace path / global hook dir を tempRoot に override)。新規ケース: 同 cwd の 2 workspace が独立した state file を持つ、`discardState` がディレクトリごと消す。13 ケース全 pass。
- **Docs**: `spec.md §7.2` / `§7.3.1` と `agent-state.md §1–§2/§5/§8` を新設計に書き換え (latest-only、変更経緯は残さない)。
- **既知の残務**: 既存プロジェクトに残っている `<cwd>/.cmux/state.json` と `<cwd>/.cmux/prompt-hook.sh` (旧 layout の遺物) は手動削除推奨。`.claude/settings.json` の旧エントリは hook が CMUX_STATE_FILE を読まないので無害だが、整理したければユーザが削除。orphan sweep の自動化は別途。

### 2026-04-24 (Phase 1 Step 13–14 実装 — MVP 完了)
- **Step 13**: `Sources/Async/NewAsyncWorkspaceFlow.swift` を新設（`scripts/add-swift-file.sh` 経由で pbxproj 登録）。`createNow(debugSource:)` は `addWorkspaceInPreferredMainWindow` → `.convertToAsync(.preparing, nil)`、`createLater(debugSource:)` は内部クラス `ScheduleNextSyncSheetPresenter` で `ScheduleNextSyncSheet` を親ありなら `beginSheet`、無ければ独立 window で提示し、確定で `.convertToAsync(.selfRunning, <selected>)`。File メニューの「New Workspace」直後に 2 エントリを追加。Command Palette にも 2 コマンド (`palette.newAsyncWorkspace{Now,Later}`) を追加。
- **Step 14**: Async UI 全域を `String(localized: "key", defaultValue: "English")` に置換。`Resources/Localizable.xcstrings` に 34 キー (`async.common.*` / `async.badge.*` / `async.readyToSync.*` / `async.selfRunning.*` / `async.overdue.*` / `async.syncing.*` / `async.schedule.*` / `async.notification.*` + Step 13 で追加した menu/command) を en+ja で投入。`nextSyncCountdown` / `overdue.title` / `syncing.plannedSuffix` は `%@` 形式に整え、`TimelineView` 内でフォーマット済み文字列を引数に渡す形。doc コメント内の Japanese は残置（コード側は literal 0 を確認）。
- xcodebuild Debug 成功（既存の Swift 6 concurrency 警告のみ）。
- Commits (予定): 本セッションで `rmux/phase1/data-model` ブランチ上に 1–2 本、ユーザ確認後に PR。

### 2026-04-24 (Phase 1 Step 9–12 実装)
- **Step 9**: `SyncingActionBar` に経過時間 HUD。`TimelineView(.periodic(from: .now, by: 1))` で秒粒度更新、`HH:MM:SS / 予定 HH:MM:SS` 表示、超過時は赤字 + 1 Hz blink (opacity 1.0↔0.45) + `(+HH:MM:SS)` 併記。Pill 幅を 280→400。
- **Step 10**: `SelfRunningOverlay` の「今すぐ Sync」に SwiftUI `.alert` の確認ダイアログ。フルパス手入力の強摩擦は Phase 2 (spec §6.1.6) へ継続。
- **Step 11**: `TerminalNotificationStore.addNotification(...)` の頭にガードを挿入。owner workspace が Async かつ phase が selfRunning/awaitingAttendance の場合 early return（サイドバー・MenuBar・panel・OS 通知・音を全部抑制）。stash→flush は TODO として残置（spec §5.3 / §5.4）。
- **Step 12**: `TabItemView` に `asyncPhaseBadge: String?` を追加。`Equatable` に含めつつ、時刻系フィールドは含めず coarse に保つ。badge 文字列は preparing→Ready / syncing→Sync 中 / selfRunning→自走 / awaitingAttendance→Overdue。
- **Scheduler 修正**: 主 TabManager は `cmuxApp.swift` の `StateObject` で生成されていて `AppDelegate.createMainWindow` を通らず、Scheduler が初期 window の workspaces を認識していなかった。`AppDelegate.configure(...)` でも register するように修正。Debug 動線も syncing/preparing から arm できるよう拡張。
- macOS 通知の OS 側表示は別問題（Focus mode / 通知許可）。Scheduler の post path は成功 log を確認済み。
- Commits: `9f14b4f4`（scheduler register fix）、`7a323fd7`（Step 9+10+11）、`42bcc1a9`（Step 12）。

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
