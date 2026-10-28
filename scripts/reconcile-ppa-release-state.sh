#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
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
  overall_failure=false
  changed=false
  git fetch --no-tags origin release-state:refs/remotes/origin/release-state
  git -C "$state_worktree" reset --hard refs/remotes/origin/release-state

  for channel in stable beta; do
    pending_rel="state/pending-${channel}.json"
    pending="$state_worktree/$pending_rel"
    [[ -f "$pending" ]] || continue

    result="$(mktemp)"
    bash "$repo_root/scripts/verify-ppa-release.sh" --manifest "$pending" --result-json "$result"
    status="$(jq -r '.status' "$result")"

    case "$status" in
      pending)
        echo "${channel}: still pending"
        ;;
      retryable)
        message="$(jq -r '.message // "upload did not reach Launchpad"' "$result")"
        rm -f "$pending" "$state_worktree/state/failed-${channel}.json"
        changed=true
        echo "${channel}: cleared pending state for controlled retry: ${message}"
        ;;
      success)
        tag="$(jq -r '.tag' "$result")"
        commit="$(jq -r '.commit' "$result")"
        revision="$(jq -r '.revision' "$result")"
        printf '%s\n' "$tag" > "$state_worktree/state/latest-${channel}-tag.txt"
        printf '%s\n' "$commit" > "$state_worktree/state/latest-${channel}-commit.txt"
        printf '%s\n' "$revision" > "$state_worktree/state/latest-${channel}-revision.txt"
        rm -f "$pending" "$state_worktree/state/failed-${channel}.json"
        changed=true
        echo "${channel}: promoted ${tag}-0ppa${revision} to verified latest"
        ;;
      failed)
        cp "$result" "$state_worktree/state/failed-${channel}.json"
        rm -f "$pending"
        changed=true
        overall_failure=true
        echo "${channel}: recorded terminal Launchpad failure" >&2
        ;;
      *)
        echo "Unexpected verifier status for ${channel}: $status" >&2
        rm -f "$result"
        exit 1
        ;;
    esac
    rm -f "$result"
  done

  if [[ "$changed" != "true" ]]; then
    [[ "$overall_failure" == "false" ]] || exit 1
    exit 0
  fi

  git -C "$state_worktree" add -A -- state
  # Failure manifests can also be ignored by release-state's *.json rule.
  for channel in stable beta; do
    if [[ -f "$state_worktree/state/failed-${channel}.json" ]]; then
      git -C "$state_worktree" add -f -- "state/failed-${channel}.json"
    fi
  done

  if git -C "$state_worktree" diff --cached --quiet; then
    [[ "$overall_failure" == "false" ]] || exit 1
    exit 0
  fi

  git -C "$state_worktree" commit -m "chore: reconcile Launchpad release state"
  if git -C "$state_worktree" push origin HEAD:release-state; then
    [[ "$overall_failure" == "false" ]] || exit 1
    exit 0
  fi

  if [[ "$attempt" -eq 3 ]]; then
    echo "Release-state reconciliation push failed after retries." >&2
    exit 1
  fi
  sleep 5
done
