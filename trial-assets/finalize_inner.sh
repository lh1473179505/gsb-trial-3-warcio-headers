#!/bin/bash
set -euo pipefail
INIT=$(git -C /work/candidates/warcio rev-parse HEAD)
echo INIT=$INIT
for NAME in A B; do
  R=/work/runs/$NAME
  E=/work/delivery/evidence/$NAME
  test -f "$E/run_meta.json"
  git -C "$R" add -A
  if git -C "$R" diff --cached --quiet; then
    echo "$NAME no changes" >&2
    exit 1
  fi
  git -C "$R" -c user.name=lh1473179505 -c user.email=lh1473179505@users.noreply.github.com \
    commit -m "Trial 3 run ${NAME}: model output (non-ascii http headers)"
  COMMIT=$(git -C "$R" rev-parse HEAD)
  PARENT=$(git -C "$R" rev-parse HEAD^)
  test "$PARENT" = "$INIT"
  git -C "$R" bundle create "$E/source.bundle" "$NAME"
  git -C "$R" diff "$INIT"..HEAD > "$E/changes.diff" || true
  python3 - <<PY
import json
from pathlib import Path
name="$NAME"
e=Path("/work/delivery/evidence")/name
meta=json.loads((e/"run_meta.json").read_text())
meta.update({
  "commit": "$COMMIT",
  "parent": "$PARENT",
  "url": "https://github.com/lh1473179505/gsb-trial-3-warcio-headers/commit/$COMMIT",
})
(e/"snapshot.json").write_text(json.dumps(meta, indent=2)+"\n")
print(name, meta["commit"], meta["session_id"])
PY
done
echo FINALIZE_OK
