#!/bin/bash
# Run inside gsb-trial3 container. Sequential A then B.
set -euo pipefail
export PATH=/work/runtime/node/bin:/work/runtime:$PATH
export CODEX_HOME=/work/model
export GSB_API_KEY=$(cat /work/secrets/api-key)
CODEX=/work/runtime/codex
PROMPT=/work/delivery/prompt.txt
INIT=$(git -C /work/candidates/warcio rev-parse HEAD)

# start transport proxy on host network (container uses host net)
pkill -f 'transport_proxy.py' 2>/dev/null || true
sleep 1
nohup python3 /work/scripts/transport_proxy.py > /work/logs/transport_proxy.log 2>&1 &
for i in $(seq 1 50); do grep -q listening /work/logs/transport_proxy.log && break; sleep 0.2; done
grep -q listening /work/logs/transport_proxy.log

run_one() {
  local NAME=$1
  local WORK=/work/runs/$NAME
  local EV=/work/delivery/evidence/$NAME
  mkdir -p "$EV" /tmp/run-$NAME
  rm -f "$EV"/* /tmp/run-$NAME/*
  git -C "$WORK" reset --hard "$INIT"
  git -C "$WORK" clean -fd
  test "$(git -C "$WORK" rev-parse HEAD)" = "$INIT"
  test -z "$(git -C "$WORK" status --porcelain)"

  "$CODEX" exec -C "$WORK" --json -o /tmp/run-$NAME/final.txt - < "$PROMPT" \
    > /tmp/run-$NAME/events.jsonl 2> /tmp/run-$NAME/stderr.txt
  cp /tmp/run-$NAME/events.jsonl "$EV/"
  cp /tmp/run-$NAME/stderr.txt "$EV/"
  cp /tmp/run-$NAME/final.txt "$EV/" || true

  python3 - <<PY
import json, hashlib, shutil
from pathlib import Path
name="$NAME"
ev=Path("/work/delivery/evidence")/name
events=[json.loads(l) for l in (ev/"events.jsonl").read_text().splitlines() if l.strip()]
assert any(e.get("type")=="turn.completed" for e in events), events[-5:]
assert not any(e.get("type") in ("error","turn.failed") for e in events)
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
}
(ev/"run_meta.json").write_text(json.dumps(meta, indent=2))
print(name, "OK", sid, len(events))
PY
}

# preflight
mkdir -p /work/preflight
"$CODEX" exec -C /work/runs/A --json -o /work/preflight/final.txt - <<<"Reply with exactly: PREFLIGHT_OK. Do not modify any files." \
  > /work/preflight/events.jsonl 2> /work/preflight/stderr.txt
python3 - <<'PY'
import json
from pathlib import Path
events=[json.loads(l) for l in Path('/work/preflight/events.jsonl').read_text().splitlines() if l.strip()]
assert any(e.get('type')=='turn.completed' for e in events)
assert not any(e.get('type') in ('error','turn.failed') for e in events)
final=Path('/work/preflight/final.txt').read_text() if Path('/work/preflight/final.txt').exists() else ''
assert 'PREFLIGHT_OK' in final or 'PREFLIGHT_OK' in Path('/work/preflight/events.jsonl').read_text()
print('PREFLIGHT_OK')
PY
# reset A after preflight
git -C /work/runs/A reset --hard "$INIT"
git -C /work/runs/A clean -fd

mkdir -p /work/delivery/evidence
run_one A
run_one B
echo ALL_RUNS_OK
