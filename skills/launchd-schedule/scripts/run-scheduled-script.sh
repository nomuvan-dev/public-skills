#!/usr/bin/env bash
set -euo pipefail

# run-scheduled-script.sh — tmux上でCodex CLIをスクリプトモード実行（セッションに入らない）
#
# 旧仕様: `claude -p "prompt"` バッチ実行
# 新仕様: `codex exec --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox` でバッチ実行
#         （Claude CLI -p は従量課金化のため、定額のCodex CLIへ移行）
#
# 既存の run-scheduled-prompt.sh（sessionモード=対話Claude）との違い:
#   - セッションに入らず非対話実行
#   - 実行完了後にtmuxセッションは自動終了
#   - 二重起動防止はguard-execution.shが担当
#
# 引数:
#   $1 — スケジュール名（ログ識別に使用）
#   $2 — tmuxセッション名
#   $3 — ワークディレクトリ
#   $4 — レガシー引数（旧 claude コマンドライン。後方互換のため受け取るが無視）
#   $5 — 実行するプロンプト

SCHED_NAME="${1:?スケジュール名が必要です}"
SESSION="${2:?セッション名が必要です}"
WORKDIR="${3:?ワークディレクトリが必要です}"
LEGACY_CMD="${4:-}"  # 旧 claude コマンドライン。受け取るが使用しない（後方互換）
PROMPT="${5:?プロンプトが必要です}"

# Codex CLI 設定（環境変数で上書き可）
# 注意: --full-auto と --dangerously-bypass-approvals-and-sandbox は排他のため
#       後者のみを使用する（前者は deprecated で --sandbox workspace-write のエイリアス）
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_CMD="${CODEX_CMD:-codex exec --model ${CODEX_MODEL} --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check}"

LOG_DIR="$HOME/.local/share/harness-schedule/logs"
STATE_DIR="$HOME/.local/share/harness-schedule"
COOLDOWN_FILE="$STATE_DIR/codex-rate-limit-cooldown"
mkdir -p "$LOG_DIR" "$STATE_DIR"

LOG_FILE="$LOG_DIR/${SCHED_NAME}-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

write_rate_limit_cooldown() {
  # Codexの場合、レートリミットのresetタイムスタンプは出力フォーマットが安定しないため、
  # 一律で「1時間後」のcooldownを設定する（保守的）
  local until_epoch until_iso
  until_epoch=$(($(date +%s) + 3600))
  until_iso=$(date -r "$until_epoch" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -d "@$until_epoch" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  printf '%s|%s|%s\n' "$until_epoch" "$until_iso" "codex-rate-limit (1h)" > "$COOLDOWN_FILE"
  log "Rate limit detected. Future Codex script runs will be skipped until $until_iso."
}

check_rate_limit_cooldown() {
  [ -f "$COOLDOWN_FILE" ] || return 0

  local until_epoch until_iso until_label
  IFS='|' read -r until_epoch until_iso until_label _ < "$COOLDOWN_FILE" || true

  if ! [[ "${until_epoch:-}" =~ ^[0-9]+$ ]]; then
    rm -f "$COOLDOWN_FILE"
    return 0
  fi

  local now_epoch
  now_epoch=$(date +%s)

  if [ "$now_epoch" -lt "$until_epoch" ]; then
    log "=== SKIP: global Codex cooldown active until $until_iso (${until_label:-cooldown}) ==="
    exit 0
  fi

  rm -f "$COOLDOWN_FILE"
}

check_rate_limit_cooldown

# 二重起動防止はguard-execution.shが担当（このスクリプトの呼び出し元）

log "=== Script Schedule Start: $SCHED_NAME ==="
log "Workdir: $WORKDIR | Cmd: $CODEX_CMD"
log "Mode: script (non-interactive, Codex) | PID: $$"
if [ -n "$LEGACY_CMD" ] && [[ "$LEGACY_CMD" == claude* ]]; then
  log "NOTE: legacy 4th arg ('$LEGACY_CMD') ignored. This script now uses Codex CLI."
fi

# tmuxセッションが既に存在する場合は終了
if tmux has-session -t "$SESSION" 2>/dev/null; then
  log "WARN: tmux session '$SESSION' already exists. Killing it."
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  sleep 1
fi

# プロンプトをファイルに書き出し（エスケープ問題回避）
PROMPT_FILE="$LOG_DIR/${SCHED_NAME}-prompt-$$.txt"
echo "$PROMPT" > "$PROMPT_FILE"

# tmuxセッション作成 + Codex CLI非対話実行
log "Creating tmux session and running Codex CLI..."
tmux new-session -d -s "$SESSION" -c "$WORKDIR" \
  "source ~/.zshrc 2>/dev/null; $CODEX_CMD \"\$(cat '$PROMPT_FILE')\" 2>&1 | tee -a '$LOG_FILE'; echo '[SCRIPT_DONE]' >> '$LOG_FILE'; rm -f '$PROMPT_FILE'"

# 実行完了を待つ（最大30分）
MAX_WAIT=1800
WAITED=0
RATE_LIMITED=false
log "Waiting for script completion (max ${MAX_WAIT}s)..."

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  sleep 10
  WAITED=$((WAITED + 10))

  # tmuxセッションが終了したか確認
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "tmux session ended. (${WAITED}s)"
    break
  fi

  # ログにSCRIPT_DONEが出たか確認
  if grep -q '\[SCRIPT_DONE\]' "$LOG_FILE" 2>/dev/null; then
    log "Script completed. (${WAITED}s)"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    break
  fi

  # レートリミット検出（Codex/OpenAI共通パターン）
  # command grep を使い zshrc の grep shell function による誤マッチを回避
  if [ "$RATE_LIMITED" = false ] && \
     command grep -qiE "rate[ ._-]?limit|\b429\b|too many requests|quota.?exceeded|insufficient_quota" "$LOG_FILE" 2>/dev/null; then
    RATE_LIMITED=true
  fi

  # 5分ごとに進捗ログ
  if [ $((WAITED % 300)) -eq 0 ]; then
    log "  Still running... (${WAITED}s / ${MAX_WAIT}s)"
  fi
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
  log "ERROR: Script timed out after ${MAX_WAIT}s. Killing session."
  tmux kill-session -t "$SESSION" 2>/dev/null || true
fi

# 最終確認
if [ "$RATE_LIMITED" = false ] && \
   command grep -qiE "rate[ ._-]?limit|\b429\b|too many requests|quota.?exceeded|insufficient_quota" "$LOG_FILE" 2>/dev/null; then
  RATE_LIMITED=true
fi

[ "$RATE_LIMITED" = true ] && write_rate_limit_cooldown

# クリーンアップ
rm -f "$PROMPT_FILE"
log "=== Script Schedule Complete: $SCHED_NAME ==="
