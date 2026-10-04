#!/usr/bin/env bash
#
# run-syla.sh — the Syla worker inside a Daytona sandbox.
#
# Started by the syla-fire edge function after it clones this repo to
# /tmp/syla. The job is exactly what a Claude Cloud routine session did:
# stand in the starter checkout with Syla's environment and run an agent
# harness on the standard "Do the task" loop (CLAUDE.md → syla-claim →
# the events' docs → syla-finish). The harness here is opencode, which
# speaks OpenRouter — so SYLA_MODEL picks any hosted open-weights model
# without touching this script.
#
# Environment (set on the sandbox by syla-fire):
#   SUPABASE_URL, SUPABASE_ANON_KEY, CLAUDE_RQ_KEY   Syla's database access
#   OPENROUTER_API_KEY                               the model provider
#   SYLA_MODEL        opencode model id, e.g. openrouter/z-ai/glm-5.3
#
# Everything here is disposable: the clone, the config, the sandbox
# itself (it auto-stops and auto-deletes). The only durable effects are
# the gated writes the scripts make — the same boundary as every other
# Syla session.

set -euo pipefail

: "${SUPABASE_URL:?}" "${SUPABASE_ANON_KEY:?}" "${CLAUDE_RQ_KEY:?}"
: "${OPENROUTER_API_KEY:?}" "${SYLA_MODEL:?}"

cd "$(cd "$(dirname "$0")/.." && pwd)"

# The snapshot (daytona/Dockerfile) bakes these in; on Daytona's default
# image, install at run time. jq is what the scripts/* wrappers need.
command -v git >/dev/null || { echo 'git is missing from this image' >&2; exit 1; }
command -v jq  >/dev/null || sudo apt-get install -y -qq jq
if ! command -v opencode >/dev/null; then
    command -v npm >/dev/null || { echo 'npm is missing from this image' >&2; exit 1; }
    npm install -g opencode-ai@latest
fi

# opencode reads AGENTS.md where Claude Code reads CLAUDE.md — same
# contract, same file.
ln -sf CLAUDE.md AGENTS.md

# Claims from this sandbox stamp claimed_by='cloud', so the apps can
# say "in the cloud" on the receipt (the Mac app stamps 'mac').
export SYLA_WORKER=cloud

# Headless runs cannot answer permission prompts; the real boundary is
# in Postgres (read-only rq, gated RPCs), not in the harness.
cat > opencode.json <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "allow",
    "bash": "allow",
    "webfetch": "allow"
  }
}
JSON

exec opencode run --model "$SYLA_MODEL" "Do the task"
