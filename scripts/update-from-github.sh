#!/usr/bin/env bash
set -euo pipefail

upstream_ref="${1:-origin/main}"
current_branch="$(git branch --show-current)"

if [[ -z "$current_branch" ]]; then
  echo "Detached HEAD detected. Check out your MilkyWayReborn work branch first." >&2
  exit 1
fi

echo "Current branch: $current_branch"
echo "Upstream ref:    $upstream_ref"

stash_name=""
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  stash_name="milkyway-local-before-github-update-$(date +%Y%m%d-%H%M%S)"
  echo "Saving local working tree to stash: $stash_name"
  git stash push -u -m "$stash_name"
fi

echo "Fetching remotes..."
git fetch --all --prune

echo "Merging $upstream_ref into $current_branch..."
git merge --no-edit "$upstream_ref"

if [[ -n "$stash_name" ]]; then
  echo "Restoring stashed local edits..."
  if ! git stash pop; then
    echo
    echo "Stash pop had conflicts. Resolve them, then run:"
    echo "  git add <files>"
    echo "  git commit"
    exit 1
  fi
fi

echo
echo "Update complete. Verify with:"
echo "  make clean package"
echo "  otool -L .theos/obj/debug/MilkyWayReborn.dylib"
