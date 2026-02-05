#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_URL="http://127.0.0.1:8788"
TMP_BASE="$(mktemp -d /tmp/stash-codex-int-XXXXXX)"
PROJECT_ROOT="$TMP_BASE/project"
FAKE_CODEX="$TMP_BASE/fake-codex"
FAKE_CODEX_LOG="$TMP_BASE/fake-codex.log"
BACKEND_LOG="$TMP_BASE/backend.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_BASE"
}
trap cleanup EXIT

if [ ! -d "$ROOT_DIR/.venv" ]; then
  echo "Missing virtualenv. Run ./scripts/install_stack.sh first." >&2
  exit 1
fi

mkdir -p "$PROJECT_ROOT"

cat >"$FAKE_CODEX" <<'EOF_FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${STASH_TEST_CODEX_LOG:-/tmp/stash-fake-codex.log}"
{
  echo "ARGS:$*"
} >> "$LOG_FILE"

if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using Fake Codex"
  exit 0
fi

if [[ "${1:-}" != "exec" ]]; then
  echo "Unsupported fake codex command" >&2
  exit 2
fi

if [[ "${@: -1}" == "-" ]]; then
  PROMPT="$(cat)"
else
  PROMPT="${@: -1}"
fi

{
  echo "PROMPT_BEGIN"
  printf '%s\n' "$PROMPT"
  echo "PROMPT_END"
} >> "$LOG_FILE"

if [[ "$PROMPT" == *"You are the Stash planner."* ]]; then
  FAKE_PROMPT="$PROMPT" python3 - <<'PY'
import json
import os
import re

prompt = os.environ.get("FAKE_PROMPT", "")
root_path = "."
match = re.search(r"Project summary JSON:\n(.*?)\n\nRecent conversation JSON:", prompt, flags=re.S)
if match:
    try:
        project = json.loads(match.group(1).strip())
        root_path = str(project.get("root_path") or ".")
    except Exception:
        root_path = "."

planner_text = (
    "Planner via fake codex.\n"
    "<codex_cmd>\n"
    "worktree: main\n"
    f"cwd: {root_path}\n"
    "cmd: python3 -c \"from pathlib import Path; Path('integration_from_codex.txt').write_text('created-by-fake-codex')\"\n"
    "</codex_cmd>"
)
events = [
    {"type": "thread.started", "thread_id": "fake-planner"},
    {"type": "turn.started"},
    {"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": planner_text}},
    {"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}},
]
for event in events:
    print(json.dumps(event))
PY
  exit 0
fi

CMD="$(printf '%s\n' "$PROMPT" | awk 'f{print} /^Command:/{f=1; next}' | sed '/^[[:space:]]*$/d' | head -n 1)"
if [[ -z "$CMD" ]]; then
  CMD="true"
fi

TMP_OUT="$(mktemp /tmp/stash-fake-out-XXXXXX)"
TMP_ERR="$(mktemp /tmp/stash-fake-err-XXXXXX)"
set +e
bash -lc "$CMD" >"$TMP_OUT" 2>"$TMP_ERR"
EC="$?"
set -e
OUT="$(cat "$TMP_OUT")"
ERR="$(cat "$TMP_ERR")"
rm -f "$TMP_OUT" "$TMP_ERR"
AGG="$OUT$ERR"

FAKE_EC="$EC" FAKE_CMD="$CMD" FAKE_AGG="$AGG" python3 - <<'PY'
import json
import os

exit_code = int(os.environ.get("FAKE_EC", "1"))
command = os.environ.get("FAKE_CMD", "")
aggregated = os.environ.get("FAKE_AGG", "")
status = "completed" if exit_code == 0 else "failed"
events = [
    {"type": "thread.started", "thread_id": "fake-executor"},
    {"type": "turn.started"},
    {
        "type": "item.completed",
        "item": {
            "id": "item_exec",
            "type": "command_execution",
            "command": command,
            "aggregated_output": aggregated,
            "exit_code": exit_code,
            "status": status,
        },
    },
    {"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}},
]
for event in events:
    print(json.dumps(event))
PY
exit 0
EOF_FAKE_CODEX

chmod +x "$FAKE_CODEX"

# shellcheck disable=SC1091
source "$ROOT_DIR/.venv/bin/activate"

STASH_CODEX_MODE=cli \
STASH_CODEX_BIN="$FAKE_CODEX" \
STASH_TEST_CODEX_LOG="$FAKE_CODEX_LOG" \
STASH_LOG_LEVEL=INFO \
uvicorn stash_backend.main:app --host 127.0.0.1 --port 8788 >"$BACKEND_LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 80); do
  if curl -fsS "$API_URL/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! curl -fsS "$API_URL/health" >/dev/null 2>&1; then
  echo "Backend failed health check; backend log:" >&2
  sed -n '1,200p' "$BACKEND_LOG" >&2
  exit 1
fi

echo "[1/7] check integration diagnostics endpoint"
INTEGRATIONS_JSON="$(curl -fsS "$API_URL/health/integrations")"
python3 - <<'PY' "$INTEGRATIONS_JSON"
import json
import sys

data = json.loads(sys.argv[1])
assert data["codex_mode"] == "cli"
assert data["codex_available"] is True
assert data["login_checked"] is True
assert data["login_ok"] is True
print("integrations_ok")
PY

echo "[2/7] create project"
PROJECT_JSON="$(curl -fsS -X POST "$API_URL/v1/projects" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Codex Integration\",\"root_path\":\"$PROJECT_ROOT\"}")"
PROJECT_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$PROJECT_JSON")"

echo "[3/7] get default conversation"
CONVS_JSON="$(curl -fsS "$API_URL/v1/projects/$PROJECT_ID/conversations")"
CONV_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["id"])' "$CONVS_JSON")"

echo "[4/7] send natural-language message (no tagged commands)"
TASK_JSON="$(curl -fsS -X POST "$API_URL/v1/projects/$PROJECT_ID/conversations/$CONV_ID/messages" \
  -H 'Content-Type: application/json' \
  -d '{"role":"user","content":"Create a file named integration_from_codex.txt in the project root.","start_run":true,"mode":"manual"}')"
RUN_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["run_id"])' "$TASK_JSON")"

echo "[5/7] wait for run completion"
RUN_STATUS="pending"
for _ in $(seq 1 120); do
  RUN_JSON="$(curl -fsS "$API_URL/v1/projects/$PROJECT_ID/runs/$RUN_ID")"
  RUN_STATUS="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$RUN_JSON")"
  if [[ "$RUN_STATUS" == "done" || "$RUN_STATUS" == "failed" || "$RUN_STATUS" == "cancelled" ]]; then
    break
  fi
  sleep 0.25
done

if [[ "$RUN_STATUS" != "done" ]]; then
  echo "Run did not finish successfully: $RUN_STATUS" >&2
  echo "$RUN_JSON" >&2
  exit 1
fi

echo "[6/7] verify file + run step engine"
if [[ ! -f "$PROJECT_ROOT/integration_from_codex.txt" ]]; then
  echo "Expected file not created by CLI flow" >&2
  exit 1
fi
CONTENT="$(cat "$PROJECT_ROOT/integration_from_codex.txt")"
if [[ "$CONTENT" != "created-by-fake-codex" ]]; then
  echo "Unexpected file content: $CONTENT" >&2
  exit 1
fi

python3 - <<'PY' "$PROJECT_ROOT/.stash/stash.db"
import json
import sqlite3
import sys

db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
row = conn.execute("SELECT output_json FROM run_steps ORDER BY step_index DESC LIMIT 1").fetchone()
assert row is not None, "No run steps found"
output = json.loads(row[0] or "{}")
assert output.get("engine") == "codex-cli", f"Expected codex-cli engine, got: {output.get('engine')}"
print("engine_ok")
PY

echo "[7/7] verify log evidence"
grep -q "Planner selected codex planner path" "$BACKEND_LOG"
grep -q "Execution finished engine=codex-cli" "$BACKEND_LOG"
grep -q "You are the Stash planner." "$FAKE_CODEX_LOG"
grep -q "Command:" "$FAKE_CODEX_LOG"

echo "Codex CLI integration test passed"
echo "project_id=$PROJECT_ID"
echo "run_id=$RUN_ID"
echo "backend_log=$BACKEND_LOG"
echo "fake_codex_log=$FAKE_CODEX_LOG"
