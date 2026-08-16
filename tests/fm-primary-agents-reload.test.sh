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
const p = await FmPrimaryAgentsReload({ directory: '$ROOT', worktree: '$ROOT' });
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
const p = await FmPrimaryAgentsReload({ directory: '$ROOT', worktree: '$ROOT' });
const output = { context: [] };
await p['experimental.session.compacting']({}, output);
const agents = readFileSync('$ROOT/AGENTS.md', 'utf8');
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
const p = await FmPrimaryAgentsReload({ directory: '$ROOT', worktree: '$ROOT' });
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
const p = await FmPrimaryAgentsReload({ directory: '$ROOT', worktree: '$ROOT' });
const output = { system: ['existing system prompt'] };
await p['experimental.chat.system.transform']({}, output);
const agents = readFileSync('$ROOT/AGENTS.md', 'utf8');
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
const p = await FmPrimaryAgentsReload({ directory: '$ROOT', worktree: '$ROOT' });
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
# UNIT 6: .opencode/opencode.json validates against the published schema.
# ---------------------------------------------------------------------------
unit_config_validates() {
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-agents-reload.XXXXXX")
  trap "rm -rf '$tmpdir'" EXIT

  npm install --prefix "$tmpdir" ajv 2>/dev/null >/dev/null
  curl -s https://opencode.ai/config.json -o "$tmpdir/opencode-schema.json"
  curl -s https://models.dev/model-schema.json -o "$tmpdir/model-schema.json"

  local result
  result=$(node --input-type=module -e "
import Ajv2020 from '$tmpdir/node_modules/ajv/dist/2020.js';
import { readFileSync } from 'node:fs';
const schema = JSON.parse(readFileSync('$tmpdir/opencode-schema.json', 'utf8'));
const modelSchema = JSON.parse(readFileSync('$tmpdir/model-schema.json', 'utf8'));
const config = JSON.parse(readFileSync('$CONFIG', 'utf8'));
const ajv = new Ajv2020({ strict: false });
ajv.addSchema(modelSchema);
const validate = ajv.compile(schema);
console.log(validate(config) ? 'ok' : JSON.stringify(validate.errors));
")
  if [[ "$result" == "ok" ]]; then
    pass ".opencode/opencode.json validates against published schema"
  else
    fail "config validation failed: $result"
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

exit "$FAILED"
