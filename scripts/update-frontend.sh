#!/usr/bin/env bash
# Fork-specific (not in upstream): builds donetick/frontend in self-hosted mode
# and vendors the output into frontend/dist, so `go build` / `docker build`
# embed a real UI without needing Node at build time. Mirrors the frontend
# steps of .github/workflows/go-release.yml.
#
# Usage: scripts/update-frontend.sh [frontend-git-ref]   (default: develop)
# The frontend repo has no tags; pick the commit that was on its default
# branch when the matching backend release was published.
set -euo pipefail

REF="${1:-develop}"
REPO="${FRONTEND_REPO:-https://github.com/donetick/frontend.git}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$REPO" "$WORK/frontend"
git -C "$WORK/frontend" checkout --quiet "$REF"
SHA="$(git -C "$WORK/frontend" rev-parse HEAD)"

(cd "$WORK/frontend" && npm run build-selfhosted)

rm -rf "$ROOT/frontend/dist"
cp -r "$WORK/frontend/dist" "$ROOT/frontend/dist"
echo "$REPO $SHA" > "$ROOT/frontend/FRONTEND_VERSION"

echo "frontend/dist updated from $REPO @ $SHA"
