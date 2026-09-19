#!/bin/bash
set -euo pipefail
WORK=/u01/zq/gsb-trial3
ASSET_BASE=https://ghproxy.net/https://raw.githubusercontent.com/lh1473179505/gsb-trial-3-warcio-headers/trial-assets/trial-assets
API_KEY_FILE="$WORK/secrets/api-key"

mkdir -p "$WORK"/{model,scripts,delivery,secrets,candidates,runtime,runs,preflight,logs}
curl -fsSL "$ASSET_BASE/config.toml" -o "$WORK/model/config.toml"
curl -fsSL "$ASSET_BASE/model_catalog.json" -o "$WORK/model/model_catalog.json"
curl -fsSL "$ASSET_BASE/transport_proxy.py" -o "$WORK/scripts/transport_proxy.py"
curl -fsSL "$ASSET_BASE/prompt.txt" -o "$WORK/delivery/prompt.txt"

# API key injected by kickoff wrapper replacing this marker, or pre-written file.
if [ ! -s "$API_KEY_FILE" ]; then
  echo "MISSING API KEY at $API_KEY_FILE" >&2
  exit 2
fi
chmod 600 "$API_KEY_FILE"
chown -R subadmin:subadmin "$WORK" || true

docker exec gsb-trial3 bash -lc '
set -euo pipefail
export PATH=/work/runtime/node/bin:$PATH
cd /work
if [ ! -x /work/runtime/node/bin/node ]; then
  mkdir -p /work/runtime
  curl -fL --retry 5 -o /tmp/node.tar.xz https://cdn.npmmirror.com/binaries/node/v22.23.2/node-v22.23.2-linux-x64.tar.xz
  tar -xJf /tmp/node.tar.xz -C /work/runtime
  rm -rf /work/runtime/node
  mv /work/runtime/node-v22.23.2-linux-x64 /work/runtime/node
fi
node -v
mkdir -p /work/runtime/codex114
cd /work/runtime/codex114
if [ ! -x node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex ]; then
  npm init -y >/dev/null
  npm install @openai/codex@0.114.0 --registry=https://registry.npmmirror.com
fi
CODEX_BIN=/work/runtime/codex114/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex
"$CODEX_BIN" --version
ln -sfn "$CODEX_BIN" /work/runtime/codex
rm -rf /work/candidates/warcio /tmp/warcio-src
mkdir -p /work/candidates /tmp/warcio-src
curl -fL --retry 5 -o /tmp/warcio-initial.tgz "https://ghproxy.net/https://github.com/lh1473179505/gsb-trial-3-warcio-headers/archive/refs/heads/initial.tar.gz"
tar -xzf /tmp/warcio-initial.tgz -C /tmp/warcio-src
mv /tmp/warcio-src/gsb-trial-3-warcio-headers-initial /work/candidates/warcio
cd /work/candidates/warcio
rm -rf .git
git init
git config user.name lh1473179505
git config user.email lh1473179505@users.noreply.github.com
git add -A
git commit -m "Prepare reproducible offline trial environment"
git branch -M initial
echo INITIAL_SHA=$(git rev-parse HEAD)
'

docker exec gsb-trial3 bash -lc '
set -euo pipefail
rm -rf /work/runs/A /work/runs/B
cp -a /work/candidates/warcio /work/runs/A
cp -a /work/candidates/warcio /work/runs/B
git -C /work/runs/A checkout -B A
git -C /work/runs/B checkout -B B

setup_venv() {
  local R=$1
  python3 -m venv "$R/.venv"
  "$R/.venv/bin/pip" install -U pip -i https://mirrors.aliyun.com/pypi/simple/
  "$R/.venv/bin/pip" install -r "$R/requirements-trial.txt" -i https://mirrors.aliyun.com/pypi/simple/
  "$R/.venv/bin/pip" install --no-build-isolation --no-deps -e "$R"
}

setup_venv /work/runs/A
setup_venv /work/runs/B

cd /work/runs/A
.venv/bin/python -m pytest -q \
  test/test_archiveiterator.py test/test_bufferedreaders.py test/test_cli.py \
  test/test_check_digest_examples.py test/test_digestverifyingreader.py \
  test/test_limitreader.py test/test_statusandheaders.py test/test_utils.py \
  test/test_writer.py --doctest-modules | tee /work/logs/baseline-A.txt
tail -5 /work/logs/baseline-A.txt
echo PREPARE_OK
'

echo ALL_BOOTSTRAP_OK
