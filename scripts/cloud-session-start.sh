#!/usr/bin/env bash
# SessionStart hook for Claude Code cloud sessions: makes sure the Flutter
# SDK is available and every package's dependencies are fetched, so tests
# can run immediately (see docs/benchmarking.md for what runs where).
#
# No-op outside the cloud environment. Idempotent and quiet: prints one
# summary line (hook stdout is shown to the agent).
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

FLUTTER_DIR="${FLUTTER_ROOT:-/opt/flutter}"
if ! command -v flutter >/dev/null 2>&1; then
  if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
    git clone --quiet --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
  fi
  export PATH="$FLUTTER_DIR/bin:$PATH"
fi
# Keep flutter/dart on PATH for the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$(dirname "$(command -v flutter)"):\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
log="$(mktemp)"
status=ok
{
  (cd "$root/packages/syncsphere_core" && dart pub get) &&
  (cd "$root/packages/syncsphere_audio" && flutter pub get) &&
  (cd "$root/app" && flutter pub get)
} >"$log" 2>&1 || status=failed

if [ "$status" = ok ]; then
  echo "SyncSphere: $(flutter --version 2>/dev/null | head -1); dependencies fetched. Android builds run in GitHub Actions (dl.google.com is blocked here)."
  rm -f "$log"
else
  echo "SyncSphere: dependency fetch failed; see $log"
fi
