# Offline development environment

Python 3.12. The trial uses the upstream source without functional patches.

Recreate the environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-trial.txt
.venv/bin/python -m pip install --no-build-isolation --no-deps -e .
```

Run the offline regression suite from the repository root:

```sh
.venv/bin/python -m pytest -q test/test_archiveiterator.py test/test_bufferedreaders.py test/test_cli.py test/test_check_digest_examples.py test/test_digestverifyingreader.py test/test_limitreader.py test/test_statusandheaders.py test/test_utils.py test/test_writer.py --doctest-modules
```

The baseline result is 221 passed, 1 skipped. External HTTP/proxy/S3 integration suites are not part of this offline baseline. New offline test modules should also be run.
