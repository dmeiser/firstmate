FM_KIMI_* defaults and semantics traced from bin/fm-spawn.sh (authoritative source):

| env var | code site | default | doc default | match |
|---|---|---|---|---|
| FM_KIMI_READY_POLLS | fm-spawn.sh:2885 kimi_wait_for_ready | 60 | 60 | yes |
| FM_KIMI_DELIVERY_POLLS | fm-spawn.sh:2911 kimi_wait_for_delivery | 40 | 40 | yes |
| FM_KIMI_POLL_INTERVAL | fm-spawn.sh:2885,2911 | 0.5 | 0.5 | yes |
| FM_KIMI_SUBMIT_RETRIES | fm-spawn.sh:3878 | 3 | 3 | yes |
| FM_KIMI_SUBMIT_SLEEP | fm-spawn.sh:3879 (falls back to FM_KIMI_POLL_INTERVAL then 0.5) | 0.5 | 0.5 | yes |
| FM_KIMI_SUBMIT_SETTLE | fm-spawn.sh:3880 | 0 | 0 | yes |

Semantics verified:
- READY_POLLS/DELIVERY_POLLS/POLL_INTERVAL drive the pane-capture poll loops in
  kimi_wait_for_ready / kimi_wait_for_delivery (welcome-banner or empty-composer
  readiness; delivery = empty composer + brief echo/context usage).
- SUBMIT_RETRIES/SUBMIT_SLEEP/SUBMIT_SETTLE are passed to
  fm_backend_send_text_submit -> fm_tmux_submit_core (bin/fm-tmux-lib.sh:281),
  which types the brief pointer once, sleeps `settle` (PRE-Enter settle so
  completion popups clear), then retries Enter up to `retries` times sleeping
  `sleep_s` between checks - never retyping. Delivery polling starts
  immediately after the verdict; there is no post-submit settle in the kimi path.
- Fix applied during testing: docs/configuration.md originally described
  FM_KIMI_SUBMIT_SETTLE as "seconds to settle after a confirmed brief-pointer
  submit before delivery polling" (semantics of FM_SEND_SETTLE, which fm-send.sh
  implements separately at bin/fm-send.sh:1107-1109). Corrected to the actual
  pre-Enter settle semantics.

Targeted test run: bash tests/fm-kimi-harness.test.sh -> all cases ok,
including "fm-spawn: kimi launches, delivers its brief, and registers a guarded
turn-end token", "kimi never sends the brief pointer before an observable ready
signal", and "kimi treats a silent pointer drop as a failed spawn" (these run
fm-spawn.sh with FM_KIMI_READY_POLLS=2 FM_KIMI_DELIVERY_POLLS=2
FM_KIMI_POLL_INTERVAL=0, exercising the documented env-var family end to end
through the kimi spawn readiness/submit/delivery path).
