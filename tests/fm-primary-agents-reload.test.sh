#!/usr/bin/env bash
# tests/fm-primary-agents-reload.test.sh - regression tests for the OpenCode
# plugin that re-injects this repo's AGENTS.md across context compaction.
#
# These tests exercise the plugin's public hook contract with mocked context
# objects, so they run without a live opencode session. The end-to-end behavior
# (compaction survival) is covered by the hook logic and the config schema.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/.opencode/plugins/fm-primary-agents-reload.js"
CONFIG="$ROOT/.opencode/opencode.json"

# The plugin only runs in a primary checkout, where .git is a directory.
# Create a fake primary root for the units so the tests are not coupled to
# whether the current worktree is a primary checkout or a spawned worktree.
FAKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fm-agents-reload-root.XXXXXX")"
trap "rm -rf '$FAKE_ROOT'" EXIT
mkdir -p "$FAKE_ROOT/bin" "$FAKE_ROOT/.git"
cp "$ROOT/AGENTS.md" "$FAKE_ROOT/AGENTS.md"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# UNIT 1: plugin loads and exposes the expected hooks in the primary checkout.
# ---------------------------------------------------------------------------
unit_plugin_hooks() {
  local hooks
  hooks=$(node --input-type=module -e "
import { FmPrimaryAgentsReload } from '$PLUGIN';
const p = await FmPrimaryAgentsReload({ directory: '$FAKE_ROOT', worktree: '$FAKE_ROOT' });
console.log(Object.keys(p).sort().join(','));
")
  if [[ "$hooks" == "experimental.chat.system.transform,experimental.session.compacting" ]]; then
    pass "plugin exposes compaction and chat system transform hooks"
  else
    fail "unexpected hooks: $hooks"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 2: experimental.session.compacting appends AGENTS.md to output.context.
# ---------------------------------------------------------------------------
unit_compacting_injects() {
  local result
  result=$(node --input-type=module -e "
import { FmPrimaryAgentsReload } from '$PLUGIN';
import { readFileSync } from 'node:fs';
const p = await FmPrimaryAgentsReload({ directory: '$FAKE_ROOT', worktree: '$FAKE_ROOT' });
const output = { context: [] };
await p['experimental.session.compacting']({}, output);
const agents = readFileSync('$FAKE_ROOT/AGENTS.md', 'utf8');
const injected = output.context[0] || '';
const checks = [
  output.context.length === 1,
  injected.includes('FIRSTMATE_AGENTS_RELOAD'),
  injected.includes(agents.slice(0, 200)),
];
console.log(checks.every(Boolean) ? 'ok' : 'fail');
")
  if [[ "$result" == "ok" ]]; then
    pass "compaction hook injects AGENTS.md into output.context"
  else
    fail "compaction hook did not inject AGENTS.md"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 3: experimental.session.compacting is idempotent within one call.
# ---------------------------------------------------------------------------
unit_compacting_idempotent() {
  local result
  result=$(node --input-type=module -e "
import { FmPrimaryAgentsReload } from '$PLUGIN';
const p = await FmPrimaryAgentsReload({ directory: '$FAKE_ROOT', worktree: '$FAKE_ROOT' });
const output = { context: [] };
await p['experimental.session.compacting']({}, output);
await p['experimental.session.compacting']({}, output);
console.log(output.context.length === 1 ? 'ok' : 'fail');
")
  if [[ "$result" == "ok" ]]; then
    pass "compaction hook is idempotent"
  else
    fail "compaction hook duplicated context"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 4: experimental.chat.system.transform prepends AGENTS.md when missing.
# ---------------------------------------------------------------------------
unit_chat_transform_injects() {
  local result
  result=$(node --input-type=module -e "
import { FmPrimaryAgentsReload } from '$PLUGIN';
import { readFileSync } from 'node:fs';
const p = await FmPrimaryAgentsReload({ directory: '$FAKE_ROOT', worktree: '$FAKE_ROOT' });
const output = { system: ['existing system prompt'] };
await p['experimental.chat.system.transform']({}, output);
const agents = readFileSync('$FAKE_ROOT/AGENTS.md', 'utf8');
const first = output.system[0] || '';
const checks = [
  output.system.length === 1,
  first.includes('FIRSTMATE_AGENTS_RELOAD'),
  first.includes(agents.slice(0, 200)),
  first.includes('existing system prompt'),
];
console.log(checks.every(Boolean) ? 'ok' : 'fail');
")
  if [[ "$result" == "ok" ]]; then
    pass "chat system transform prepends AGENTS.md when absent"
  else
    fail "chat system transform did not inject AGENTS.md"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 5: experimental.chat.system.transform is idempotent when already present.
# ---------------------------------------------------------------------------
unit_chat_transform_idempotent() {
  local result
  result=$(node --input-type=module -e "
import { FmPrimaryAgentsReload } from '$PLUGIN';
const p = await FmPrimaryAgentsReload({ directory: '$FAKE_ROOT', worktree: '$FAKE_ROOT' });
const output = { system: ['existing system prompt'] };
await p['experimental.chat.system.transform']({}, output);
await p['experimental.chat.system.transform']({}, output);
console.log(output.system.length === 1 ? 'ok' : 'fail');
")
  if [[ "$result" == "ok" ]]; then
    pass "chat system transform is idempotent"
  else
    fail "chat system transform duplicated AGENTS.md"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 6: .opencode/opencode.json validates against a local schema fixture.
# ---------------------------------------------------------------------------
unit_config_validates() {
  local result
  result=$(node --input-type=module -e "
import { readFileSync } from 'node:fs';
const schema = JSON.parse(readFileSync('$ROOT/tests/fixtures/opencode-config-schema.json', 'utf8'));
const config = JSON.parse(readFileSync('$CONFIG', 'utf8'));
function validate(value, s) {
  if (s.type === 'object') {
    if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
    if (s.required) {
      for (const key of s.required) {
        if (!(key in value)) return false;
      }
    }
    if (s.properties) {
      for (const [key, propSchema] of Object.entries(s.properties)) {
        if (key in value && !validate(value[key], propSchema)) return false;
      }
    }
    return true;
  }
  if (s.type === 'array') {
    if (!Array.isArray(value)) return false;
    if (s.items) {
      for (const item of value) {
        if (!validate(item, s.items)) return false;
      }
    }
    return true;
  }
  if (s.type === 'string') return typeof value === 'string';
  return true;
}
console.log(validate(config, schema) ? 'ok' : 'fail');
")
  if [[ "$result" == "ok" ]]; then
    pass ".opencode/opencode.json validates against local schema fixture"
  else
    fail "config validation failed"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 7: plugin refuses to run when .git is a file (git worktree).
# ---------------------------------------------------------------------------
unit_worktree_guard() {
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-agents-reload.XXXXXX")
  trap "rm -rf '$tmpdir'" EXIT

  mkdir -p "$tmpdir/bin"
  printf 'AGENTS.md placeholder\n' > "$tmpdir/AGENTS.md"
  printf 'gitdir: /path/to/repo.git/worktrees/foo\n' > "$tmpdir/.git"

  local result
  result=$(node --input-type=module -e "
import { FmPrimaryAgentsReload } from '$PLUGIN';
const p = await FmPrimaryAgentsReload({ directory: '$tmpdir', worktree: '$tmpdir' });
console.log(Object.keys(p).length === 0 ? 'ok' : 'fail');
")
  if [[ "$result" == "ok" ]]; then
    pass "plugin skips git worktrees where .git is a file"
  else
    fail "plugin did not skip git worktree"
  fi
}

# ---------------------------------------------------------------------------
# Run all units.
# ---------------------------------------------------------------------------
unit_plugin_hooks
unit_compacting_injects
unit_compacting_idempotent
unit_chat_transform_injects
unit_chat_transform_idempotent
unit_config_validates
unit_worktree_guard

exit "$FAILED"
