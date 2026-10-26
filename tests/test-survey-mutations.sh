#!/bin/sh
# 複数の壊した版は survey-mutations.py が独立した領域で並列に検査する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/tests/survey-mutations.py"
