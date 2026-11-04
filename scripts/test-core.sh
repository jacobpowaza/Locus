#!/usr/bin/env bash
# Build and test the platform-independent Scheduled Runs core.
#
#   scripts/test-core.sh            # swift test (native toolchain if present, else Docker)
#   scripts/test-core.sh --filter X # extra args are passed to `swift test`
#
# On Linux without a Swift toolchain this uses the official swift:6.2 image.
# Build products go to .build/ (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${LOCUS_SWIFT_IMAGE:-swift:6.2}"

if command -v swift >/dev/null 2>&1; then
  exec swift test "$@"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: neither 'swift' nor 'docker' is available" >&2
  exit 1
fi

exec docker run --rm \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/work -w /work \
  "$IMAGE" \
  swift test --scratch-path /work/.build "$@"
