# Agent state file 公開スキーマ

rmux が Async workspace ごとに継続的に書き出す状態ファイルの仕様。エージェント（Claude Code / Codex / OpenCode / その他）がこれを読んで自分の振る舞いを調整する前提。

詳細な背景は `spec.md` §7（エージェント連携）。

---

## 1. 意図

- **agent-agnostic**: Claude Code の `UserPromptSubmit` hook（`spec.md` §7.2 #3）に依存しない他エージェントも、このファイルを読めば現状を把握できる
- **atomic write**: rmux は tempfile → rename で書き込む。partial JSON を読まされる心配はない
- **更新タイミング**:
  - Async workspace のフェーズ遷移時（必ず）
  - `syncing` / `selfRunning` / `awaitingAttendance` 中は **60 秒ごと** に refresh（elapsed / remaining / overdue の秒単位を更新）
  - Workspace 作成・削除時
- **identity は workspace、cwd ではない**: 同一 cwd で複数 Async workspace を立ち上げても衝突しない。古い workspace を破棄しても新しい workspace の状態に混入しない

---

## 2. パスと発見方法

### 2.1 パス

```
~/Library/Application Support/<bundleId>/workspaces/<workspaceId>/state.json
```

- `<bundleId>` は実行中の rmux ビルドの bundle identifier（例: production `com.cmuxterm.app` / debug `com.cmuxterm.app.debug` / tagged build はタグ別 ID）。これにより dev / prod / 並走 tagged build が互いに分離される
- `<workspaceId>` は workspace の UUID
- プロジェクトツリー（cwd 配下）には **置かない**。`.gitignore` 汚染なし

### 2.2 エージェントからの発見

エージェントプロセスは **環境変数 `CMUX_STATE_FILE`** からこの絶対パスを取得する。rmux はターミナル起動時に常にこの env を export する（Normal workspace の terminal にも入る；ファイルが存在しないだけ）。

```bash
$ echo "$CMUX_STATE_FILE"
/Users/me/Library/Application Support/com.cmuxterm.app.debug/workspaces/8e4a2f3b-1234-5678-9abc-def012345678/state.json

$ jq '.phase' "$CMUX_STATE_FILE"
"syncing"
```

`$CMUX_STATE_FILE` が未設定 / ファイル不在 → 「rmux Async workspace ではない」と解釈する（Normal workspace、または rmux 外で起動したエージェント）。`$PWD/.cmux/state.json` への fallback は **行わない**（cwd 紐付けは Phase 1.5 で廃止）。

### 2.3 cwd 配下に残るもの

**`.claude/settings.local.json` の 1 ファイルだけ**（Claude Code の hook entry）。これは Claude Code の慣習で個人設定（gitignored）扱い。rmux が書き込む cwd 配下のファイルはこれ以外にない:

- `CLAUDE.async.md` → **配布しない**（per-turn hook で operating notes は完結、fuller doc は rmux 側 `docs-rmux/agent-state.md`）
- `.cmux/` ディレクトリ → **作らない**
- `CLAUDE.md` → **絶対に触らない**（team-shared、rmux は個人ワークフローツール）
- `.claude/settings.json` → **触らない**（team-shared、git 追跡前提）

rmux をアンインストールしたければ `.claude/settings.local.json` の hook entry を手動で消すだけで cwd は綺麗になる。

---

## 3. schemaVersion 1

### 例（syncing 中）

```json
{
  "schemaVersion": 1,
  "workspaceId": "8e4a2f3b-1234-5678-9abc-def012345678",
  "phase": "syncing",
  "updatedAt": "2026-04-23T09:12:00Z",
  "syncing": {
    "startedAt": "2026-04-23T09:00:00Z",
    "plannedDurationSeconds": 1800,
    "elapsedSeconds": 720,
    "overrunSeconds": 0
  },
  "selfRunning": null,
  "awaitingAttendance": null
}
```

### 例（self-running 中）

```json
{
  "schemaVersion": 1,
  "workspaceId": "8e4a2f3b-1234-5678-9abc-def012345678",
  "phase": "selfRunning",
  "updatedAt": "2026-04-23T13:00:00Z",
  "syncing": null,
  "selfRunning": {
    "nextSyncAt": "2026-04-23T18:00:00Z",
    "remainingSeconds": 18000
  },
  "awaitingAttendance": null
}
```

### 例（awaiting-attendance）

```json
{
  "schemaVersion": 1,
  "workspaceId": "8e4a2f3b-1234-5678-9abc-def012345678",
  "phase": "awaitingAttendance",
  "updatedAt": "2026-04-23T14:45:00Z",
  "syncing": null,
  "selfRunning": null,
  "awaitingAttendance": {
    "scheduledAt": "2026-04-23T14:00:00Z",
    "overdueSeconds": 2700
  }
}
```

### 例（preparing）

```json
{
  "schemaVersion": 1,
  "workspaceId": "8e4a2f3b-1234-5678-9abc-def012345678",
  "phase": "preparing",
  "updatedAt": "2026-04-23T08:59:50Z",
  "syncing": null,
  "selfRunning": null,
  "awaitingAttendance": null
}
```

---

## 4. フィールド定義

| フィールド | 型 | 説明 |
| --- | --- | --- |
| `schemaVersion` | integer | 互換性のない変更でのみ bump |
| `workspaceId` | string | Workspace の一意識別子（UUID）。パスにも入っているが冗長保持 |
| `phase` | string | `"preparing"` / `"syncing"` / `"selfRunning"` / `"awaitingAttendance"` のいずれか |
| `updatedAt` | string (ISO8601 UTC) | 書き込み時点 |
| `syncing` | object \| null | `phase == "syncing"` のときだけ非 null |
| `syncing.startedAt` | string (ISO8601) | Sync 開始時刻 |
| `syncing.plannedDurationSeconds` | integer | 予定時間（秒） |
| `syncing.elapsedSeconds` | integer | 開始からの壁時計経過（秒） |
| `syncing.overrunSeconds` | integer | 超過分（超過がなければ 0） |
| `selfRunning` | object \| null | `phase == "selfRunning"` のときだけ非 null |
| `selfRunning.nextSyncAt` | string (ISO8601) | 次回 Sync の予定時刻 |
| `selfRunning.remainingSeconds` | integer | 次回までの残り秒数 |
| `awaitingAttendance` | object \| null | `phase == "awaitingAttendance"` のときだけ非 null |
| `awaitingAttendance.scheduledAt` | string (ISO8601) | 本来の予定時刻 |
| `awaitingAttendance.overdueSeconds` | integer | 予定時刻からの経過（遅延）秒数 |

`phase == "preparing"` のときは syncing / selfRunning / awaitingAttendance はすべて null。

---

## 5. 読み方（エージェント向け recipe）

1. `$CMUX_STATE_FILE` 環境変数を読む
2. 未設定 / ファイル不在 → 「rmux Async ではない」と解釈（= 従来通りの挙動）
3. JSON パース。パース失敗のときも同様に従来通りの挙動
4. `phase` で分岐:
   - `syncing` → 残り時間（`plannedDurationSeconds - elapsedSeconds`）を確認し、少なければ話題を切り上げる。`overrunSeconds > 0` なら超過なので早めに Sync を終える合意を取る
   - `preparing` → 人間が Sync を開始する直前。気持ちを整える（この状態でエージェントが能動的に何かする必要は通常ない）
   - `selfRunning` → 人間は見ていない。質問を積極的に抱え込まず、保守的に進めてログに残す。OSC 通知は自発的に抑制
   - `awaitingAttendance` → 予定時刻を過ぎているが人間が来ていない。`selfRunning` と同じ振る舞いで OK
5. Claude Code を使っているなら、rmux が配布する `UserPromptSubmit` hook（`~/.cmux/prompt-hook.sh`、`.claude/settings.local.json` に登録）経由で上記情報が毎発話 `[cmux]` 接頭辞で会話に prepend される（spec §7.3.2）。自力で読む必要は薄い。他エージェントは自力で読む

---

## 6. 非保証 / 制約

- **鮮度**: 60 秒粒度。10 秒以内の正確性は保証しない
- **消失**: ファイルが存在しない → Async workspace でない か、rmux が動いていない。前者なら何もしなくてよい
- **複数書き込み**: workspace 単位なので、同一 workspace への書き込み競合は rmux 内部で起きない（writeState は main actor 上）。複数 rmux プロセスが **同じ workspaceId** を持つ状況は通常起きない（UUID 衝突は無視できる）
- **バージョン互換**: `schemaVersion` が将来 2 になったときは、フィールド配置が変わる可能性がある。エージェント側は `schemaVersion` を必ず確認

---

## 7. 将来の拡張候補（Phase ごと）

- **Phase 3（Google Calendar）**: `selfRunning.calendarEventId`, `awaitingAttendance.calendarEventId` を追加
- **Phase 4（密度強化）**: `syncing.note`（今回やりたいこと）、`selfRunning.bankedQuestions[]`（エージェントが次回 sync のために積んだ質問一覧）、`utilization` ブロック（self-running 中の実稼働時間メトリクス）
- **Phase 5（複数プロジェクト）**: Workspace ごとの state.json は変わらないが、俯瞰用に別の集約ファイルを提供する可能性

---

## 8. 関連

- 書き込み側実装: `Sources/Async/AgentStateEmitter.swift`、パス計算は `Sources/Async/AgentStatePaths.swift`
- env 注入: `Sources/GhosttyTerminalView.swift`（`setManagedEnvironmentValue("CMUX_STATE_FILE", ...)`）
- Claude Code hook 本体: `~/.cmux/prompt-hook.sh`（rmux が初回 Async 化時に配布、global 1 本）
- エージェント期待振る舞い: `spec.md` §7.4
