#!/usr/bin/env bash
# Live validation of the kimi herdr spawn-gate fix against REAL herdr 0.8.2 +
# kimi 0.40.1, mirroring the author's 2026-09-03 live validation.
#
# Part A (defects 1+2): a fresh `kimi --auto` pane on an isolated herdr lab
# session is fed the exact spawn-gate call (fm_backend_send_text_submit with
# the real brief-pointer text and the new patient defaults 20/0.5/0). Before
# the fix this false-failed: the permission-badged footer invalidated the
# empty-composer read, native status read unknown (no registered agent yet),
# and the unknown verdict aborted instead of falling through to the composer.
#
# Part B (defect 3): the same pane's agent is made to self-exit (/exit), and
# fm_backend_agent_state must report dead from the retained record + bare-shell
# foreground (herdr's agent_status is ambiguous done/idle in both directions),
# which is what lets fm-control relaunch confirm the old-agent stop.
set -u

ROOT="/home/dm/.no-mistakes/worktrees/ce3ac3a0e863/01M1P7T0V9QSH0EXP0BJ4YCENZ"
EVID="/tmp/no-mistakes-evidence/01M1P7T0V9QSH0EXP0BJ4YCENZ"
LOG="$EVID/live-kimi-gate-validation.log"
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

SESSION="fm-lab-kimigate-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "/tmp/kimi-gate-scratch.XXXXXX")
BRIEF="$SCRATCH/brief.md"
printf '# Scratch brief\n\nReply with exactly: ACK-BRIEF-READ\n' > "$BRIEF"

cleanup() {
  say "== cleanup: tearing down lab session $SESSION, removing $SCRATCH"
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >>"$LOG" 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

say "== provisioning isolated herdr lab session (starts the lab server): $SESSION"
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" >>"$LOG" 2>&1 || { say "FAIL: lab provision"; exit 1; }
# provision backgrounds the server boot; wait until it answers.
for i in $(seq 1 30); do
  if "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" session list >/dev/null 2>&1; then break; fi
  sleep 1
done

say "== creating workspace (cwd=$SCRATCH)"
ws_json=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" workspace create --cwd "$SCRATCH" --label kimigate --no-focus 2>>"$LOG") \
  || { say "FAIL: workspace create"; exit 1; }
say "$ws_json"
WS=$(printf '%s' "$ws_json" | jq -r '.result.workspace.id // .result.workspace.workspace_id // empty')
[ -n "$WS" ] || { say "FAIL: could not parse workspace id"; exit 1; }

say "== listing panes in $WS"
panes_json=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane list --workspace "$WS" 2>>"$LOG") || { say "FAIL: pane list"; exit 1; }
PANE=$(printf '%s' "$panes_json" | jq -r '.result.panes[0].pane_id // .result.panes[0].id // empty')
[ -n "$PANE" ] || { say "FAIL: could not parse pane id"; exit 1; }
say "pane: $PANE"

say "== launching real kimi 0.40.1: pane run $PANE 'kimi --auto'"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane run "$PANE" 'kimi --auto' >>"$LOG" 2>&1 || { say "FAIL: pane run"; exit 1; }

# Wait for the kimi TUI (same ready signal fm-spawn's kimi_wait_for_ready uses).
# A brand-new untrusted cwd first draws kimi 0.40.1's trust dialog; accept it
# with Enter (the ❯ starts on "Trust this folder") and keep waiting for the
# real composer.
say "== waiting for kimi TUI ready signal"
ready=0
for i in $(seq 1 90); do
  cap=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane read "$PANE" --source visible --format text 2>/dev/null || true)
  if printf '%s' "$cap" | grep -Fq 'Trust this folder'; then
    "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane send-keys "$PANE" Enter >>"$LOG" 2>&1
    sleep 2
    continue
  fi
  if printf '%s' "$cap" | grep -Fq 'Welcome to Kimi Code!'; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { say "FAIL: kimi TUI never became ready"; exit 1; }
say "kimi TUI is up"

say "== captured screen at rest (badged footer evidence):"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane read "$PANE" --source visible --format text 2>/dev/null | tee -a "$LOG" "$EVID/live-kimi-screen-at-rest.txt"

# Source the real backend adapter (the same code fm-spawn drives).
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { say "FAIL: backend source"; exit 1; }

TARGET="$SESSION:$PANE"

say "== native agent status raw, pre-first-message (defect 2 premise):"
raw_pre=$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")
say "raw agent_status='$raw_pre' (expect empty / no registered agent)"

say "== shared composer classification of the live at-rest screen (via the real backend dispatch):"
verdict_rest=$(fm_backend_composer_state herdr "$TARGET")
say "composer verdict at rest: '$verdict_rest' (empty = badged footer tolerated)"

say "== DEFECT 1+2: real spawn-gate submit (retries=20 sleep=0.5 settle=0, the fm-spawn defaults)"
KIMI_POINTER="Read the brief at $BRIEF and follow it exactly."
t0=$(date +%s)
SUBMIT_OUT=$(FM_HERDR_LOG="$EVID/live-kimi-herdr-cli.log" \
  fm_backend_send_text_submit herdr "$TARGET" "$KIMI_POINTER" 20 0.5 0 2>&1)
SUBMIT_RC=$?
t1=$(date +%s)
say "submit rc=$SUBMIT_RC elapsed=$((t1-t0))s"
say "submit verdict: '$SUBMIT_OUT' (empty = delivery confirmed)"
[ "$SUBMIT_RC" -eq 0 ] && [ "$SUBMIT_OUT" = empty ] || { say "FAIL: spawn gate would have false-failed"; exit 1; }

sleep 2
say "== screen after delivery (brief pointer visible in transcript, composer empty):"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane read "$PANE" --source visible --format text 2>/dev/null | tee -a "$LOG" "$EVID/live-kimi-screen-after-delivery.txt"

say "== native agent status raw, post-submit:"
raw_post=$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")
say "raw agent_status='$raw_post'"

say "== DEFECT 3a: agent_state while kimi TUI is live (must be alive on any retained status):"
state_live=$(fm_backend_agent_state herdr "$TARGET")
say "agent_state live: '$state_live' (raw status was '$raw_post')"
[ "$state_live" = alive ] || { say "FAIL: live kimi must report alive"; exit 1; }

say "== waiting for the brief turn to finish before /exit (kimi refuses /exit while streaming)"
for i in $(seq 1 150); do
  st=$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")
  [ "$st" = working ] || break
  sleep 1
done
say "turn settled (raw status: $(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE"))"

# Text refused while streaming (the /exit below, or a fresh pending composer)
# is submitted with a plain Enter; an empty composer gets a fresh /exit typed.
comp=$(fm_backend_composer_state herdr "$TARGET")
say "composer before exit: '$comp'"
if [ "$comp" = empty ]; then
  say "== asking kimi to self-exit: /exit"
  "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane send-text "$PANE" '/exit' >>"$LOG" 2>&1
  sleep 0.5
  "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane send-keys "$PANE" Enter >>"$LOG" 2>&1
else
  say "== submitting the pending composer content (the earlier /exit) with Enter"
  "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane send-keys "$PANE" Enter >>"$LOG" 2>&1
fi

exited=0
for i in $(seq 1 45); do
  cap=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane read "$PANE" --source visible --format text 2>/dev/null || true)
  if printf '%s' "$cap" | grep -Fq 'Bye!'; then exited=1; break; fi
  fg=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null | jq -r '.result.process_info.foreground_processes[0].name // empty' 2>/dev/null)
  case "$fg" in sh|bash|zsh|dash|ksh|fish) exited=1; break ;; esac
  sleep 1
done
[ "$exited" -eq 1 ] || say "WARN: neither 'Bye!' nor a shell foreground observed; proceeding anyway"

say "== screen after self-exit:"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane read "$PANE" --source visible --format text 2>/dev/null | tee -a "$LOG" "$EVID/live-kimi-screen-after-exit.txt"

# Give the shell a moment to return to the foreground.
sleep 2

say "== herdr pane process-info after exit (bare-shell foreground evidence):"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null | tee -a "$LOG" "$EVID/live-kimi-process-info-after-exit.json" | jq '.result.process_info.foreground_processes' | tee -a "$LOG"

say "== retained agent record after exit:"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" agent get "$PANE" 2>&1 | tee -a "$LOG" "$EVID/live-kimi-agent-record-after-exit.json" | head -5

say "== DEFECT 3b: agent_state after self-exit (must be dead so relaunch confirms the stop):"
raw_exit=$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")
say "raw retained agent_status after exit: '$raw_exit' (done or idle retained - ambiguous by design)"
state_exit=$(fm_backend_agent_state herdr "$TARGET")
say "agent_state after exit: '$state_exit'"
[ "$state_exit" = dead ] || { say "FAIL: exited kimi must report dead (relaunch would time out its dead-wait)"; exit 1; }

say "ALL LIVE CHECKS PASSED"
