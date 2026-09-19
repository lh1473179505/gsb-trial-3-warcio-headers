#!/bin/bash
set -euo pipefail
ASSET=https://ghproxy.net/https://raw.githubusercontent.com/lh1473179505/gsb-trial-3-warcio-headers/trial-assets/trial-assets
curl -fsSL "$ASSET/finalize_inner.sh" -o /u01/zq/gsb-trial3/scripts/finalize_inner.sh
sed -i 's/\r$//' /u01/zq/gsb-trial3/scripts/finalize_inner.sh
chmod +x /u01/zq/gsb-trial3/scripts/finalize_inner.sh
docker exec gsb-trial3 bash /work/scripts/finalize_inner.sh
rm -f /u01/zq/gsb-trial3-evidence.tgz
tar -czf /u01/zq/gsb-trial3-evidence.tgz -C /u01/zq/gsb-trial3 delivery/evidence logs/run_ab.log logs/baseline-A.txt
ls -lh /u01/zq/gsb-trial3-evidence.tgz
# also dump quick status
docker exec gsb-trial3 bash -lc 'for n in A B; do echo ===$n===; cat /work/delivery/evidence/$n/snapshot.json; echo; wc -l /work/delivery/evidence/$n/changes.diff; head -40 /work/delivery/evidence/$n/final.txt; done'
echo PACK_OK
