# 仕様書: Async Workspace と Sync Session

この文書は実装ではなく **理想の挙動** を定義する。実装計画は後続の `plan.md` で別途扱う。

---

## 1. 用語

### 1.1 概念

| 用語 | 定義 |
| --- | --- |
| **Workspace** | cmux の現行概念そのまま。サイドバーに並ぶタブ 1 つ。 |
| **Normal workspace** | 現行の cmux と同じ使い勝手。スケジューリングはない。人間が常に張り付く / 自由に触る。 |
| **Async workspace** | エージェントが基本は自走し、人間は時々チェックインする前提の Workspace。「プロジェクト」相当。 |
| **Sync session** | Async workspace で人間とエージェントが同期的に対話する時間枠。ここで要件定義・進捗レビュー・次回予定の設定を行う。 |
| **Self-running** | Sync session と Sync session の間の時間。エージェントが自走している。人間からは進捗が見えない。 |
| **Awaiting attendance** | 次の sync session の予定時刻は過ぎたが、まだ人間が来ていない / 開始していない状態。 |
| **Preparing** | Sync session に入る直前、Ready to sync 画面が出ている状態。ここで今回の予定時間（time box）を設定する。 |
| **Planned duration** | Sync session を「これくらいで終わらせたい」と宣言した時間。30 分単位で設定する。 |
| **Elapsed time** | 今の sync session を開始してから経過した時間（HH:MM:SS）。 |

Workspace はいずれか 1 つのタイプを持つ。Normal ↔ Async の相互変換は可能（§8.3, §8.4）。

### 1.2 UI 用語（日本語 / 英語）

日本語 UI では **`Sync` / `Async` を英単語のまま** 扱い、自然な日本語助詞と組み合わせる（例: `Sync 中`、`Sync を終える`）。「同期」「会議」といった直訳は使わない。`自走` だけは日本語として自然なのでそのまま用いる（prompt.md 由来）。

| 概念 | 内部名 | 英語 UI | 日本語 UI |
| --- | --- | --- | --- |
| Workspace タイプ | normal | Normal | Normal |
| Workspace タイプ | async | Async | Async |
| セッションそのもの | — | Sync session | Sync セッション（短縮時は Sync） |
| フェーズ | preparing | Ready to sync | Ready to sync |
| フェーズ | syncing | In sync | Sync 中 |
| フェーズ | self-running | Self-running | 自走中 |
| フェーズ | awaiting-attendance | Overdue | Overdue |
| 予定時間 | plannedDuration | Planned | 予定時間 |
| 経過時間 | — | Elapsed | 経過時間 |
| 次の sync までの残り時間 | — | Next in X | 次の Sync まで X |

#### アクション ラベル

| アクション | 日本語 UI |
| --- | --- |
| 最初の sync を始める | 最初の Sync を始める |
| syncing を終えて次回を予定する | Sync を終える / 次回を予定… |
| self-running から割り込み開始 | 今すぐ Sync |
| awaiting-attendance から開始 | 今すぐ開始 |
| 次回時刻を組み直す | リスケ |
| preparing で開始確定 | 開始 |
| preparing を中断 | キャンセル |
| スケジュール再設定（self-running overlay） | スケジュール変更 |

#### メッセージ / 見出し

| 状況 | 日本語 UI |
| --- | --- |
| self-running overlay 見出し | 次の Sync は **X** 後 |
| awaiting-attendance overlay 見出し | Overdue — 予定は **X** 前 |
| preparing overlay 見出し | Ready to sync |
| Sync 予定時刻到達の macOS 通知 | Sync の時間です: `<workspace>` |
| エージェント異常通知 | 自走が停止しています: `<workspace>` |

---

## 2. Workspace タイプ

### 2.1 Normal
- 現行 cmux の挙動のまま。何も変更しない。
- タブアイコンや状態ドットで「Normal」であることはあえて強調しない（デフォルトなので）。

### 2.2 Async
- 生成時に「Async として作る」選択があり、既存の Normal から後で変換も可能。
- **4 つのフェーズ** のいずれか 1 つを常に持つ:
  - `preparing` (Ready to sync) — 予定時間を設定中
  - `syncing` (Sync 中) — Sync session 中
  - `self-running` (自走中) — 次の Sync session が未来にある。エージェントは自走中
  - `awaiting-attendance` (Overdue) — 予定時刻は過ぎたが、まだ開始されていない
- 直近の Sync session 終了時刻、次回 Sync session 予定時刻を保持する。
- `syncing` 中のみ `syncStartedAt` と `plannedDuration` を保持する。

---

## 3. Async Workspace のライフサイクル

```
[create async]
      │
      ▼
(初回 Sync session の予定／既定「今すぐ」)
      │
      ├──「今すぐ」─────────▶ preparing
      │                          │ 予定時間を設定して [開始]
      │                          ▼
      │                        syncing
      │                          │ [Sync を終える / 次回を予定]
      │                          ▼
      └──「後で (時刻選択)」──▶ self-running
                                 │
                   ┌─────────────┤
                   │             │ [予定時刻到達] → 到達通知 + self-running → awaiting-attendance
                   │             │
                   │             │ [今すぐ Sync] → preparing
                   │             ▼
                   │       awaiting-attendance
                   │         │   │
                   │         │   └─「今すぐ開始」──▶ preparing
                   │         │
                   │         └──「リスケ」────────▶ self-running（新しい予定で）
                   │
                   └── 人間が「今すぐ Sync」─▶ preparing
```

**重要**:
- 予定時刻が来ても自動で `syncing` には入らない。時刻到達時は `awaiting-attendance` に遷移するだけ。
- `syncing` には必ず `preparing` を経由してしか入れない。Ready to sync 画面で予定時間を決める儀式を飛ばせない。

### 3.1 フェーズ境界の原則
- **syncing → self-running**: 終了モーダルで次回予定を決めなければ self-running に入れない。予定なしの self-running は存在しない。
- **self-running → awaiting-attendance**: 自動。予定時刻到達で遷移。
- **self-running → preparing**: ユーザが「今すぐ Sync」を押したとき。
- **awaiting-attendance → preparing**: ユーザが「今すぐ開始」を押したとき。
- **awaiting-attendance → self-running**: ユーザが「リスケ」で新しい時刻を決めたとき。
- **preparing → syncing**: ユーザが予定時間を設定して「開始」を押したとき。
- **preparing → (直前のフェーズ)**: 「キャンセル」で戻る。
- フェーズ遷移はすべて **サイドバーの選択を奪わない**（§6.2）。
- フェーズ遷移はすべてエージェント側にも伝播する（§7）。

---

## 4. Sync Session の流れ

### 4.1 Preparing（Ready to sync 画面）
- `syncing` に入る前に必ず通る画面。時間を何となく溶かさないための儀式。
- 画面構成:
  - Workspace 名
  - 見出し: 「Ready to sync」
  - 予定時間ピッカー: 30 分単位の離散値（15 min / 30 min / 45 min / 1 h / 1.5 h / 2 h / 3 h ...）。既定は 30 min。
  - 任意: 「今回やりたいこと」メモ欄（ロードマップ扱い、MVP は無し）
  - ボタン: 「開始」「キャンセル」
- 「開始」を押した瞬間から `syncStartedAt = now`、`plannedDuration = 選択値` を確定し `syncing` へ遷移する。
- 「キャンセル」で直前のフェーズに戻る（遷移元が awaiting-attendance なら awaiting-attendance、self-running なら self-running）。

### 4.2 Syncing 中の UI
- Workspace の表示は **通常のターミナル** に戻る（overlay は外れる）。
- サイドバー選択がその Workspace でなければ、**選択は自動では奪わない**。macOS 通知 + サイドバーの強調で知らせる。通知をタップしたときにのみ該当 Workspace に切り替わる。
- 直前の self-running / awaiting-attendance 中に積み上がっていたエージェント通知は、この時点で通知パネルに通常通り表示される（§5.4）。
- **経過時間 HUD**（§6.1.4）を常時表示する。

### 4.3 中にできること
- ターミナルでエージェントと自由に対話（通常の cmux と同じ）。
- 進捗の振り返り（self-running 中のログ・通知がここでまとめて見える）。
- 稼働率レビュー（ロードマップ。§10）。
- 次回予定・permission 見直し（permission はロードマップ。§10）。

### 4.4 出る（次回予定の設定モーダル）
- 「Sync を終える / 次回を予定…」アクションは `syncing` 中だけ表示。
- モーダル構成:
  - **クイックピック**: 「今から X 時間後」数点 + 一週間後までのきりのいい時刻候補（例: 翌日 09:00 / 18:00、来週月曜 09:00 など）
  - **カレンダーピッカー**: 手動で日時を選ぶ。候補粒度は 30 分
  - Google Calendar 連携が有効なら、空いている時間帯だけが選択可能（§9）
  - 確定 → `self-running` へ。Google Calendar に予定を作成（連携有効時）
- 事前通知（5 分前など）は cmux 側からは **出さない**。Google Calendar のリマインダーに任せる（§5.1）。

### 4.5 Sync session の中断 / 延長
- もう少し話したい: 終了ボタンを押さなければずっと `syncing`。経過時間が予定時間を超えると赤点滅で警告（§6.1.4）。
- 早めに切り上げ: 通常の終了フローで次回を短めに設定するだけ。特別扱いしない。

---

## 5. 通知ポリシー

通知は 2 方向ある。**ユーザ通知**（cmux → 人間）と **エージェント通知**（ターミナル OSC 9/99/777 → cmux）。ポリシーは正反対。

### 5.1 ユーザ通知（cmux → 人間）

macOS ローカル通知 + サイドバーの強調を基本とする。通知をタップしたときだけ該当 Workspace にフォーカスが移る。

| イベント | 既定 | 目的 |
| --- | --- | --- |
| Sync 予定時刻到達 | ユーザ通知（音あり）+ サイドバーバッジ（オフ不可） | 遅刻に気付かせる。フェーズは `awaiting-attendance` へ遷移。 |
| エージェント異常停止（self-running / awaiting-attendance 中） | ユーザ通知 | 自走が壊れたことは知らせる（進捗そのものは見せない） |
| 通常のエージェント通知（self-running / awaiting-attendance 中） | **完全抑制**（§5.3） | 覗き見の誘惑を排除 |

事前通知（5 分前など）は cmux 側からは出さない。Google Calendar の標準リマインダーで十分（§9）。

### 5.2 エージェント通知（OSC → cmux）

cmux は既存で OSC 9/99/777 を拾い、サイドバーバッジ / 通知パネル / MenuBarExtra 未読数に反映している。Async workspace のフェーズにより扱いが変わる（§5.3）。

### 5.3 Self-running / Awaiting-attendance 中の通知抑制
Async workspace が `self-running` または `awaiting-attendance` の間、そこ由来のエージェント通知は：

- **サイドバーバッジに出さない**（未読カウントに加算しない）
- **MenuBarExtra 未読数に加算しない**
- **通知パネルに表示しない**
- **macOS 通知を出さない**
- **音・dock バウンスも含め一切の可視化をしない**
- **内部には蓄積する**（次の syncing で普通に見える）

エージェント自身に通知を出させない方針（Claude Code の設定など）はユーザが別途取り決める領域で、cmux はあくまで表示側の抑制を保証する。

例外: `self-running` / `awaiting-attendance` 中でもエージェントが **停止した / エラー** になったことはユーザ通知を出す。進捗は見せないが自走が壊れたことは知らせる。

### 5.4 Sync session に入った後の扱い
Sync session に入った瞬間、それまで蓄積されていたエージェント通知は通知パネルに **通常通り** 並ぶ。サマリやバッジの派手な演出はしない。ユーザは必要なら通知パネルで自分のペースで遡る。

---

## 6. UI 原則

### 6.1 Async Workspace の UI（フェーズ別）

全画面 opaque の overlay で terminal を覆う（terminal プロセスは落とさない）。フェーズにより中身が変わる。

#### 6.1.1 `self-running` overlay
- Workspace 名
- 「次の Sync は **X** 後」（相対時刻、1 分粒度で更新）
- 絶対時刻（例: `2026-04-24 09:00`）
- ボタン:
  - 「スケジュール変更」
  - 「今すぐ Sync」→ preparing へ

#### 6.1.2 `awaiting-attendance` overlay
- Workspace 名
- 「Overdue — 予定は **X** 前」+ 元の予定時刻
- ボタン:
  - 「今すぐ開始」→ preparing へ
  - 「リスケ」→ 日時ピッカー（§4.4 と同じ UI）

#### 6.1.3 `preparing`（Ready to sync）overlay
- Workspace 名
- 見出し: 「Ready to sync」
- 予定時間ピッカー（30 分単位、§4.1）
- ボタン: 「開始」「キャンセル」
- 開始を押すまでは syncing に入らない。ターミナルも隠れたまま。

#### 6.1.4 `syncing` の経過時間 HUD
- `syncing` 中は overlay が外れて通常のターミナルに戻る。
- 画面の目立つが邪魔にならない位置（案: ターミナル上部の Workspace タイトル隣、もしくは左下の小さな pill）に経過時間を **常時** 表示する:
  - 「**00:24:18** / 予定 00:30:00」
  - フォーマット: `HH:MM:SS`、1 秒更新
- **予定時間を超えたら**: 数値を **赤字で点滅**（約 1 Hz）させる。超過時間も表示（例: 「**00:32:14** / 予定 00:30:00（+00:02:14）」）。
- HUD をユーザが非表示にする術はあえて用意しない（ダラダラ抑止）。

#### 6.1.5 経過時間の計測ポリシー
- `syncStartedAt` を基準に壁時計で計測する。アプリを閉じても時間は進む（閉じている間も「セッション中」と見なす）。
- 意図的な「一時停止」は設けない。離席や昼食で数時間経ったら素直に赤点滅で責められる仕様にする。

#### 6.1.6 「今すぐ Sync」の誤爆抑止（将来的な摩擦レイヤ）
- MVP では単純に confirm ダイアログ 1 枚で済ませる。
- `self-running` からの割り込みは気軽に押すと「バックグラウンドで完全に忘れる」狙いが崩れるため、Phase を重ねるにつれ強い摩擦（例: Workspace のフルパス手入力で初めてボタンが有効化）を段階的に足す（plan.md §11 参照）。
- `awaiting-attendance` 側はもう遅刻合意済みのため摩擦なし。

#### 6.1.7 **Peek ボタンは作らない**
「ちょっとだけ覗く」UI は意図的に無い。見たくなったら「今すぐ Sync」で preparing に入る。

### 6.2 サイドバー
- Normal Workspace: 現行と同じ。
- Async Workspace:
  - `preparing`: 「Ready」インジケータ
  - `syncing`: 目立つインジケータ（`Sync 中` バッジ）+ 経過時間（超過時は赤）
  - `self-running`: 小さな時計アイコン + 残り時間（`2h` / `18m` / `明日`）。通知バッジは出ない（§5.3）
  - `awaiting-attendance`: 遅刻を示すインジケータ（例: オレンジの "!" ＋「Overdue 45m」）
- サイドバーの選択は **勝手に奪わない**。自動遷移はユーザ選択を変えない。ユーザが macOS 通知をタップしたときだけ該当 Workspace を選択状態にする。

### 6.3 エージェント異常時の挙動
- Self-running / awaiting-attendance 中にエージェントが止まった / エラー画面のまま動いていないことが検出された場合:
  - サイドバーに「⚠ 自走が停止しています」の控えめな印
  - macOS 通知を 1 度出す
  - Workspace のフェーズは勝手に変えない
- 検出機構は未定（PTY 活動のタイムアウト・OSC 通知の終了マーカー等）。MVP では未対応で良い。

### 6.4 MenuBarExtra
- Async workspace の self-running / awaiting-attendance 中は未読カウントに加算しない（§5.3）。
- 代わりに「N 個の Workspace が自走中 / 次の Sync は X 後」のようなステータス表示を持てるとよい（ロードマップ）。

---

## 7. エージェント連携 (Agent awareness)

Async workspace のフェーズは **エージェント側も常に自覚** している必要がある。そうでないと:

- Sync session 中に permission の事前交渉を提案できない（気付いたら self-running に入って permission 不足で詰まる）
- Self-running に入る直前に「人間に訊いておくべきこと」をまとめられない
- Sync の残り時間を意識したペース配分ができない
- 要件定義フェーズで「この粒度で自走させて大丈夫か」の自己判定ができない

cmux → 人間の UI が §6 なら、**cmux → エージェントの UI** が本節。cmux はエージェントに状態を継続的に提示する責務を持つ。

### 7.1 エージェントが知るべき情報

- **現在のフェーズ**: `preparing` / `syncing` / `self-running` / `awaiting-attendance`
- **Syncing 中**: `syncStartedAt` / `plannedDuration` / 経過時間 / 残り時間 / 超過分
- **Self-running 中**: `nextSyncAt` / 残り時間
- **Awaiting-attendance 中**: 本来の予定時刻 / 遅延
- **履歴**（Phase 4 以降）: 直近 sync の終了時刻、前回のメモ、前回 banked questions
- **Workspace メタデータ**（Phase 5 以降）: 名前、cwd、プロジェクトの目的
- **Permission の現状**（Phase 4 以降）

### 7.2 情報の提供手段

以下を組み合わせる。単独では不足。

1. **環境変数（静的 snapshot、agent-agnostic）**
   エージェントプロセス起動時に `CMUX_WORKSPACE_ID`, `CMUX_PHASE`, `CMUX_SYNC_STARTED_AT`, `CMUX_PLANNED_DURATION`, `CMUX_NEXT_SYNC_AT`, `CMUX_STATE_FILE` 等を注入。読むだけ。フェーズ変化には追随しない。
2. **状態ファイル（動的、agent-agnostic）**
   Workspace cwd 配下 `.cmux/state.json`（gitignore 前提）を cmux が継続的に書く。エージェントは必要なとき読みに行く。複数ハーネスに対応できる。スキーマを公開ドキュメント化する。
3. **Claude Code の `UserPromptSubmit` hook（ユーザ発話ごとに自動注入、Claude Code 専用）**
   cmux が Async workspace 初期化時に cwd の `.claude/settings.json` に `UserPromptSubmit` hook を登録する。Hook は `.cmux/state.json` を読んで整形し stdout に出す。Claude Code はこの stdout をユーザプロンプトに prepend して会話に含める。詳細は §7.3。

   PTY への直接テキスト注入は **採用しない**: Claude Code が TUI 常駐しているため、任意の瞬間に stdin を書くとタイミング（ツール実行中・応答待機中・質問待機中）や意味論（前の質問への回答として解釈されるリスク）で壊れやすい。Hook は挿入点が明確なので安全。
4. **MCP サーバ（双方向 + 能動 push、Phase 4 以降）**
   cmux を MCP サーバとして提供し、`get_cmux_state`, `queue_question_for_next_sync`, `checkpoint_note` のようなツールを expose。Hook は「ユーザが喋ったとき」しか発火しないため、**能動 push**（self-running 中のリアルタイム警告、エージェントからの人間呼び戻し要請）は MCP の担当。

**MVP（Phase 1）は 1 + 2 + 3 で成立**。Claude Code 以外のエージェントは 1 + 2 と個別機構で後追い対応（§7.7）。

### 7.3 Hook 出力の形式

§7.2 #3 の具体仕様。Hook は **ユーザが発話した瞬間** にだけ発火し、現在のフェーズのスナップショットを会話に prepend する。遷移イベントごとの能動 push ではなく、**毎発話での状態再提示** という設計。

#### 7.3.1 Hook の登録
- cmux が Async workspace 作成時に cwd の `.claude/settings.json` に `UserPromptSubmit` hook を追加する（既存設定があればマージ）
- 実行スクリプトは `.cmux/prompt-hook.sh`（cmux が配布、実行権限付き）
- Claude Code はユーザ発話ごとにこのスクリプトを実行し、stdout を会話コンテキストに prepend する

#### 7.3.2 Hook の出力内容
- 常に `[cmux] ` 接頭辞で始まる数行
- 現在のフェーズ / 関連時刻 / 行動リマインダー

**Syncing 中（残り 11 分）**:

```
[cmux] phase=syncing elapsed=00:18:34 planned=00:30:00 remaining=00:11:26
[cmux] Surface permission gaps & blocking questions now. Self-running starts when this sync ends.
```

**Syncing 超過中**:

```
[cmux] phase=syncing elapsed=00:32:14 planned=00:30:00 over=00:02:14
[cmux] Time is up. Wrap up and end the sync.
```

**Self-running 中**:

```
[cmux] phase=self-running next_sync=2026-04-23T18:00 remaining=5h12m
[cmux] Human is not watching. Don't ask clarifying questions; log them for next sync.
```

**Awaiting-attendance**:

```
[cmux] phase=awaiting-attendance scheduled=2026-04-23T14:00 overdue=00:45:12
[cmux] Scheduled sync time has passed; human not yet here. Continue as before.
```

#### 7.3.3 Hook が発火しないケース
Hook は **ユーザがプロンプトを送信した瞬間** にしか発火しない。したがって:

- ユーザが黙っている間のフェーズ遷移は、次の発話まで伝わらない
- Syncing 中の残り時間警告も、ユーザが喋らなければ届かない

実用上の許容:
- Syncing 中は人間が能動的に喋っている。次ターンで必ず伝わる
- Self-running → awaiting-attendance は人間が見ていない時間帯なので、エージェント側がその瞬間に知ったところで特にやることがない
- Syncing → self-running は人間の明示操作（「Sync を終える」）が起点。遷移直後はエージェントに発話しておらず、次回 sync 開始時に最新状態が伝わる

**能動 push** が本当に要るケース（self-running 中のリアルタイム警告、エージェントからの「今すぐ人間呼び戻し」要請など）は Phase 4 で MCP サーバを足して対応する。

### 7.4 エージェントに期待する振る舞い（convention）

cmux はエージェントのロジック自体を書き換えない。以下は「脳に優しい」ワークフローに適合する振る舞い。ユーザが各エージェントの設定（Claude Code なら CLAUDE.md / system prompt）で明文化するのが自然。cmux はこれをガイドするためのテンプレート（例: プロジェクトに配布する `CLAUDE.async.md`）を提供してもよい。

- **Preparing 中**: 本来エージェントは前セッションの続きの自走状態にあるかもしれない。cmux からの遷移メッセージ（§7.3）を受け取ったら、syncing 開始時のまとめの準備を始める。
- **Syncing 中**:
  - 前回 self-running 中の進捗を最初に要約
  - Permission 不足 / 仕様の曖昧さ / self-running 中に詰まった箇所を優先して提示
  - 状態ファイルの残り時間を意識し、終盤で「この話は次回で良いか」を確認
  - 未解決の質問を self-running に持ち越さない方針
- **Self-running / awaiting-attendance 中**:
  - 人間に訊くより「保守的に進めてログに残す」を優先
  - OSC 通知（9/99/777）を自発的に抑制（cmux 側でも抑制されるがログが汚れない）
  - 「次回 sync で話したいこと」のキューを積極的に維持
  - Permission 不足に当たったら **そこで止まる**（勝手に回避しない）。ユーザは次回 sync でキューを見る

### 7.5 エージェントから cmux への情報（逆方向、Phase 4 以降）

Phase 4 以降は MCP 経由で cmux ← エージェントの経路も開ける。MVP では未対応だが、状態ファイル / 環境変数の設計時点でインタフェースの拡張可能性を意識する。

- **Checkpoint note**: 「次回 sync で人間に聞きたいこと」をエージェントが登録 → syncing 入り直後にダッシュボードに並ぶ（Phase 4 の `SyncDashboardView` と統合）
- **早期呼び戻し要請**: エージェントが「今すぐ人間が必要」と判断したとき awaiting-attendance に前倒し（乱用防止に rate limit 必須）
- **停止宣言**: 自発的な自走終了の明示（異常停止と区別）

### 7.6 境界と非目標

- cmux はエージェントのロジック自体を書き換えない。情報提供と経路提供にとどめる。
- エージェントが state を誤認しても cmux 本体の整合は壊れない（state は表示目的であって権限ゲートではない）。
- Prompt injection 対策は別トピック。cmux のメッセージには `[cmux] ` 接頭辞を付け、ハーネス側で識別する前提。
- `.cmux/state.json` はローカルファイルで、複数プロセスから読まれるが書き込みは cmux 1 点に統一する。

### 7.7 他エージェント（Codex, OpenCode 等）への拡張方針

- `.cmux/state.json` は agent-agnostic なプレーン JSON。スキーマを公開ドキュメント化。
- 環境変数も共通の `CMUX_*` 名前空間。
- Claude Code の `UserPromptSubmit` hook は Claude Code 固有機構。他エージェントはそれぞれの hook / context injection 機構を個別に組む（MVP は Claude Code 決め打ち、後続 phase で拡張）。
- MCP は Claude Code 優先、他エージェントは後追い。
- `[cmux] ` 接頭辞は全経路で共通とし、エージェント側で識別できるようにする。

---

## 8. 例外・エッジケース

### 8.1 アプリ / マシンを落として次の Sync 予定時刻を過ぎた
- 復元時、既に過ぎた予定を持つ Workspace は `awaiting-attendance` として復元される（§6.1.2 の overlay）。
- 自動では `syncing` に入れず、ユーザが「今すぐ開始 / リスケ」を選ぶ。

### 8.2 複数 Async workspace の Sync session が重なる
- **起こらないように設計する**。スケジュール決定時に他の Async workspace の予定と重ならないようにチェックする。
- Google Calendar 連携時は、その Workspace 自身の予定も含めて「空き時間」がそもそも候補に出ない（§9）。
- 連携無効時も cmux 内の他の Sync session との衝突はチェックして拒絶する。
- MVP (Phase 1) は単一プロジェクト想定のためこのチェックを実装しない（plan.md §11 Phase 5 以降）。

### 8.3 Normal → Async 変換
- 既存の Normal Workspace を途中で「Async にする」できる。
- 変換時の既定: 直ちに `preparing`（Ready to sync 画面）。そこから syncing に入る。

### 8.4 Async → Normal 変換
- いつでも可能。スケジュール破棄、overlay 解除、通知抑制解除。Google Calendar 連携時は該当予定を削除。
- 積んであった self-running / awaiting-attendance 中の未読通知は通知パネルに一括で戻る。

### 8.5 Sync session 中にアプリを落とす
- 次回起動時は `syncing` のまま復元する（self-running / awaiting-attendance に勝手に戻さない）。
- `syncStartedAt` と `plannedDuration` も保持しているので、経過時間 HUD は正しい壁時計経過を表示する（§6.1.5）。
- ユーザが意図的に session を終わらせる操作を経ない限り、次回予定は動かない。

### 8.6 Preparing 中にアプリを落とす
- 次回起動時は `preparing` のまま復元する。まだ予定時間が確定していないだけ。ユーザが開始またはキャンセルするまでその状態。

### 8.7 ターミナルプロセス自体が死んだ
- Self-running / awaiting-attendance 中: §6.3 の異常扱い。overlay は維持。
- Syncing 中: 通常の cmux と同じ挙動に委ねる。

### 8.8 `awaiting-attendance` を数日放置
- **そのまま放っておく**。自動リスケや自動開始はしない。人間が戻ってきて意図的に判断するまでこの状態でよい。

---

## 9. Google Calendar 連携

**理想挙動**: Sync session の予定は Google Calendar を「ソース」として扱う。cmux 内のスケジュールは必ず Google Calendar に対応する予定を持つ。

### 9.1 連携のオン・オフ
- 設定画面で Google アカウントを認証すると連携が有効になる。
- 連携がオフでも Async workspace は使える（ただしカレンダー衝突チェックは cmux 内の他の Async workspace に限られる）。

### 9.2 予定の作成・更新・削除
- `syncing → self-running` の終了モーダルで次回時刻を確定したタイミングで Google Calendar に予定を作成する。
- Sync session を delete / reschedule したら対応するカレンダー予定も更新する。
- Async workspace を削除したら将来の予定も削除する。
- 事前通知（5 分前など）は Google Calendar 側のリマインダーに任せる。cmux は独自に事前通知を出さない。

### 9.3 空き時間ベースのスケジューリング
- 予定ピッカーの候補は Google Calendar 上で **空いている時間帯** からのみ表示する。既に別の予定（会議、他の Sync session、など）が入っている時刻は選択肢に出さない（もしくは disabled）。
- これにより「別の Sync session と被る」ケースは構造的に発生しない。
- 候補粒度は **30 分**。

### 9.4 使用カレンダーの範囲
- MVP: プライマリカレンダー 1 つだけを空き判定に使う。
- 将来: 複数カレンダーを選択可能にする（空き判定対象と書き込み先を個別に指定）。ロードマップ。

### 9.5 外部からのカレンダー変更
- Google Calendar 側で対応する予定を削除 / 移動されたら、次回アプリ起動時（あるいはバックグラウンド同期時）に検出し:
  - 削除: cmux 側のスケジュールも破棄し、Workspace は `awaiting-attendance` 相当に寄せる（予定時刻を「直前に削除された時刻」として解釈）。ユーザは「今すぐ開始 / リスケ」で判断。
  - 移動: cmux 側のスケジュールも同期して更新する（Google Calendar 優先）。

### 9.6 不在 / 休暇との整合
- Google Calendar に「不在」「OOO」「終日予定」があればその時間帯も空きから除外される（§9.3）。
- 結果として、夜間・休日を避けた自然なリズムで Sync session が組まれることを期待する。

### 9.7 Google Calendar 連携を有効化しない場合
- Google Calendar 連携は Phase 3（§10）で実装される機能。Phase 1 では連携オフで動作する。
- 連携オフのときは「空き時間候補のフィルタ」と「Calendar 側イベントとの同期」が行われない。スケジュール選択は rmux 内のみで完結する（複数 Async workspace 間の衝突チェックも §8.2 の通り Phase 5 まで無い）。

---

## 10. ロードマップ（この spec の対象外）

- 稼働率レビュー（prompt.md §23）: self-running 中の実際のエージェント活動時間 / CPU 等をメトリクス化し、Sync session でグラフを見せる。
- Permission 事前交渉: Claude Code `settings.json` 等への介入。cmux の現行抽象の外。
- カレンダービュー（cmux 内）: 全 Async workspace の予定を時系列で俯瞰。
- Project 一覧ビュー: Async workspace だけの別リスト。
- MenuBarExtra の稼働状態表示拡張。
- caffeinate / `IOPMAssertionCreateWithName` による省電力抑止。
- エージェント異常検出の詳細化。
- Preparing 画面の「今回やりたいこと」メモ欄（次回 Sync で振り返りに使う）。
- Google Calendar 複数カレンダー対応。
- Sync session 中の離席検出 / 経過時間の一時停止（現状は壁時計固定）。
- Sync session 終了時の振り返りプロンプト（予定時間と実時間の乖離を意識させる）。
- MCP サーバ経由の cmux ↔ エージェントの双方向連携（§7.2 #4, §7.5）。
- Workspace フルパス手入力による「今すぐ Sync」の強い摩擦（§6.1.6）。
- 複数 Async workspace 間の Sync session 衝突チェック（§8.2）。
