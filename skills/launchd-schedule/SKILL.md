---
name: launchd-schedule
description: |
  macOSのlaunchdで定期タスクを実行するスケジューラ。
  3モード: session(Claude対話), script(Codex CLI), exec(任意コマンド)。
  「スケジュール登録して」「スケジュール一覧」「スケジュール変更」「スケジュール削除」「今すぐ実行」で起動。
  「巡回スケジュール作って」「定期実行を設定して」でも起動。
---

# launchd-schedule スキル

macOSのlaunchdで定期タスクを実行する。Claude CLIだけでなく任意コマンドも対応。

## 操作

### create — スケジュール登録

3つのモードを選択可能:
- **session**（デフォルト）: tmux上でClaudeセッションに入りプロンプトを送信（Claudeサブスク維持）
- **script**: Codex CLI非対話実行（`codex exec --full-auto --model gpt-5.5`）。旧 `claude -p` は従量課金化のためCodexへ移行
- **exec**: 任意コマンドを直接実行（LLM不要。Python/bash等）

```bash
SKILL_DIR=$(find .claude/skills/launchd-schedule -name manage-schedule.sh -exec dirname {} \; | head -1)/..

# sessionモード（Claude対話、デフォルト）
bash "$SKILL_DIR/scripts/manage-schedule.sh" create \
  "<name>" "<cron-expr>" "<tmux-session>" "<workdir>" "<claude-cmd>" "<prompt>"

# scriptモード（Codex CLI非対話）
# 5番目の <claude-cmd> 引数は後方互換のため残っているが現在は無視される
# （内部で codex exec --full-auto --model gpt-5.5 が固定で使われる）
bash "$SKILL_DIR/scripts/manage-schedule.sh" create \
  "<name>" "<cron-expr>" "<tmux-session>" "<workdir>" "" "<prompt>" script

# execモード（任意コマンド。Claude不要）
bash "$SKILL_DIR/scripts/manage-schedule.sh" create \
  "<name>" "<cron-expr>" "" "<workdir>" "<command>" "<args>" exec
```

引数:
- `name`: スケジュール名（英数字ハイフン）
- `cron-expr`: cron式（分 時 日 月 曜日）。例: `0 3 * * *` = 毎日3:00, `*/5 * * * *` = 5分毎
  - `*/N`形式はlaunchdのStartInterval(N×60秒)に自動変換
- `tmux-session`: tmuxセッション名（execモードでは空文字""でOK）
- `workdir`: ワークディレクトリ
- `claude-cmd`: sessionモード→claudeコマンド、scriptモード→無視（Codex固定）、execモード→実行コマンド
- `prompt`: session/scriptモード→プロンプト、execモード→コマンド引数

例（Claude対話モード）:
```bash
bash "$SKILL_DIR/scripts/manage-schedule.sh" create \
  "daily-check" "0 3 * * *" "my-session" \
  "/path/to/project" \
  "claude --dangerously-skip-permissions" "/my-task"
```

例（Python script）:
```bash
bash "$SKILL_DIR/scripts/manage-schedule.sh" create \
  "data-fetch" "0 6 * * *" "" \
  "/path/to/project" \
  "python3 scripts/fetch_data.py" "--all" exec
```

### list — スケジュール一覧

```bash
# 現在のプロジェクトのスケジュールのみ表示（デフォルト）
bash "$SKILL_DIR/scripts/manage-schedule.sh" list

# 全プロジェクトのスケジュールを表示
bash "$SKILL_DIR/scripts/manage-schedule.sh" list --all

# 特定プロジェクトのスケジュールを表示
bash "$SKILL_DIR/scripts/manage-schedule.sh" list <project-name>
```

デフォルトではカレントディレクトリ名でフィルタし、自プロジェクトのスケジュールのみ表示。
各スケジュールにはProject名が表示される（plistのSCHEDULE_PROJECT環境変数から取得）。

### update — スケジュール変更

```bash
bash "$SKILL_DIR/scripts/manage-schedule.sh" update "<name>" "<new-cron-expr>"
```

例: 毎日3:00 → 毎日6:00に変更
```bash
bash "$SKILL_DIR/scripts/manage-schedule.sh" update "daily-check" "0 6 * * *"
```

### run — 即時実行

登録済みスケジュールをスケジュール時刻を待たずに今すぐ実行する。

```bash
bash "$SKILL_DIR/scripts/manage-schedule.sh" run "<name>"
```

### delete — スケジュール削除

```bash
bash "$SKILL_DIR/scripts/manage-schedule.sh" delete "<name>"
```

## 動作の仕組み

全モード共通で `guard-execution.sh` が最初に呼ばれ、二重起動防止とcooldownチェックを行う。

```
launchd → guard-execution.sh <name> -- <実コマンド>
              ├─ pgrep で同名スケジュールの既存プロセスをチェック → 重複ならSKIP
              ├─ cooldownファイルチェック → 有効ならSKIP
              └─ 実コマンドを実行
```

### sessionモード
guard → `run-scheduled-prompt.sh` → tmux + Claude対話

### scriptモード
guard → `run-scheduled-script.sh` → tmux + `codex exec --full-auto --model gpt-5.5`
（環境変数 `CODEX_MODEL` / `CODEX_CMD` で上書き可。レートリミット検出時は1時間cooldown）

### execモード
guard → `bash -c "cd workdir && command"`

## ファイル配置

| パス | 用途 |
|------|------|
| `~/Library/LaunchAgents/com.harness-schedule.*.plist` | launchdジョブ定義 |
| `~/.local/share/harness-schedule/logs/` | 実行ログ |
| `~/.local/share/harness-schedule/prompts/` | プロンプト保存 |

## 識別キーワード

全てのlaunchdジョブは `com.harness-schedule.` プレフィックス付き。
`launchctl list | grep harness-schedule` で一覧取得可能。

## 注意事項

- macOS専用（launchd依存）
- Mac起動中のみ実行。スリープ復帰時は未実行分を実行
- tmuxが必要（`brew install tmux`）
- 初回Claude起動時にログインが必要な場合あり（手動対応）
