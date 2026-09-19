#!/bin/bash
set -euo pipefail
docker exec gsb-trial3 bash -lc "pkill -f 'pip ' || true" 2>/dev/null || true
sleep 1

docker exec gsb-trial3 bash -lc '
set -e
for R in /work/candidates/warcio /work/runs/A /work/runs/B; do
  f=$R/requirements-trial.txt
  [ -f "$f" ] || continue
  sed -i "s/idna==3.20/idna>=3.19/" "$f"
  sed -i "s/certifi==2026.7.22/certifi>=2024.0.0/" "$f"
  sed -i "s/packaging==26.3/packaging>=24.0/" "$f"
  sed -i "s/urllib3==2.8.0/urllib3>=2.0.0/" "$f"
  sed -i "s/requests==2.34.2/requests>=2.31.0/" "$f"
  sed -i "s/Pygments==2.21.0/Pygments>=2.0/" "$f"
  sed -i "s/pytest==9.1.1/pytest>=8.0/" "$f"
  sed -i "s/pytest-cov==7.1.0/pytest-cov>=5.0/" "$f"
  sed -i "s/coverage==7.16.1/coverage>=7.0/" "$f"
  sed -i "s/hypothesis==6.168.0/hypothesis>=6.100/" "$f"
  sed -i "s/setuptools==84.0.0/setuptools>=68/" "$f"
  sed -i "s/wheel==0.48.0/wheel>=0.40/" "$f"
  sed -i "s/charset-normalizer==3.5.1/charset-normalizer>=3.0/" "$f"
done
echo RELAXED
'

docker exec gsb-trial3 bash -lc '
set -euo pipefail
setup_venv() {
  local R=$1
  rm -rf "$R/.venv"
  python3 -m venv "$R/.venv"
  "$R/.venv/bin/pip" install -U pip -i https://mirrors.aliyun.com/pypi/simple/
  "$R/.venv/bin/pip" install -r "$R/requirements-trial.txt" -i https://mirrors.aliyun.com/pypi/simple/
  "$R/.venv/bin/pip" install --no-build-isolation --no-deps -e "$R"
}
mkdir -p /work/runs
rm -rf /work/runs/A /work/runs/B
cp -a /work/candidates/warcio /work/runs/A
cp -a /work/candidates/warcio /work/runs/B
git -C /work/runs/A checkout -B A
git -C /work/runs/B checkout -B B
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
echo ALL_PREPARE_OK
