FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
# kimi spawn readiness, submit, and delivery tuning (bin/fm-spawn.sh owns the mechanics)
FM_KIMI_READY_POLLS=60   # kimi-only: pane-capture polls for the launch-readiness signal (welcome banner or empty composer) before brief delivery
FM_KIMI_DELIVERY_POLLS=40   # kimi-only: pane-capture polls confirming brief-pointer delivery before the spawn fails
FM_KIMI_POLL_INTERVAL=0.5   # kimi-only: seconds between readiness and delivery polls; also the default FM_KIMI_SUBMIT_SLEEP
FM_KIMI_SUBMIT_RETRIES=3   # kimi-only: Enter-retry attempts for the brief-pointer submit after typing it once, never retyping
FM_KIMI_SUBMIT_SLEEP=0.5   # kimi-only: seconds between submit checks; defaults to FM_KIMI_POLL_INTERVAL
FM_KIMI_SUBMIT_SETTLE=0   # kimi-only: pre-Enter settle seconds after typing the brief pointer so completion popups clear before Enter; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
