#!/bin/bash
# CI only: publish dist/PuckBridge.zip as this branch's preview pre-release, replacing the previous one.
# The app reads the "key: value" lines of the notes (branch, commit, version, signed, summary).
# Env: GITHUB_REF_NAME, GITHUB_SHA, GITHUB_REPOSITORY, VERSION, SIGNED (true/false), GH_TOKEN.
set -euo pipefail
TAG="$(scripts/preview-tag.sh "$GITHUB_REF_NAME")"
NOTES="${RUNNER_TEMP:-/tmp}/preview-notes.md"
{
  echo "Preview build of \`$GITHUB_REF_NAME\`. It may be unfinished: install it from Puck Bridge → Settings → Beta Access."
  echo
  echo "branch: $GITHUB_REF_NAME"
  echo "commit: $GITHUB_SHA"
  echo "version: $VERSION"
  echo "signed: ${SIGNED:-false}"
  echo "summary: $(git log -1 --format=%s | tr -d '\r')"
} > "$NOTES"
gh release delete "$TAG" --repo "$GITHUB_REPOSITORY" --cleanup-tag --yes >/dev/null 2>&1 || true
EXTRA=()
[ -f dist/MacScreenshots.zip ] && EXTRA+=(dist/MacScreenshots.zip)   # pictures of the Mac app's windows (sample data)
gh release create "$TAG" dist/PuckBridge.zip ${EXTRA[@]+"${EXTRA[@]}"} --repo "$GITHUB_REPOSITORY" --prerelease --latest=false \
  --target "$GITHUB_SHA" --title "Preview: $GITHUB_REF_NAME" --notes-file "$NOTES"
echo "✓ Published $TAG ($VERSION)"
