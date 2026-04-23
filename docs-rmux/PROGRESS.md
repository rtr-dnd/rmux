# 実装進捗

**最上部に「現在の焦点」と「次の具体アクション」を置く。その下が Phase 1 チェックリスト、未解決リスト、セッションログ（新しい順で追記）。**

---

## 現在の焦点

Phase 1 Step 1（データモデル）と Step 2（永続化 v1→v2）が完了。Step 3（overlay の殻 + WorkspaceContentView の ZStack 組み込み）に移る直前。

実装済み（ブランチ `rmux/phase1/data-model`）:
- トップレベル enum / transition（`Sources/Async/AsyncPhase.swift`）+ extension（`Sources/Async/Workspace+AsyncPhase.swift`）
- `Workspace` に Async 状態フィールド 6 本（`@Published var`、ミューテーションは `transition(_:reason:)` 経由と規約で強制）
- 派生ヘルパー `remainingUntilSync` / `overdueDuration` / `elapsedSinceSyncStart` / `syncOverrun`
- 永続化 schema v2（`SessionSnapshotSchema.currentVersion = 2`, `supportedVersions = 1...2`）、`SessionWorkspaceSnapshot` に Async optional 6 フィールド、`SessionPersistenceStore.applyAsyncPastDueCorrection(_:now:)` で past-due→awaitingAttendance 自動補正
- `Workspace.sessionSnapshot(includeScrollback:)` と `restoreSessionSnapshot(_:)` が Async 状態を往復
- ツール: `scripts/add-swift-file.sh` で新規 Swift ファイルを project.pbxproj に登録（冪等、冒頭でプレフィックス→target 自動判定）
- 単体テスト: `AsyncPhaseTransitionTests`（32 ケース） + `AsyncWorkspacePersistenceTests`（8 ケース）、全 pass

---

## 次の具体アクション

**`plan.md` §8 Step 3 — Preparing / Self-running / Awaiting overlay の殻** に着手。

1. `./scripts/add-swift-file.sh Sources/Async/ReadyToSyncOverlay.swift`
2. `./scripts/add-swift-file.sh Sources/Async/SelfRunningOverlay.swift`
3. `./scripts/add-swift-file.sh Sources/Async/OverdueOverlay.swift`
4. 各 overlay は SwiftUI `View`、ボタンと文言だけの最小実装（plan.md §6.2–6.4 参照）
5. `Sources/WorkspaceContentView.swift` の body を `ZStack` 化し、フェーズに応じて overlay を最前面に被せる（plan.md §6.1 / spec.md §6.1）
6. 動作確認用 dev ショートカットを一時的に仕込む（フェーズを手動切替できるように、Cmd+Opt+... 等）
7. `./scripts/reload.sh --tag rmux-async-data-model --launch` で UI 確認（overlay が出る／ターミナルが unmount されない）
8. screenshot を撮って視認（各フェーズで overlay が正しく表示されているか）

このステップでは永続化も UI もまだ触らない（ステップ 2, 3 で別途）。

---

## Phase 1 ステップ進捗（plan.md §8）

- [x] 1. データモデル（`WorkspaceMode` / `AsyncPhase` / 新規 `@Published` / 遷移集約メソッド + 32 unit tests）
- [x] 2. 永続化 v1→v2（`SessionWorkspaceSnapshot` 拡張、past-due 復元ハンドリング + 8 unit tests）
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
