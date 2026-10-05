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

# Everything this run says lands in /tmp/syla-run.log too, so a quiet
# sandbox is one `cat` away from explaining itself.
exec > >(tee -a /tmp/syla-run.log) 2>&1
echo "run-syla: starting $(date -u +%FT%TZ)"

set -euo pipefail

: "${SUPABASE_URL:?}" "${SUPABASE_ANON_KEY:?}" "${CLAUDE_RQ_KEY:?}"
: "${OPENROUTER_API_KEY:?}" "${SYLA_MODEL:?}"

cd "$(cd "$(dirname "$0")/.." && pwd)"
echo "run-syla: checkout $(pwd), model $SYLA_MODEL"

# The snapshot (daytona/Dockerfile) bakes the tools in; on Daytona's
# default image, install at run time. Root-or-sudo for apt, and npm
# globals go to a user prefix so a non-root sandbox user works too.
command -v git >/dev/null || { echo 'run-syla: git is missing from this image'; exit 1; }
if ! command -v jq >/dev/null; then
    echo 'run-syla: installing jq…'
    if [ "$(id -u)" = "0" ]; then
        apt-get update -qq || true
        apt-get install -y -qq jq
    elif command -v sudo >/dev/null; then
        sudo apt-get update -qq || true
        sudo apt-get install -y -qq jq
    else
        echo 'run-syla: no root and no sudo — cannot install jq; the scripts need it'
        exit 1
    fi
fi
if ! command -v opencode >/dev/null; then
    command -v npm >/dev/null || { echo 'run-syla: npm is missing from this image'; exit 1; }
    echo 'run-syla: installing opencode…'
    export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX"
    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
    npm install -g --silent opencode-ai@latest
fi
echo "run-syla: tools ready — opencode $(opencode --version 2>/dev/null || echo '?')"

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

echo 'run-syla: working the queue'
# The same railed prompt the Mac worker uses: open models wander
# without the procedure spelled out.
exec opencode run --model "$SYLA_MODEL" "Do the task. The do-the-task section of CLAUDE.md is your complete procedure - follow it literally and nothing else: 1) run scripts/syla-claim; empty array means stop. 2) For each claimed run, read its attached docs with scripts/rq and do what they say through the scripts/ wrappers. 3) Answer message runs with scripts/chat-say --run <run_id>. 4) Report every run with scripts/syla-finish before stopping. The scripts are your whole interface: do NOT explore the repository, do NOT read supabase/migrations or any source files, and do NOT study the schema - the claim and the docs carry everything you need. Work quickly."
