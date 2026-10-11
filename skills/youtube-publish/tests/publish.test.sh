#!/usr/bin/env bash
# Surface: skills/youtube-publish/scripts/youtube-publish.py
# Inputs: skills/youtube-publish/tests/lib/test_publish.py and tests/fixtures/api.json
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -B "$here/lib/test_publish.py"
