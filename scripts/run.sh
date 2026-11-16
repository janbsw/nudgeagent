#!/usr/bin/env bash
# Builds the app, quits a running instance and opens the fresh build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

pkill -x NudgeAgent || true
sleep 0.5
open "$ROOT/build/NudgeAgent.app"
