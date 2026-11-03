#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p outputs/namespace-acceptance
# Exit 77 is a required capability failure in CI, never a successful skip.
python3 -B test/scripts/namespace_acceptance.py | tee outputs/namespace-acceptance/result.json
