#!/usr/bin/env bash
set -euo pipefail

CHANNEL=""
MANIFEST=""

usage() {
  echo "Usage: record-ppa-pending-state.sh --channel stable|beta --manifest FILE" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || usage
[[ -f "$MANIFEST" ]] || { echo "Missing manifest: $MANIFEST" >&2; exit 2; }

manifest_channel="$(jq -r '.channel' "$MANIFEST")"
manifest_status="$(jq -r '.status' "$MANIFEST")"
[[ "$manifest_channel" == "$CHANNEL" ]] || { echo "Manifest channel mismatch: $manifest_channel" >&2; exit 2; }
[[ "$manifest_status" == "pending" ]] || { echo "Manifest is not pending: $manifest_status" >&2; exit 2; }

state_worktree="$(mktemp -d)"
rmdir "$state_worktree"
cleanup() {
  git worktree remove --force "$state_worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git fetch --no-tags origin release-state:refs/remotes/origin/release-state
git worktree add -B release-state "$state_worktree" refs/remotes/origin/release-state
git -C "$state_worktree" config user.name "github-actions[bot]"
git -C "$state_worktree" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for attempt in 1 2 3; do
  git fetch --no-tags origin release-state:refs/remotes/origin/release-state
  git -C "$state_worktree" reset --hard refs/remotes/origin/release-state
  cp "$MANIFEST" "$state_worktree/state/pending-${CHANNEL}.json"
  rm -f "$state_worktree/state/failed-${CHANNEL}.json"
  git -C "$state_worktree" add -A -- state
  # release-state may ignore *.json; stage the pending manifest explicitly.
  git -C "$state_worktree" add -f -- "state/pending-${CHANNEL}.json"

  if git -C "$state_worktree" diff --cached --quiet; then
    echo "release-state already records this pending ${CHANNEL} release"
    exit 0
  fi

  git -C "$state_worktree" commit -m "chore: record pending ${CHANNEL} PPA release"
  if git -C "$state_worktree" push origin HEAD:release-state; then
    exit 0
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo "Pending release-state push failed after retries." >&2
    exit 1
  fi
  sleep 5
done
