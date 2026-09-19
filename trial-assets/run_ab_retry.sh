#!/bin/bash
set -euo pipefail
# Sequential A then B with per-side retries.
ASSET=https://ghproxy.net/https://raw.githubusercontent.com/lh1473179505/gsb-trial-3-warcio-headers/trial-assets/trial-assets
curl -fsSL "$ASSET/run_one_retry.sh" -o /u01/zq/gsb-trial3/scripts/run_one_retry.sh
sed -i 's/\r$//' /u01/zq/gsb-trial3/scripts/run_one_retry.sh
chmod +x /u01/zq/gsb-trial3/scripts/run_one_retry.sh

# skip preflight in retry script; do a quick one here
docker exec gsb-trial3 bash -lc '
set -euo pipefail
export PATH=/work/runtime:$PATH
export CODEX_HOME=/work/model
export GSB_API_KEY=$(cat /work/secrets/api-key)
if [ -f /work/logs/transport_proxy.pid ]; then kill $(cat /work/logs/transport_proxy.pid) 2>/dev/null || true; fi
: > /work/logs/transport_proxy.log
nohup python3 /work/scripts/transport_proxy.py > /work/logs/transport_proxy.log 2>&1 &
echo $! > /work/logs/transport_proxy.pid
sleep 1
grep -q listening /work/logs/transport_proxy.log
printf "%s\n" "Reply with exactly: PREFLIGHT_OK. Do not modify any files." > /work/preflight/prompt.txt
/work/runtime/codex exec -C /work/runs/A --json -o /work/preflight/final.txt - < /work/preflight/prompt.txt > /work/preflight/events.jsonl 2>/work/preflight/stderr.txt
grep -q PREFLIGHT_OK /work/preflight/final.txt
INIT=$(git -C /work/candidates/warcio rev-parse HEAD)
git -C /work/runs/A reset --hard "$INIT"; git -C /work/runs/A clean -fd
echo PREFLIGHT_OK
'

docker exec gsb-trial3 bash /work/scripts/run_one_retry.sh A 10
docker exec gsb-trial3 bash /work/scripts/run_one_retry.sh B 10
echo ALL_RUNS_OK
