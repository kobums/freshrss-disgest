#!/usr/bin/env bash
# .env 를 읽어 환경변수로 넣고 요약 스크립트를 실행한다.
set -euo pipefail
cd "$(dirname "$0")"
set -a
[ -f .env ] && source .env
set +a
exec python3 summarize_unread.py "$@"
