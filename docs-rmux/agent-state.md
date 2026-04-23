# `.cmux/state.json` 公開スキーマ

rmux が Async workspace の **cwd 配下 `.cmux/state.json`** に継続的に書き出す状態ファイルの仕様。エージェント（Claude Code / Codex / OpenCode / その他）がこれを読んで自分の振る舞いを調整する前提。

詳細な背景は `spec.md` §7（エージェント連携）。

---

## 1. 意図

- **agent-agnostic**: Claude Code の `UserPromptSubmit` hook（`spec.md` §7.2 #3）に依存しない他エージェントも、このファイルを読めば現状を把握できる
- **atomic write**: rmux は tempfile → rename で書き込む。partial JSON を読まされる心配はない
- **更新タイミング**:
  - Async workspace のフェーズ遷移時（必ず）
  - `syncing` / `selfRunning` / `awaitingAttendance` 中は **60 秒ごと** に refresh（elapsed / remaining / overdue の秒単位を更新）
  - Workspace 作成・削除時
- **パス**: ワークスペース cwd の `.cmux/state.json`。環境変数 `CMUX_STATE_FILE` にも絶対パスが入る（エージェントはこれを優先して読むべき）
- **gitignore**: rmux は `.gitignore` を勝手に書き換えない。ユーザが自分で `.cmux/` を除外する想定

---

## 2. schemaVersion 1

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

## 3. フィールド定義

| フィールド | 型 | 説明 |
| --- | --- | --- |
| `schemaVersion` | integer | 互換性のない変更でのみ bump |
| `workspaceId` | string | Workspace の一意識別子（UUID） |
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

## 4. 読み方（エージェント向け recipe）

1. `$CMUX_STATE_FILE` 環境変数があればそのパスから読む。なければ `$PWD/.cmux/state.json`
2. JSON パース。パース失敗・ファイル不在のときは「rmux Async ではない」と解釈（= 従来通りの挙動）
3. `phase` で分岐:
   - `syncing` → 残り時間（`plannedDurationSeconds - elapsedSeconds`）を確認し、少なければ話題を切り上げる。`overrunSeconds > 0` なら超過なので早めに Sync を終える合意を取る
   - `preparing` → 人間が Sync を開始する直前。気持ちを整える（この状態でエージェントが能動的に何かする必要は通常ない）
   - `selfRunning` → 人間は見ていない。質問を積極的に抱え込まず、保守的に進めてログに残す。OSC 通知は自発的に抑制
   - `awaitingAttendance` → 予定時刻を過ぎているが人間が来ていない。`selfRunning` と同じ振る舞いで OK
4. Claude Code を使っているなら、rmux が配布する `UserPromptSubmit` hook 経由で上記情報が毎発話 `[cmux]` 接頭辞で会話に prepend される（spec §7.3.2）。自力で読む必要は薄い。他エージェントは自力で読む

---

## 5. 非保証 / 制約

- **鮮度**: 60 秒粒度。10 秒以内の正確性は保証しない
- **消失**: ファイルが存在しない → Async workspace でない か、rmux が動いていない。前者なら何もしなくてよい
- **複数書き込み**: rmux は単一プロセス前提。複数 rmux が同じ cwd を書く状況は想定外（Phase 以降で防御検討）
- **バージョン互換**: `schemaVersion` が将来 2 になったときは、フィールド配置が変わる可能性がある。エージェント側は `schemaVersion` を必ず確認

---

## 6. 将来の拡張候補（Phase ごと）

- **Phase 3（Google Calendar）**: `selfRunning.calendarEventId`, `awaitingAttendance.calendarEventId` を追加
- **Phase 4（密度強化）**: `syncing.note`（今回やりたいこと）、`selfRunning.bankedQuestions[]`（エージェントが次回 sync のために積んだ質問一覧）、`utilization` ブロック（self-running 中の実稼働時間メトリクス）
- **Phase 5（複数プロジェクト）**: Workspace ごとの state.json は変わらないが、俯瞰用に別の集約ファイルを提供する可能性

---

## 7. 関連

- 書き込み側実装: `Sources/Async/AgentStateEmitter.swift`（予定、plan.md §5.3）
- Claude Code hook 本体: `Resources/AgentTemplates/prompt-hook.sh`（予定、plan.md §5.3.4）
- エージェント期待振る舞い: `spec.md` §7.4
