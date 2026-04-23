# rmux 固有の規約

`INDEX.md` と `spec.md` / `plan.md` を読んだ上で、実際にコードを書くときの規約。

---

## 1. 用語（再掲、詳細は spec §1.2）

| 用途 | 使うもの | 使わないもの |
| --- | --- | --- |
| UI ラベル | `Sync 中` / `Sync を終える` / `次の Sync は X 後` | 「同期」「会議」 |
| UI ラベル | `自走中` | 「バックグラウンド中」「非同期中」 |
| UI ラベル | `Ready to sync` / `Overdue` | 日本語への無理な直訳 |
| コード enum case | `preparing` / `syncing` / `selfRunning` / `awaitingAttendance` | 他の綴り |

エージェント向けテキスト（hook 出力、`CLAUDE.async.md` テンプレ）は **英語固定**。ローカライズ対象外。

---

## 2. コード配置

### 新規ファイル
原則 `Sources/Async/` 下（ディレクトリは新設）:
- `Sources/Async/AgentStateEmitter.swift`
- `Sources/Async/SyncSessionScheduler.swift`
- `Sources/Async/ReadyToSyncOverlay.swift`
- `Sources/Async/SelfRunningOverlay.swift`
- `Sources/Async/OverdueOverlay.swift`
- `Sources/Async/SyncElapsedHUD.swift`
- `Sources/Async/ScheduleNextSyncSheet.swift`

### 既存ファイルへの追加（plan.md に列挙された箇所のみ触る）
- `Sources/Workspace.swift` — `WorkspaceMode`, `AsyncPhase`, 新規 `@Published` フィールド、遷移集約メソッド
- `Sources/TabManager.swift` — 最小限、必要な場合のみ
- `Sources/WorkspaceContentView.swift` — ZStack overlay 組み込み
- `Sources/ContentView.swift` `TabItemView` — phase インジケータ表示（Equatable 注意）
- `Sources/SessionPersistence.swift` — schema v1→v2
- `Sources/TerminalNotificationStore.swift` — 通知抑制ゲート
- `Resources/Localizable.xcstrings` — `async.*` キー追加
- `Resources/AgentTemplates/` — 新設、Async workspace 作成時に cwd にコピーするテンプレ（`CLAUDE.async.md`, `prompt-hook.sh`）

**それ以外の既存コードには原則触らない**。触る必要が出たら PROGRESS.md の「仕様の未解決 / 揺れ」に記録して議論。

---

## 3. ローカライズ

- プレフィックス `async.*` で統一（例: `async.phase.syncing.label`、`async.preparing.start`）
- すべての user-facing string は `String(localized: "key.name", defaultValue: "English fallback")` で包む
- `Resources/Localizable.xcstrings` に **ja / en 必須**。他言語は空文字で追加しておけば、公式翻訳で埋まる
- bare string literal を SwiftUI `Text()` / `Button()` / アラートタイトル等に書かない（cmux 既存規約）
- キー一覧は `plan.md` §7

---

## 4. 永続化

- schema version は `SessionSnapshotSchema.currentVersion`
- Phase 1 で v1 → v2（Async フィールド追加）
- Phase 3 で v2 → v3（`calendarEventId` 追加）
- 古いバージョンの JSON を decode できるよう、新フィールドはすべて optional + default 注入（plan.md §3）

---

## 5. Reload / ビルド

- **必ず** `./scripts/reload.sh --tag rmux-<feature>` を使う
- bare `cmux DEV.app` を開かない（CLAUDE.md の cmux 既存規約、rmux でも守る）
- タグ例: `rmux-async-data-model`, `rmux-overlay`, `rmux-scheduler`, `rmux-agent-state`, `rmux-hook`
- 古いタグ付きアプリ・socket / derived data を session 内で使い回したら掃除してから新タグ

---

## 6. Commit / ブランチ

- ブランチ: `rmux/phase<N>/<step-slug>` 形式（例: `rmux/phase1/data-model`, `rmux/phase1/overlay`）
- commit メッセージ prefix:
  - rmux 固有変更: `rmux: <imperative verb> ...`
    - 例: `rmux: add AsyncPhase enum to Workspace`
    - 例: `rmux: wire AgentStateEmitter into phase transitions`
  - upstream cmux と共通の修正（プラットフォーム / バグ fix 等）は prefix なし（upstream PR 候補として分離可能に）
- 1 commit = 1 論理単位。spec と plan の更新は本体実装とは別 commit に
- 回帰テスト用 commit 分割は cmux 既存規約（CLAUDE.md「Regression test commit policy」）に従う

---

## 7. テスト

- ローカルで E2E / UI は走らせない（cmux 既存規約）
- `xcodebuild -scheme cmux-unit` のみ安全
- rmux で unit カバーすべきもの（plan.md §9.1）:
  - フェーズ遷移の不変条件
  - 復元時 past-due → awaiting-attendance 書き換え
  - 経過 / 超過計算
  - v1 セッションファイルの decode
  - `.cmux/state.json` のシリアライズ形式
- ソースコード文字列を grep するだけの fake テストは書かない（cmux 既存「Test quality policy」）

---

## 8. Pitfalls（rmux 固有、実装時に踏み抜きやすいもの）

- **`TabItemView` の Equatable 最適化**: Async の phase / 経過時間を追加するときは `==` 関数を更新。忘れるとタイピングレイテンシが悪化する（cmux CLAUDE.md pitfalls にも既出）
- **ZStack overlay がキー入力を透過させない**: overlay ビューは `.contentShape(Rectangle())` + 明示ハンドラで入力を吸収。事故でターミナルにキーが届くのを防ぐ
- **`TerminalNotificationStore` の通知抑制ゲートは 1 箇所に集約**: 下流コードに判定を散らすと抑制の破れが発生しやすい
- **`.claude/settings.json` マージ時の既存設定破壊**: ユーザが既に hook を登録している場合、配列に追記する形で既存を壊さない。JSON パースエラー時は上書きせず warning だけ
- **Hook 配布の冪等性**: Workspace 再作成や設定再書き込みで `.cmux/prompt-hook.sh` パスのエントリが重複しないこと
- **`.cmux/state.json` の partial read**: atomic write（tempfile → rename）を守る
- **Bonsplit / Ghostty サーフェスの unmount**: 絶対にやらない。overlay で覆うのみ

---

## 9. Spec / Plan の更新規約

### 9.1 原則: latest-only
`spec.md` / `plan.md` / `INDEX.md` / `agent-state.md` には **最新の決定事項だけ** を書く。コンテキストがリセットされた次のセッションが読んで一貫した現在像を得られることを最優先する。

残してはいけない（NG パターン、左 → 右に書き換える）:

| NG 表現 | OK 表現 |
| --- | --- |
| 「MVP から外し、後続 phase に送ったもの」 | 「Phase 2 以降で扱うもの」 |
| 「MVP では X できないので Phase N で Y」 | 「Phase N は Y を実現する」 |
| 「MVP 第 1 弾」「第 2 弾」 | 「Phase 1」「Phase 3」（具体 phase 番号） |
| 「いま A だけ、将来 B」 | 「Phase 1 は A、Phase N で B を追加する」 |
| 「これまで通り X」 | 具体 section 参照付きで X |
| 「以前は Y だったが今は Z」「元々 A だったのを B に変えた」 | 最新の Z / B だけを書く |

残してよい:
- **永続的な設計判断の根拠**: 「X を採用しない理由は Y」「この制約があるので Z を選ぶ」といった eternal rationale（例: spec §7.2 #3「PTY 直接注入を採用しない: TUI のタイミング / 意味論の問題」）
- フェーズごとのスコープ宣言: 「Phase N は A を扱う、Phase M は B を扱う」
- 未解決の検討事項（ただしこれは `PROGRESS.md` 側に置く）

チェック手順: `grep -nE "以前|元々|前は|これまで通り|かつて|当初|MVP から外|第 [12] 弾|送った|落とした" spec.md plan.md` を実行し、ヒットがあったら判断して書き換える。

### 9.2 仕様の揺れ / 未解決の扱い

- 見つけたら `PROGRESS.md` の「仕様の未解決 / 揺れ」に追記
- 決着したら `spec.md`（理想挙動）に昇格させ、その後 `plan.md`（実装計画）の該当箇所も追随させる
- 昇格した項目は `PROGRESS.md` から削除する

### 9.3 整合性の担保

- 節番号を動かすときは cross-ref を `grep '§[0-9]'` で全ファイル洗う
- spec を変えたら plan の該当箇所を必ず見直す（逆も同様）
- 用語変更時は `INDEX.md` / `CONVENTIONS.md` / spec / plan / PROGRESS のすべてに波及させる

### 9.4 ファイル別の責務

| ファイル | 役割 | 書くべきもの |
| --- | --- | --- |
| `prompt.md` | ビジョン原典（保全） | 元の思想。用語は現行に揃える |
| `spec.md` | 理想挙動の仕様 | フェーズ・UI・通知・エージェント連携・エッジケース・ロードマップ見出し |
| `plan.md` | 実装計画 | Phase 1 MVP の具体ステップ、Phase 2–5 の詳細 |
| `INDEX.md` | エントリポイント | 読む順・用語要約・絶対規約 |
| `CONVENTIONS.md` | 開発規約 | コード配置・命名・コミット・pitfalls |
| `PROGRESS.md` | 実装の実況 | 現在の焦点・次アクション・未解決・セッションログ |
| `agent-state.md` | 公開スキーマ | `.cmux/state.json` の形式と読み方 |

---

## 10. Upstream マージの扱い

- `upstream` = `manaflow-ai/cmux` からの merge は基本無害（`docs-rmux/` を触らないため）
- `CLAUDE.md` / `AGENTS.md` が更新された場合:
  - 先頭の **rmux ヘッダセクション** を維持したまま、それ以降の cmux agent notes 部分をマージ
  - rmux 固有の追記と競合する場合は rmux 側を優先
- コード側で upstream とコンフリクトしたら、機能単位で spec / plan と突き合わせて判断
