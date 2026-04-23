# 実装計画: Async Workspace + Sync Session (MVP)

前提は `spec.md`。本書はそれを cmux に実装するための MVP の切り分けと順序。用語も `spec.md` §1.2 に従う。

---

## 1. MVP スコープ

Phase 1 のゴール: **1 プロジェクトで脳に優しいサイクルが回る**。Async workspace を 1 個作り、Sync session を始めて → self-running → 次の Sync で戻る、という最小ループがエージェントも含めて成立する状態。

### 1.1 入れるもの
1. Workspace の 2 タイプ（Normal / Async）
2. Async workspace の 4 フェーズ（preparing / syncing / self-running / awaiting-attendance）
3. 4 種類の overlay（+ 通常ターミナルに重ねる経過時間 HUD）
4. Sync を終える / 次回予定モーダル（クイックピック + 日時ピッカー、30 分粒度）
5. 「今すぐ Sync」の最小確認ダイアログ（yes / no）
6. スケジューラ（`self-running → awaiting-attendance` 自動遷移 + macOS 通知）
7. Self-running / awaiting-attendance 中のエージェント通知の完全抑制
8. サイドバー行のフェーズ表示
9. **エージェント連携の最小セット**: 環境変数注入、`.cmux/state.json` 継続更新、Claude Code `UserPromptSubmit` hook の配布、Async 作成時の `CLAUDE.async.md` テンプレ配布
10. 永続化 schema v1 → v2 マイグレーション
11. ローカライズ（ja / en）

### 1.2 Phase 2 以降で扱うもの
各項目の体験・依存・実装領域は §11 に詳述。

- **Self-running の信頼性と discipline**（省電力抑止 / エージェント異常検出 / 自動再起動 /「今すぐ Sync」の強摩擦）→ Phase 2
- **Google Calendar 連携** → Phase 3
- **Sync session の密度強化**（permission 事前交渉 / 稼働率レビュー / 振り返り / preparing のメモ欄 / 履歴 / MCP 双方向）→ Phase 4
- **複数プロジェクト俯瞰**（MenuBarExtra ステータス / プロジェクト一覧 / カレンダービュー / Sync session 間の衝突チェック）→ Phase 5
- **Normal ↔ Async 相互変換 UI**（データモデル自体は Phase 1 で可能にする）

---

## 2. データモデル

### 2.1 `Sources/Workspace.swift` への追加
`final class Workspace: ObservableObject` に以下を追加する。

```swift
enum WorkspaceMode: String, Codable { case normal, async }

enum AsyncPhase: String, Codable {
    case preparing
    case syncing
    case selfRunning
    case awaitingAttendance
}

@Published var mode: WorkspaceMode = .normal
@Published var asyncPhase: AsyncPhase? = nil         // mode == .async のときだけ非 nil

// フェーズ別に意味が変わるフィールド（invariant は §2.2）
@Published var nextSyncAt: Date? = nil               // selfRunning / awaitingAttendance
@Published var syncStartedAt: Date? = nil            // syncing
@Published var plannedDuration: TimeInterval? = nil  // syncing
@Published var lastSyncEndedAt: Date? = nil          // 常に valid（初回前は nil）
```

Workspace 本体は `Codable` ではないので、Codable 化は不要。永続化は §3 で別途。

### 2.2 不変条件（コードコメントにも 1 行で残す）
| `mode` | `asyncPhase` | `nextSyncAt` | `syncStartedAt` / `plannedDuration` |
| --- | --- | --- | --- |
| `.normal` | `nil` | `nil` | `nil` |
| `.async` + `.preparing` | — | `nil` または直前のスケジュール値を引き継ぎ | `nil` |
| `.async` + `.syncing` | — | `nil` | **set** |
| `.async` + `.selfRunning` | — | **set (未来)** | `nil` |
| `.async` + `.awaitingAttendance` | — | **set (過去)** | `nil` |

遷移は `Workspace.transition(to:reason:)` のような集約メソッド経由のみに制限してバリデーションを一箇所にまとめる。バラバラに `@Published` を書き換えさせない。集約メソッドは遷移後に §5.3 の `AgentStateEmitter` もキックする。

### 2.3 ヘルパ
- `var remainingUntilSync: TimeInterval? { nextSyncAt?.timeIntervalSinceNow }` — self-running の表示用
- `var overdueDuration: TimeInterval? { ... }` — awaiting-attendance 用
- `var elapsedSinceSyncStart: TimeInterval? { syncStartedAt.map { -$0.timeIntervalSinceNow } }` — HUD 用
- `var syncOverrun: TimeInterval? { zip(elapsedSinceSyncStart, plannedDuration).map(-) }` — 超過

---

## 3. 永続化（`Sources/SessionPersistence.swift`）

### 3.1 schema v2
`SessionSnapshotSchema.currentVersion` を `1 → 2` にバンプ。

`SessionWorkspaceSnapshot` に追加（全て optional、v1 読み出し時はデフォルト値を注入）:
- `mode: String?` — 欠損なら `"normal"`
- `asyncPhase: String?`
- `nextSyncAt: Date?`
- `syncStartedAt: Date?`
- `plannedDuration: TimeInterval?`
- `lastSyncEndedAt: Date?`

`SessionWorkspaceLayoutSnapshot.init(from:)`（既存 line 304 付近）の custom decoding パターンに倣って、v1 JSON でも読めるようにする。

### 3.2 復元時のフェーズ判定
読み込み時は snapshot の値をそのまま反映するが、1 箇所だけ特別処理：
- `mode == .async` かつ `asyncPhase == .selfRunning` かつ `nextSyncAt != nil` かつ `nextSyncAt < now` の場合、`awaitingAttendance` に書き換えて復元する（spec §8.1）。
- その他のフェーズはそのまま（syncing 中だった、preparing 中だった、など）。

### 3.3 書き込みタイミング
既存の save パスと同じでよい。`@Published` を監視している既存の機構に乗る（必要なら追加の `objectWillChange` フックを検討）。

---

## 4. スケジューラ（`Sources/Async/SyncSessionScheduler.swift`）

### 4.1 責務
- `TabManager.tabs` を監視し、`selfRunning` フェーズかつ `nextSyncAt` を持つ Workspace の中から **最も近い `nextSyncAt`** に 1 本タイマーを張る。
- 発火時に:
  - 対象 Workspace を `awaitingAttendance` に遷移（§2.2 の集約メソッド経由）
  - macOS ローカル通知（`UNUserNotificationCenter`）を 1 発（「Sync の時間です: `<workspace>`」）
  - 通知タップ時のハンドラで対象 Workspace を選択状態にする（`TabManager.selectedTabId = workspace.id`）。アプリ前面化はしない（Socket focus policy に揃える）。
- `tabs` 追加 / 削除、個別 Workspace の `asyncPhase` / `nextSyncAt` 変更で再スケジュール。

### 4.2 実装メモ
- タイマーは `DispatchSourceTimer` または `Timer.scheduledTimer(withTimeInterval:)`。
- 起動時に全 Workspace をスキャンし、past-due の self-running は §3.2 で既に `awaitingAttendance` に戻っている。スケジューラは何もしない。
- **衝突チェックは MVP に含めない** (Phase 5)。

---

## 5. エージェント連携・通知抑制

### 5.1 通知抑制のゲート（`Sources/TerminalNotificationStore.swift`）
現状 OSC 9/99/777 を受けて以下を更新している：
- サイドバーバッジ
- MenuBarExtra 未読数
- 通知パネル
- macOS 通知（出しているなら）

対象 Workspace の `asyncPhase` が `selfRunning` または `awaitingAttendance` のとき、上記 4 つのうち **可視化系は全てスキップ**（内部配列への `append` は通常通り行う）。関数入口で早期 return するガード層を 1 箇所に集中させる。

### 5.2 Sync session に戻った瞬間の扱い
`asyncPhase` が `syncing` に変わった瞬間、蓄積されている未抑制通知は既に内部 array にあるので、通知パネル UI 側で `workspace.asyncPhase` を見て表示条件を揃えるだけで自動的に見え始める（はず）。実装時に確認。

### 5.3 `Sources/Async/AgentStateEmitter.swift`（新規）

#### 5.3.1 責務
エージェントが sync / self-running / 他フェーズにあることを常時把握できる状態を提供する。spec §7 Phase 1 相当。具体的には 3 層:
1. **環境変数の注入**（プロセス起動時、静的、agent-agnostic）
2. **`.cmux/state.json` の書き込み**（動的、agent-agnostic）
3. **Claude Code `UserPromptSubmit` hook の配布**（ユーザ発話ごとに状態を会話に prepend、Claude Code 固有）

PTY への直接テキスト注入は **採用しない**（spec §7.2 #3 参照: Claude Code は TUI 常駐のためタイミング / 意味論の問題で壊れやすい）。

#### 5.3.2 環境変数
Workspace 初回起動（Ghostty surface 初期化）時に、ターミナルプロセスの環境に以下を注入する:

- `CMUX_WORKSPACE_ID` — Workspace の UUID
- `CMUX_STATE_FILE` — `.cmux/state.json` の絶対パス
- `CMUX_PHASE` — 初期フェーズ（`syncing` / `selfRunning` / `awaitingAttendance` / `preparing`）
- `CMUX_SYNC_STARTED_AT` — syncing のときだけ ISO8601
- `CMUX_PLANNED_DURATION_SECONDS` — syncing のときだけ
- `CMUX_NEXT_SYNC_AT` — selfRunning / awaitingAttendance のときだけ ISO8601

環境変数は静的なのでフェーズ変化には追随しない。追随する情報は (2) state.json で拾わせる。

#### 5.3.3 `.cmux/state.json` の書き込み
- 書き込み先: `{workspace.currentDirectory}/.cmux/state.json`
- Atomic write（一時ファイル → rename）で読み手が partial JSON を見ないようにする
- JSON スキーマ（MVP v1）:
  ```json
  {
    "schemaVersion": 1,
    "workspaceId": "...",
    "phase": "syncing|preparing|selfRunning|awaitingAttendance",
    "updatedAt": "2026-04-23T09:12:00Z",
    "syncing": {
      "startedAt": "2026-04-23T09:00:00Z",
      "plannedDurationSeconds": 1800,
      "elapsedSeconds": 720,
      "overrunSeconds": 0
    },
    "selfRunning": {
      "nextSyncAt": "2026-04-23T18:00:00Z",
      "remainingSeconds": 32580
    },
    "awaitingAttendance": {
      "scheduledAt": "2026-04-23T14:00:00Z",
      "overdueSeconds": 4200
    }
  }
  ```
  該当しないフェーズのオブジェクトは省略。
- 書き込み契機:
  - フェーズ遷移時（必ず）
  - syncing / selfRunning / awaitingAttendance 中は 60 秒に 1 回 refresh（elapsed / remaining / overdue の秒単位を更新）
  - Workspace 作成 / 削除時
- スキーマは公開ドキュメント（`docs-rmux/agent-state.md` を将来追加）にして agent-agnostic にする。

#### 5.3.4 Claude Code `UserPromptSubmit` hook の配布
- Async workspace 作成時に cwd に以下を配置:
  - `.cmux/prompt-hook.sh` — `.cmux/state.json` を読んで spec §7.3.2 の形式で stdout に出力する shell スクリプト（実行権限付き）
  - `.claude/settings.json` — `UserPromptSubmit` hook としてこのスクリプトを登録するエントリ
- `.claude/settings.json` が既存の場合は JSON をパースして `hooks.UserPromptSubmit` 配列に追記する。他のユーザ / 他ツール由来の hook は壊さない
- Hook エントリには「cmux managed」識別子（例: 特徴的なコマンドパス `.cmux/prompt-hook.sh` や命名規則）を含め、次回以降の再配布で重複書き込みを避ける
- スクリプトの挙動:
  - `.cmux/state.json` が無ければ何も出力せず exit 0（Workspace が Async でない等の想定）
  - ある場合は現在のフェーズと関連情報を spec §7.3.2 の形式で stdout に出す
- スクリプト依存: `bash` + `jq`。macOS 前提なので `jq` は Homebrew 経由を仮定。無い場合は素の shell で最低限のパース（機能限定）にフォールバック
- 能動 push（遷移の瞬間に agent に伝える）は MVP に含めない。Hook は「ユーザが喋ったとき」にしか発火しないので、残り時間警告などもユーザの次発話で伝わる（spec §7.3.3）。能動 push は Phase 4 の MCP で扱う

#### 5.3.5 `CLAUDE.async.md` テンプレ配布
- cmux リポジトリ内に `Resources/AgentTemplates/CLAUDE.async.md` を同梱。
- Async workspace 作成時、cwd にコピーする（既存ファイルがあればスキップ。`.gitignore` には勝手に触らない）。
- 内容: spec §7.4 のエージェント期待振る舞いを英語で明文化 + `CMUX_STATE_FILE` / `.cmux/state.json` の見方 + `[cmux] ` 接頭辞の解釈
- Phase が進むにつれ エージェントごとに分岐（Claude Code 用、Codex 用…）するが、MVP は 1 ファイル。

#### 5.3.6 オプトアウト
- 環境変数・state.json 書き込みは常時オン（軽量なため）。
- Hook 配布は Async 作成時のみ書き込む。ユーザが `.claude/settings.json` から cmux 由来エントリを手動で消した場合、cmux は書き戻さず尊重する（これがオプトアウトの手段を兼ねる）。

---

## 6. UI

### 6.1 Overlay 組み込み点（`Sources/WorkspaceContentView.swift`）
既存 `body` の `Group { if isMinimalMode ... bonsplitView ... }`（line 157–164 付近）を `ZStack` でラップ：

```swift
ZStack {
    existingBody                // bonsplitView を含む既存構造を保持（unmount しない）
    if let overlay = asyncOverlay(for: workspace) {
        overlay.transition(.opacity)
    }
    syncHUDIfNeeded(for: workspace)  // syncing のときだけ表示される経過時間 HUD
}
```

`asyncOverlay(for:)` はフェーズにより 3 種類のビューを返す（`preparing` / `selfRunning` / `awaitingAttendance`）。`syncing` / `normal` のときは nil。

**Bonsplit / Ghostty のサーフェスを絶対に unmount しない**（spec の核: ターミナルプロセスを維持する）。overlay で被せるだけ。

### 6.2 Preparing overlay (`Sources/Panels/ReadyToSyncOverlay.swift`)
- 全面 opaque、背景色は ghostty 設定の背景色に寄せる
- 見出し「Ready to sync」
- 予定時間ピッカー: Segmented or Picker。値は固定リスト: `15m / 30m / 45m / 1h / 1.5h / 2h / 3h / 4h`
- 「開始」押下:
  - `workspace.syncStartedAt = Date()`
  - `workspace.plannedDuration = selected`
  - `workspace.asyncPhase = .syncing`（集約メソッド経由、§2.2）
- 「キャンセル」押下:
  - 遷移元フェーズに戻す（呼び出し側が引数で渡す `previousPhase`、もしくは Workspace に一時フィールド）

### 6.3 Self-running overlay (`Sources/Panels/SelfRunningOverlay.swift`)
- 見出し: 「次の Sync は **2h 14m** 後」（相対時刻、`TimelineView(.periodic(from: .now, by: 60))` で 1 分更新）
- サブ: 絶対時刻（ユーザの locale で整形）
- ボタン「スケジュール変更」→ §6.7 のピッカーを出す
- ボタン「今すぐ Sync」→ §6.6 の確認ダイアログ → preparing へ

### 6.4 Awaiting-attendance overlay (`Sources/Panels/OverdueOverlay.swift`)
- 見出し: 「Overdue — 予定は **45m** 前」
- サブ: 元の予定時刻
- ボタン「今すぐ開始」→ 確認なしで preparing へ
- ボタン「リスケ」→ §6.7 のピッカーへ

### 6.5 経過時間 HUD (`Sources/Panels/SyncElapsedHUD.swift`)
- `syncing` 中だけ表示、`ZStack` の最前面に配置
- 配置: ターミナルの左下に小さな pill（一旦これで決め打ち。将来設定可能に）
- `TimelineView(.periodic(from: .now, by: 1))` で秒粒度更新
- フォーマット: `"00:24:18 / 予定 00:30:00"`
- 超過時:
  - テキスト色 → 赤
  - 1 Hz で点滅（opacity を 1.0 ↔ 0.4）
  - 超過時間を併記: `"00:32:14 / 予定 00:30:00 (+00:02:14)"`

### 6.6 「今すぐ Sync」確認ダイアログ（MVP: 最小版）
- SwiftUI `.alert` または簡易シートで確認ダイアログを出す
- 内容: 「Sync を今すぐ始めますか？ 予定時刻まで自走していた作業は中断されます。」
- ボタン: 「開始」「キャンセル」
- 「開始」で preparing へ遷移

MVP では摩擦は 1 クリック分だけ。フルパス手入力のような強い摩擦は Phase 2（§11）に回す。理由: まずサイクル自体を回して「誤爆の頻度」を実測してから摩擦のレベルを決める。

### 6.7 終了 / リスケモーダル `Sources/Panels/ScheduleNextSyncSheet.swift`
- クイックピック行: 「今から 1h / 3h / 6h」「翌 09:00 / 18:00」「来週月曜 09:00」等
  - 現在時刻から 30 分単位で候補を生成
  - 既に過ぎた候補は出さない
- 手動ピッカー: `DatePicker(displayedComponents: [.date, .hourAndMinute])`。minute は 30 分粒度で丸める。
- **衝突チェックは MVP に含めない** (Phase 5)。候補はそのまま全部選択可能。
- 確定:
  - `syncing → self-running`: `workspace.nextSyncAt = selected`, `workspace.asyncPhase = .selfRunning`, `workspace.syncStartedAt = nil`, `workspace.plannedDuration = nil`, `workspace.lastSyncEndedAt = Date()`
  - `awaitingAttendance → self-running` (リスケ): `workspace.nextSyncAt = selected`, `workspace.asyncPhase = .selfRunning`
- 確定後、遷移により `AgentStateEmitter` が state.json を更新する。エージェントは次発話時に hook 経由で新しい状態を受け取る（§5.3）。
- 戻り値は構造体 `ScheduledSync { at: Date, calendarEventId: String? }`。将来 Phase 3 で `calendarEventId` を足すための余白。

### 6.8 サイドバー行 (`Sources/ContentView.swift` `TabItemView`)
既存の git branch / ports 行に並ぶ形で、Async Workspace のみ 1 行追加:

| phase | 表示 |
| --- | --- |
| `preparing` | 「Ready to sync」小バッジ |
| `syncing` | 「Sync 中 · 00:24:18」（超過時は赤、HUD と同じ） |
| `selfRunning` | 時計アイコン + 「次の Sync まで 2h」 |
| `awaitingAttendance` | 「!」アイコン + 「Overdue 45m」 |

**`TabItemView` は Equatable 最適化あり**（CLAUDE.md pitfalls）:
- 新しい `let` パラメータで phase / 時間情報を precompute して渡す
- `==` 関数に新フィールドを含める
- `@ObservedObject` を増やさない

### 6.9 Workspace 作成フロー
- 新規 Workspace 作成 UI（既存の「+」ボタン）に Normal / Async の選択を足す。
- Async を選んだ場合、作成直後に「今すぐ」「後で」の 2 択:
  - 「今すぐ」→ 即 `preparing` で開く（内部的に nextSyncAt は nil）
  - 「後で」→ §6.7 のピッカーを出してから `selfRunning` へ
- 作成時に `CLAUDE.async.md` を cwd に配置（§5.3.5）。

MVP では Normal 側 UI は既存のまま、Async 化は新規 Async の作成のみ。Normal↔Async 変換 UI は MVP 外（spec §8.3, §8.4）。

---

## 7. ローカライズ

`Resources/Localizable.xcstrings` に以下を追加（ja / en 必須、CLAUDE.md）。キーは `async.*` で統一。

| キー | en | ja |
| --- | --- | --- |
| `async.create.title` | New Async Workspace | Async Workspace を作成 |
| `async.create.startNow` | Start now | 今すぐ |
| `async.create.scheduleLater` | Schedule for later… | 後で… |
| `async.phase.preparing.label` | Ready to sync | Ready to sync |
| `async.phase.syncing.label` | In sync | Sync 中 |
| `async.phase.selfRunning.label` | Self-running | 自走中 |
| `async.phase.awaitingAttendance.label` | Overdue | Overdue |
| `async.preparing.headline` | Ready to sync | Ready to sync |
| `async.preparing.durationPicker` | Planned duration | 予定時間 |
| `async.preparing.start` | Start | 開始 |
| `async.preparing.cancel` | Cancel | キャンセル |
| `async.selfRunning.headline` | Next sync in %@ | 次の Sync は %@ 後 |
| `async.selfRunning.reschedule` | Change schedule | スケジュール変更 |
| `async.selfRunning.syncNow` | Sync now | 今すぐ Sync |
| `async.awaitingAttendance.headline` | Overdue — scheduled %@ ago | Overdue — 予定は %@ 前 |
| `async.awaitingAttendance.startNow` | Start now | 今すぐ開始 |
| `async.awaitingAttendance.reschedule` | Reschedule | リスケ |
| `async.syncing.endAndSchedule` | End sync / Schedule next… | Sync を終える / 次回を予定… |
| `async.syncing.elapsedOverPlanned` | %@ / planned %@ | %@ / 予定 %@ |
| `async.syncing.elapsedOverrun` | %@ / planned %@ (+%@) | %@ / 予定 %@ (+%@) |
| `async.syncNow.confirmTitle` | Sync now? | 今すぐ Sync しますか？ |
| `async.syncNow.confirmMessage` | The work running in the background will be interrupted. | 裏で走っている自走作業が中断されます。 |
| `async.syncNow.confirmAction` | Start | 開始 |
| `async.scheduler.notificationTitle` | Sync time | Sync の時間です |
| `async.scheduler.notificationBody` | Sync with %@ is scheduled now | %@ との Sync の時間です |
| `async.sidebar.overdue` | Overdue %@ | Overdue %@ |
| `async.sidebar.nextIn` | Next in %@ | 次の Sync まで %@ |

エージェント向けテキスト（§5.3.4）は **英語固定** でローカライズ対象外。

---

## 8. 実装ステップ（順）

各ステップ後に `./scripts/reload.sh --tag rmux-async` で動作確認。

1. **データモデル**: `WorkspaceMode`, `AsyncPhase`, 新規フィールドを `Workspace` に追加。遷移集約メソッドを生やす。ビルド通るだけで UI には何も出ない。
2. **永続化 v1→v2**: `SessionWorkspaceSnapshot` 拡張、custom decoding。古い session ファイルを食わせて正しく復元できることを手動確認。
3. **Preparing / Self-running / Awaiting overlay の殻**: 文言とボタンだけの最小ビュー。`WorkspaceContentView` の `ZStack` 組み込み。Workspace を手動で各フェーズにセットする開発用ショートカットキーを一時的に作ると iterate が楽。
4. **スケジュール設定モーダル（§6.7）**: クイックピック + 日時ピッカー。preparing や終了フローから呼び出せる。衝突チェックは入れない。
5. **Sync を終える導線**: syncing 中にだけ出る「Sync を終える / 次回を予定…」ボタン → §6.7 のモーダル → self-running へ。
6. **`AgentStateEmitter` (§5.3)**: 環境変数注入 + state.json 書き込み + `CLAUDE.async.md` 配布。まだ hook 配布は入れない（state.json が正しく更新されるかを先に確認する）。
7. **SyncSessionScheduler**: 最近接 `nextSyncAt` のタイマー、発火で awaiting-attendance 遷移 + macOS 通知。
8. **Claude Code hook 配布**: §5.3.4 に従い `.claude/settings.json` マージと `.cmux/prompt-hook.sh` 配置。実際に Claude Code セッションでユーザ発話ごとに `[cmux] ` 行が会話に prepend されることを手動確認。
9. **経過時間 HUD**: syncing 中だけの pill。予定超過で赤点滅。
10. **「今すぐ Sync」確認ダイアログ（§6.6）**: self-running overlay から preparing への経路。MVP は yes/no 1 枚。
11. **通知抑制**: `TerminalNotificationStore` 側のゲート。Async workspace が self-running / awaiting 中は可視化系をスキップ。内部 append は継続。
12. **サイドバー行表示**: `TabItemView` に phase 情報を precompute して渡す。Equatable の `==` 更新を忘れない。
13. **新規 Async workspace 作成 UI**: 「+」ボタンに Normal / Async の選択。「今すぐ / 後で」。
14. **ローカライズ**: §7 のキーを ja / en で埋める。

---

## 9. テスト戦略

CLAUDE.md の「Testing policy」と「Test quality policy」を厳守：
- ローカルで `xcodebuild -scheme cmux-unit` は走らせても良いが、E2E / UI 系は GitHub Actions に委ねる。
- ソースコード文字列や project.pbxproj を grep するだけのテストは書かない。
- observable な振る舞いを検証する。

### 9.1 unit でカバーできるもの（cmux-unit 想定）
- フェーズ遷移の不変条件: `Workspace.transition(to:)` が不正遷移を弾くか
- 復元時の past-due → awaiting-attendance 書き換え
- 経過 / 超過計算 (`elapsedSinceSyncStart`, `syncOverrun`)
- v1 セッションファイルを decode できるか（decoder 直接呼び出し）
- `.cmux/state.json` のシリアライズ形式（固定スキーマに一致するか）

### 9.2 手動 / UI で確認（CI 後）
- 通知抑制: self-running 中の OSC 通知がサイドバー・MenuBar・通知パネルに現れず、syncing 戻りで見えるようになる
- 経過 HUD の赤点滅が予定超過で発動する
- 今すぐ Sync 確認で「キャンセル」すると self-running に戻り、overlay と state.json が一貫している
- アプリ再起動での各フェーズ復元（特に syncing 中再起動）
- スケジュールタイマー発火で awaiting へ遷移し macOS 通知が出る
- `.cmux/state.json` が想定のタイミングで更新される
- Hook スクリプトが `.cmux/state.json` を読んで spec §7.3.2 の形式で出力する（bash で直接実行してスナップショット比較）
- Async 作成時に `.claude/settings.json` に cmux 由来の hook エントリが追加され、ユーザ既存設定を壊さないこと（手動確認）
- Claude Code セッションでユーザ発話ごとに `[cmux] ` prefix 行が会話に prepend されることを実機で確認

---

## 10. 既知のリスクと未解決

- **バンドル / derived data**: `./scripts/reload.sh --tag rmux-async` 必須。untagged で起動して既存の Debug app と衝突させないこと（CLAUDE.md）。
- **Equatable 最適化の崩壊**: `TabItemView` で phase 情報を追加したときに `==` を更新し忘れるとタイピングレイテンシが悪化する。レビューの chokepoint。
- **ZStack overlay の入力吸収**: overlay ビューが opaque なので基本的にクリック / キー入力は下の bonsplit に届かない想定だが、偶発的に一部が透過した際にターミナルにキーが抜けると事故なので、overlay ビューは `.contentShape(Rectangle())` と明示ハンドラで塞ぐ。
- **通知抑制のラグ**: フェーズ変更直後に抑制対象になる通知が既にキューに積まれていた場合の扱い（表示する / しない / どの時点で判定するか）。実装時に仕様決め。
- **preparing の「前のフェーズ」表現**: 「キャンセルで戻る」のためのスタック状態をどう持つか。Workspace に一時フィールドを生やすか、呼び出し元から注入するか。MVP は単純化のため「self-running を保持する Workspace なら self-running に、awaiting は awaiting に、初回は awaiting-scheduled なし＝ self-running 扱い」のルールで十分。
- **Google Calendar 連携に備えた型設計**: Phase 1 は `nextSyncAt: Date?` のみ保持する。Phase 3 で `calendarEventId` 等を schema v3 として追加する。§6.7 のスケジュールシートの戻り値は最初から構造体 `ScheduledSync { at: Date, calendarEventId: String? }` にしておき、拡張を容易にする。
- **`.cmux/state.json` の書き込み競合**: 複数の cmux プロセス / tagged ビルドが同じ cwd を触る状況で衝突しうる。`workspaceId` を確認してスキップする等の防御が要る（MVP ではとりあえず単一プロセス想定）。
- **Hook 配布の冪等性**: Workspace 再作成や設定再書き込みで `.claude/settings.json` の hook エントリが重複しないこと。特徴的なコマンドパス等で既存判定して upsert する。
- **既存 `.claude/settings.json` とのマージ**: ユーザが既に hook を登録している場合、配列に追記する形で既存を壊さない。JSON パースエラー時は上書きせず警告のみ（復旧はユーザに任せる）。
- **Hook スクリプトの環境依存**: `jq` 未インストール、PATH に無い、`bash` 以外で実行された場合のフォールバック。最低限 `bash` + 標準 Unix ツールで動くようにし、`jq` がなければ機能限定でも exit 0。
- **「今すぐ Sync」の誤爆頻度**: MVP は yes/no 1 枚のみ。実測で十分な摩擦がないなら Phase 2 でフルパス手入力を足す（§11）。

---

## 11. ロードマップ: Phase 2–5

各 phase は **独立してリリース可能な単位** を目指す。phase を進めるたびに「脳に優しい」体験が具体的にどう広がるかを先に書き、機能はその後に並べる。

### Phase 2: Self-running の信頼性と discipline

**ねらい**: Self-running を本当に「次の Sync まで忘れてよい」と言える土台にする。マシンスリープでの自走停止、エージェントの詰まり未検知、誤操作による self-running 中断の 3 点を潰す。

**この phase 後にできるようになること**:
- ノートを閉じても self-running が続く（蓋を開けたら進捗が積まれている）
- エージェントが詰まっていたら Sync の前でも通知される（ただし進捗は見せない）
- 致命ではないクラッシュは自動で 1 回再起動して復帰する
- 自走中のマシン発熱 / 電力を気にしなくていい
- 「今すぐ Sync」を気軽に押せない（強い摩擦で impulse を抑える）

**含まれるもの**:
- **Power assertion**: Async workspace が 1 つでも self-running / awaiting-attendance ならシステムスリープを抑止する。バッテリ残量 < N % / 電源未接続で自動解除。`IOPMAssertionCreateWithName` 実装。
- **Sleep / wake 耐性**: `NSWorkspace.willSleepNotification` / `didWakeNotification` をハンドリングし、スケジューラのタイマーを再計算。wake 時点で `nextSyncAt` を過ぎていれば即 `awaiting-attendance` に寄せる。
- **エージェント liveness 監視**: PTY への出力が一定時間ないことを検出（per-workspace に閾値設定可）。OSC 終了マーカーが途切れたことの検出。ターミナルプロセス自体の死亡検出。
- **異常通知**: spec §6.3 に従い 1 回だけ macOS 通知 + サイドバーの控えめな印。フェーズは勝手に変えない。
- **任意の自動再起動**: 特定の pattern（例: "Session terminated" のような agent の死亡メッセージ）にマッチしたら同じ引数で再起動。オプトイン・Workspace 単位で設定可。
- **「今すぐ Sync」強摩擦**: spec §6.1.6。self-running overlay からの割り込みで、Workspace の cwd フルパスを手入力させて初めてボタンが有効化。誤爆 impulse を抑える。

**外すもの**:
- GPU / CPU 負荷の自動スロットリング（Phase 4 の稼働率レビュー寄り）
- VPN / ネットワーク切断の自動ハンドリング（範囲が大きいため後回し）

**依存**: Phase 1

**代表的な実装領域**:
- `Sources/Async/PowerAssertion.swift` — `IOPMAssertion` ラッパ
- `Sources/Async/AgentLivenessMonitor.swift` — PTY 活動 + OSC を見る
- `Sources/Async/AutoRestartPolicy.swift` — パターンベースの自動再起動
- `Sources/Panels/SyncNowFullPathDialog.swift` — フルパス入力確認（§6.6 の拡張）

**懸念・未解決**:
- liveness 検出の false positive（長時間出力のない正常な処理と詰まりの区別）
- 自動再起動で「Claude Code の会話文脈」をどう引き継ぐか（現状 `--resume` 相当が使えるかはエージェント依存）
- power assertion がバッテリ駆動時に過剰発動しないためのしきい値
- フルパス手入力の代替（パスが長すぎる場合、ディレクトリ名だけ等）

---

### Phase 3: Google Calendar 連携

**ねらい**: Sync session の予定を Google Calendar と双方向に同期する。他の予定（会議・プライベート）と物理的に衝突しなくなり、家族や同僚から見ても通常のスケジュールの一部として扱える。

**この phase 後にできるようになること**:
- Sync session を入れると Google Calendar に自動で予定が立つ
- 既に別件が入っている時間帯は候補に出ない（物理衝突ゼロ）
- カレンダー側で予定を動かすと cmux も追従する
- リマインダーは Google Calendar の通知機構に一任できる
- 不在 / 休暇 / 夜間を自動で避けた自然なリズム

**含まれるもの**:
- **OAuth**: Google アカウント認証、トークンは Keychain 保管
- **予定の双方向同期**: Sync session 確定でイベント作成 / リスケで更新 / Workspace 削除でイベント削除。外部からの削除・移動も反映。
- **空き時間ベースのピッカー**: `ScheduleNextSyncSheet` の候補を、カレンダーの free/busy から生成
- **使用カレンダー選択**: MVP は primary 1 つ。複数カレンダー対応はさらに後
- **バックグラウンド同期**: アプリ前面時は短い間隔、バックグラウンド時はゆっくりの適応的ポーリング（push が使えるなら push）

**外すもの**:
- Outlook / iCloud Calendar 対応（エコシステムを 1 つに絞る）
- Calendly などの外部予約ツール連携

**依存**: Phase 1（MVP の `nextSyncAt` 概念）

**代表的な実装領域**:
- `Sources/Async/GoogleCalendar/` — OAuth クライアント、API ラッパ、同期ロジック
- `Sources/Async/ScheduleNextSyncSheet.swift` の拡張（free/busy 組み込み）
- 永続化に `calendarEventId: String?` 追加（schema v3）

**懸念・未解決**:
- オフライン時の挙動（どこまでローカルで動けるか、競合解消ルール）
- `calendarEventId` の衝突 / 変更検出のコスト
- 複数デバイスで同じアカウントを使ったときの同期の一貫性

---

### Phase 4: Sync session の密度強化 + エージェント双方向

**ねらい**: Sync session に意思決定の材料（前回の sync からの進捗メトリクス）と、次回までの意志決定（何を許可するか）を乗せる。エージェントからも「これを次回に持ち上げてほしい」と能動的に rmux へ伝えられるようにする。Sync の 30 分を濃くする。

**この phase 後にできるようになること**:
- Sync を始める前に「今回やりたいこと」を書き、終了時に達成度を振り返れる
- 前回の Sync 終了から今回までの **実稼働率** が数字で見える（「24h 中、エージェントが実働したのは 2h 17m」）
- Permission を Sync 内で事前に設定し、次回までの self-running で権限ダイアログに詰まらない
- プロジェクトごとの Sync 履歴が残り、過去の予定 vs 実績の乖離が見える
- エージェントが self-running 中に「人間に聞きたいこと」を積み上げ、次の sync で一覧される
- 「ダラダラしがち」「時間を過剰に取る」自分の癖が数字で突きつけられる

**含まれるもの**:
- **Preparing のメモ欄**: 「今回やりたいこと」を任意で入力
- **稼働率トラッカー**: PTY 書き込み頻度・エージェントプロセスの CPU 時間などを連続収集し、self-running 期間の活動時間を集計
- **Sync session ダッシュボード**: syncing 中に表示できるパネル（通知パネルと並ぶ位置）。前回以降のメトリクス + メモ + 予定 vs 実時間の履歴 + エージェントが積んだ "banked questions"
- **Permission 事前交渉 UI**: Claude Code の `settings.json` / permissions を cmux 内から編集。エージェント固有の設定パスを抽象化したレイヤを挟む
- **Sync 履歴の永続化**: 各 Sync session の { 予定時間, 実時間, メモ, 稼働率スナップショット, banked questions } を保存
- **MCP サーバ (cmux ↔ エージェント双方向 + 能動 push)**: spec §7.2 #4, §7.5。`get_cmux_state` / `queue_question_for_next_sync` / `checkpoint_note` 等を expose。Phase 1 の `UserPromptSubmit` hook は「ユーザ発話時のみ」発火するため、self-running 中のリアルタイム警告（予定時間超過、「今すぐ人間呼び戻し」要請）など **能動 push が必要なユースケースはここで初めて対応**。

**外すもの**:
- Claude Code 以外のエージェント harness への permission 対応（Codex, OpenCode の settings への介入は後）
- 自動化された「次回の推奨 Planned duration」の学習提案（Phase 5 以降）

**依存**: Phase 1。Phase 2 の liveness 監視があると稼働率の精度が上がる。

**代表的な実装領域**:
- `Sources/Async/UtilizationTracker.swift` — PTY / プロセス観測
- `Sources/Async/SyncHistory.swift` — 履歴永続化モデル
- `Sources/Async/SyncDashboardView.swift` — syncing 中に出すダッシュボード
- `Sources/Async/PermissionEditor.swift` — エージェント固有 settings への介入層
- `Sources/Async/CmuxMCPServer.swift` — MCP エンドポイント実装

**懸念・未解決**:
- 稼働率の定義（PTY 書き込みだけで本当に「稼働」と言えるか）
- Permission 編集の粒度（cmux の抽象化に押し込むべきか、Claude Code の設定画面へのリンクで十分か）
- MCP サーバを cmux アプリ内で走らせるか外部 daemon にするか
- Sync 履歴の UI 情報量と「詰め込みすぎで逆に疲れる」のトレードオフ

---

### Phase 5: 複数プロジェクト俯瞰

**ねらい**: 複数の Async workspace（典型的には 3–5 個並列）を 1 視点で把握 / 操作できるようにする。rmux アプリを毎回開かなくてもメニューバーで状態が分かる状態にし、複数プロジェクト間のスケジュール衝突も構造的に解決する。

**この phase 後にできるようになること**:
- Dock / Cmd+Tab に cmux を戻さなくても、メニューバーで「今走っているプロジェクト数 / 次の Sync までの時間」がわかる
- 複数プロジェクトの Sync 予定が週ビューで俯瞰できる（Google Calendar と一致）
- プロジェクト一覧で「最近放置気味」「稼働率が下がっている」が一目でわかる
- ドラッグで Sync 時刻を動かしたり、別プロジェクトに付け替えたりできる
- 2 つの Async workspace が同じ時刻に Sync を設定しようとすると構造的にブロックされる
- 「週 20h を async に割いた結果、各プロジェクトの実働がこれだけになった」という運営視点を持てる

**含まれるもの**:
- **MenuBarExtra ステータス拡張**: アイコンの状態差分で「全 Async 正常」「N 個自走中」「⚠ 異常あり」を表現。ドロップダウンに Async workspace 一覧 + 次回 Sync 時刻。self-running / awaiting-attendance 中の未読通知カウントは抑制を維持（spec §5.3）。
- **プロジェクト一覧ビュー**: Async workspace だけを抜き出した別ビュー（別ウィンドウ or 新タブ）。各行: 名前、フェーズ、次回 Sync、前回からの稼働率、稼働のトレンド小グラフ。
- **カレンダービュー**: Async の Sync を週 / 日単位で俯瞰。Google Calendar のイベントと同じ表示 (Phase 3)。ドラッグで時間変更 → Calendar API に伝播。
- **プロジェクトメタデータ**: 目的・期限・関係者・ゴール条件などを Workspace に付与し、ダッシュボードに表示。
- **運営メトリクス**: 週次 / 月次で「async に割いた総時間」「実稼働比率」などをまとめて見せる。
- **cmux 内の Sync session 衝突チェック**: `ScheduleNextSyncSheet` でスケジュール選択時、既存 Async workspace の `nextSyncAt` と ±30 分以内の候補を disable。Google Calendar 連携時は Phase 3 の free/busy と統合される。

**外すもの**:
- リモート / 他デバイスでの同期（「チームで同じプロジェクトを見る」は別の次元の話）
- AI を使った「このプロジェクトは詰まり気味です」のような自動アラート（過度な能動化は「脳に優しい」思想に反する）

**依存**: Phase 1 / 3 / 4（俯瞰に値するだけの情報が Phase 4 まででやっと揃う）

**代表的な実装領域**:
- `Sources/AppDelegate.swift` の `MenuBarExtraController` 拡張
- `Sources/Async/ProjectListView.swift`
- `Sources/Async/CalendarView.swift`
- `Sources/Async/SyncConflictChecker.swift` — ±30 分窓のスケジュール判定
- 週次集計は Phase 4 の `SyncHistory` を参照

**懸念・未解決**:
- MenuBarExtra の表示密度（詳細 vs 一目性のバランス）
- カレンダービューは Google Calendar の iframe / 埋め込みで済ませるか、独自レンダリングするか
- プロジェクトメタデータのスキーマをどこまで事前定義するか（自由記述 vs 構造化）

---

### Phase を越えて考え続けたいテーマ

- **他のエージェント harness（Codex, OpenCode）への対応**: `.cmux/state.json` と環境変数 (`CMUX_*`) は agent-agnostic なので他ハーネスでも流用できる。Claude Code 固有の `UserPromptSubmit` hook と Permission 事前交渉（エージェントごとに settings 形式が異なる）は、エージェントごとに個別実装の抽象化レイヤを用意する。
- **リモート / チーム化**: 同じ Async workspace を複数人で運営する設計。spec 全体の前提（「1 人の人間の脳を守る」）を大きく変える。
- **Sync session の AI アシスト**: 前回〜今回の活動から sync 開始時にサマリを自動生成、のような。ただし「人間の意志決定を代替しすぎない」バランスが必要。
