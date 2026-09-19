#!/bin/bash
# Retry wrapper: run one side until turn.completed without errors.
set -euo pipefail
export PATH=/work/runtime/node/bin:/work/runtime:$PATH
export CODEX_HOME=/work/model
export GSB_API_KEY=$(cat /work/secrets/api-key)
CODEX=/work/runtime/codex
PROMPT=/work/delivery/prompt.txt
INIT=$(git -C /work/candidates/warcio rev-parse HEAD)
NAME=${1:?need A or B}
MAX=${2:-8}

ensure_proxy() {
  if [ -f /work/logs/transport_proxy.pid ] && kill -0 "$(cat /work/logs/transport_proxy.pid)" 2>/dev/null; then
    return 0
  fi
  : > /work/logs/transport_proxy.log
  nohup python3 /work/scripts/transport_proxy.py > /work/logs/transport_proxy.log 2>&1 &
  echo $! > /work/logs/transport_proxy.pid
  for i in $(seq 1 50); do grep -q listening /work/logs/transport_proxy.log && break; sleep 0.2; done
  grep -q listening /work/logs/transport_proxy.log
}

run_once() {
  local WORK=/work/runs/$NAME
  local EV=/work/delivery/evidence/$NAME
  local TMP=/tmp/run-$NAME
  mkdir -p "$EV" "$TMP"
  rm -f "$EV"/* "$TMP"/*
  git -C "$WORK" reset --hard "$INIT"
  git -C "$WORK" clean -fd
  ensure_proxy
  set +e
  "$CODEX" exec -C "$WORK" --json -o "$TMP/final.txt" - < "$PROMPT" \
    > "$TMP/events.jsonl" 2> "$TMP/stderr.txt"
  local code=$?
  set -e
  cp "$TMP/events.jsonl" "$EV/" || true
  cp "$TMP/stderr.txt" "$EV/" || true
  cp "$TMP/final.txt" "$EV/" 2>/dev/null || true
  python3 - <<PY
import json, hashlib, shutil, sys
from pathlib import Path
name="$NAME"
ev=Path("/work/delivery/evidence")/name
tmp=Path("/tmp/run-"+name)
events=[json.loads(l) for l in (tmp/"events.jsonl").read_text().splitlines() if l.strip()]
types=[e.get("type") for e in events]
print("events", len(events), "types_tail", types[-8:], "exit", $code)
if any(t in ("error","turn.failed") for t in types) or "turn.completed" not in types:
    sys.exit(10)
# require workspace changes
import subprocess
st=subprocess.check_output(["git","-C",f"/work/runs/{name}","status","--porcelain"], text=True)
if not st.strip():
    print("NO_DIFF")
    sys.exit(11)
sid=next(e["thread_id"] for e in events if e["type"]=="thread.started")
traj=list(Path("/work/model/sessions").rglob("*"+sid+".jsonl"))
assert len(traj)==1, traj
shutil.copyfile(traj[0], ev/"trajectory.jsonl")
meta={
  "name": name,
  "session_id": sid,
  "events": len(events),
  "trajectory_sha256": hashlib.sha256((ev/"trajectory.jsonl").read_bytes()).hexdigest(),
  "initial": "$INIT",
  "exit_code": $code,
}
(ev/"run_meta.json").write_text(json.dumps(meta, indent=2))
print(name, "OK", sid, len(events))
PY
}

for attempt in $(seq 1 "$MAX"); do
  echo "ATTEMPT $NAME $attempt/$MAX"
  if run_once; then
    echo "SUCCESS $NAME attempt $attempt"
    exit 0
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "/work/delivery/evidence/_failed-$NAME-$stamp"
  cp -a "/tmp/run-$NAME" "/work/delivery/evidence/_failed-$NAME-$stamp/" 2>/dev/null || true
  echo "FAIL $NAME attempt $attempt — retry after cooldown"
  sleep 15
done
echo "GIVE_UP $NAME"
exit 1
