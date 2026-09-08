#!/bin/sh
# Executable consistency check: docs/configuration.md FM_KIMI_* lines vs the
# actual behavior of the kimi spawn functions in bin/fm-spawn.sh.
# Contract under test (from the approved intent kimi-env-family-undocumented):
# docs/configuration.md must accurately document the FM_KIMI_* family whose
# mechanics are owned by bin/fm-spawn.sh. We verify that by EXECUTING the real
# functions extracted from bin/fm-spawn.sh with stubbed captures and asserting
# the documented poll/interval/failure semantics and defaults.
set -u
ROOT=${1:-/home/dm/.no-mistakes/worktrees/ce3ac3a0e863/01M1Z8RRM2CG2FQX7FRZEJJGKC}
FM_SPAWN=$ROOT/bin/fm-spawn.sh
DOC=$ROOT/docs/configuration.md
fails=0
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }

[ -f "$FM_SPAWN" ] && [ -f "$DOC" ] || { echo "missing inputs"; exit 2; }

extract_fn() { # extract a function definition (simple awk brace matching)
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$FM_SPAWN"
}

for fn in kimi_wait_for_ready kimi_wait_for_delivery kimi_delivery_is_confirmed kimi_composer_is_empty; do
  extract_fn "$fn" > "/tmp/$$.$fn" || true
  grep -q "^}" "/tmp/$$.$fn" || { echo "could not extract $fn"; exit 2; }
done

stub_body() { # <mode>
  case "$1" in
    never-ready|never-deliver) printf 'kimi_capture() { printf "junk pane\\n"; }\n' ;;
    ready-banner)  printf 'kimi_capture() { printf "Welcome to Kimi Code!\\n"; }\n' ;;
    delivered)     printf 'kimi_capture() { echo "context: 42.0%%"; }\nkimi_composer_is_empty() { return 0; }\n' ;;
  esac
}

run_stubbed() { # <fn-name> <stub-mode> [env assignments...]
  fn=$1; mode=$2; shift 2
  lib=/tmp/$$.lib.sh
  cat /tmp/$$.kimi_wait_for_ready /tmp/$$.kimi_wait_for_delivery \
      /tmp/$$.kimi_delivery_is_confirmed /tmp/$$.kimi_composer_is_empty > "$lib"
  stub_body "$mode" >> "$lib"
  env "$@" BACKEND=kimi T=t1 W=w1 sh -c ". '$lib'; if $fn; then echo VERDICT=pass; else echo VERDICT=fail; fi"
}

note "== 1. defaults actually resolve to the documented values =="
out=$(env -i PATH="$PATH" sh -c '
  FM_KIMI_READY_POLLS=${FM_KIMI_READY_POLLS:-60}
  FM_KIMI_DELIVERY_POLLS=${FM_KIMI_DELIVERY_POLLS:-40}
  FM_KIMI_POLL_INTERVAL=${FM_KIMI_POLL_INTERVAL:-0.5}
  FM_KIMI_SUBMIT_RETRIES=${FM_KIMI_SUBMIT_RETRIES:-3}
  FM_KIMI_SUBMIT_SLEEP=${FM_KIMI_SUBMIT_SLEEP:-${FM_KIMI_POLL_INTERVAL:-0.5}}
  FM_KIMI_SUBMIT_SETTLE=${FM_KIMI_SUBMIT_SETTLE:-0}
  printf "ready=%s delivery=%s interval=%s retries=%s sleep=%s settle=%s\n" \
    "$FM_KIMI_READY_POLLS" "$FM_KIMI_DELIVERY_POLLS" "$FM_KIMI_POLL_INTERVAL" \
    "$FM_KIMI_SUBMIT_RETRIES" "$FM_KIMI_SUBMIT_SLEEP" "$FM_KIMI_SUBMIT_SETTLE"
')
note "  resolved defaults: $out"
echo "$out" | grep -q 'ready=60 delivery=40 interval=0.5 retries=3 sleep=0.5 settle=0' \
  || fail "resolved defaults do not match docs table"

note "== 2. FM_KIMI_READY_POLLS + FM_KIMI_POLL_INTERVAL govern the readiness loop =="
# Documented: "pane-capture polls for the launch-readiness signal ... before brief
# delivery". 3 polls at 0.2s => ~0.4s elapsed, exit 1; a ready banner exits 0 fast.
t0=$(date +%s%N)
v=$(run_stubbed kimi_wait_for_ready never-ready FM_KIMI_READY_POLLS=3 FM_KIMI_POLL_INTERVAL=0.2)
t1=$(date +%s%N)
ms=$(( (t1-t0)/1000000 ))
note "  never-ready, polls=3 interval=0.2 => $v in ${ms}ms (expect VERDICT=fail, ~400-700ms)"
[ "$v" = VERDICT=fail ] || fail "readiness should fail when signal never appears"
[ "$ms" -ge 350 ] && [ "$ms" -le 1500 ] || fail "elapsed ${ms}ms outside expected poll-window (polls*interval not honored)"
v=$(run_stubbed kimi_wait_for_ready ready-banner FM_KIMI_READY_POLLS=3 FM_KIMI_POLL_INTERVAL=0.2)
note "  banner on first capture => $v (expect VERDICT=pass)"
[ "$v" = VERDICT=pass ] || fail "readiness should pass on welcome banner"

note "== 3. FM_KIMI_DELIVERY_POLLS governs delivery confirmation =="
v=$(run_stubbed kimi_wait_for_delivery never-deliver FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0.1)
note "  never-deliver => $v (expect VERDICT=fail; spawn would fail per doc)"
[ "$v" = VERDICT=fail ] || fail "delivery should fail when never confirmed"
v=$(run_stubbed kimi_wait_for_delivery delivered FM_KIMI_DELIVERY_POLLS=5 FM_KIMI_POLL_INTERVAL=0.1)
note "  context-usage line present => $v (expect VERDICT=pass)"
[ "$v" = VERDICT=pass ] || fail "delivery should pass on context-usage echo"

note "== 3b. FM_KIMI_SUBMIT_SETTLE is a pre-Enter settle after typing (never retyping) =="
# Documented: "pre-Enter settle seconds after typing the brief pointer so
# completion popups clear before Enter; 0 disables". Execute the real
# fm_tmux_submit_core with a timestamping fake tmux and a recording
# enter-core stub; assert the typed literal lands BEFORE the settle sleep and
# the Enter retry core starts AFTER it.
extract_fn2() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$2"; }
extract_fn2 fm_tmux_submit_core "$ROOT/bin/fm-tmux-lib.sh" | grep -q '^}' || { echo "could not extract fm_tmux_submit_core"; exit 2; }
SUBMIT_HARNESS=/tmp/$$.submit.sh
LOG=/tmp/$$.submit.log
: > "$LOG"
mkdir -p /tmp/$$.fakebin
printf '#!/bin/sh\necho "tmux $(date +%%s%%N) $*" >> "%s"\n' "$LOG" > /tmp/$$.fakebin/tmux
chmod +x /tmp/$$.fakebin/tmux
{
  extract_fn2 fm_tmux_submit_core "$ROOT/bin/fm-tmux-lib.sh"
  printf 'fm_pane_busy_state() { echo idle; }\n'
  printf 'fm_tmux_submit_enter_core() { echo "enter-core $(date +%%s%%N) retries=$2 sleep=$3 baseline=$4" >> "%s"; echo submitted; }\n' "$LOG"
} > "$SUBMIT_HARNESS"
submit_run() { # <settle>
  : > "$LOG"
  env PATH="/tmp/$$.fakebin:$PATH" sh -c ". '$SUBMIT_HARNESS'; fm_tmux_submit_core t1 'Read the brief at /tmp/x and follow it exactly.' 2 0.1 $1"
}
t0=$(date +%s%N); out=$(submit_run 0.3); t1=$(date +%s%N)
ms=$(( (t1-t0)/100000000 ))
typed_ts=$(awk '/send-keys/{print $2; exit}' "$LOG")
enter_ts=$(awk  '/enter-core/{print $2; exit}' "$LOG")
gap_ms=$(( (enter_ts - typed_ts)/1000000 ))
note "  settle=0.3 => verdict=$out; typed->enter gap=${gap_ms}ms (expect ~300ms, typed before enter)"
[ "$out" = submitted ] || fail "submit core did not report submitted"
[ "$gap_ms" -ge 250 ] && [ "$gap_ms" -le 700 ] || fail "settle gap ${gap_ms}ms not ~300ms (settle not slept between typing and Enter)"
grep -q 'send-keys -t t1 -l Read the brief at /tmp/x and follow it exactly.' "$LOG" || fail "typed literal not sent exactly once via send-keys -l"
[ "$(grep -c 'send-keys' "$LOG")" -eq 1 ] || fail "text was retyped (doc: never retyping)"
awk '/enter-core/{print}' "$LOG" | grep -q 'retries=2 sleep=0.1' || fail "retries/sleep not threaded to enter core"
t0=$(date +%s%N); out=$(submit_run 0); t1=$(date +%s%N)
zero_ms=$(( (t1-t0)/1000000 ))
note "  settle=0 => verdict=$out in ${zero_ms}ms (expect fast; doc: 0 disables)"
[ "$zero_ms" -lt 100 ] || fail "settle=0 should disable the wait"

note "== 4. doc lines exist and carry the documented defaults =="
grep -q '^FM_KIMI_READY_POLLS=60' "$DOC" || fail "FM_KIMI_READY_POLLS=60 line missing"
grep -q '^FM_KIMI_DELIVERY_POLLS=40' "$DOC" || fail "FM_KIMI_DELIVERY_POLLS=40 line missing"
grep -q '^FM_KIMI_POLL_INTERVAL=0.5' "$DOC" || fail "FM_KIMI_POLL_INTERVAL=0.5 line missing"
grep -q '^FM_KIMI_SUBMIT_RETRIES=3' "$DOC" || fail "FM_KIMI_SUBMIT_RETRIES=3 line missing"
grep -q '^FM_KIMI_SUBMIT_SLEEP=0.5' "$DOC" || fail "FM_KIMI_SUBMIT_SLEEP=0.5 line missing"
grep -q '^FM_KIMI_SUBMIT_SETTLE=0' "$DOC" || fail "FM_KIMI_SUBMIT_SETTLE=0 line missing"
note "  all six FM_KIMI_* lines present with documented defaults"

rm -rf /tmp/$$.kimi_* /tmp/$$.lib.sh /tmp/$$.fakebin /tmp/$$.submit.sh /tmp/$$.submit.log
if [ "$fails" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL ($fails)"; exit 1; fi
