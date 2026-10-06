#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pre-push-divergence-gate.sh
#
# PURPOSE: Refuse a push whose branch is missing commits that are already on
#          the branch it will merge into. A branch cut from dev that keeps
#          working while other PRs land on dev reaches its PR behind dev: CI
#          tests a tree nobody will ship, and conflicts surface after the push
#          instead of before it. This gate fetches the target and counts.
#
# TARGET, per pushed branch (the remote ref name, not the local one):
#   dev, promote/*   -> main   (a promotion must already contain main)
#   *sync-dev-with-main*
#                    -> main   (the post-release sync branch is cut from main
#                               and merged into dev; see AGENTS.md)
#   main             -> none   (main is the root of the flow)
#   anything else    -> dev
#
# EXEMPT (pass with a note): hotfix/, release/, backport/, tagged-release/
#   -- the same deviation lanes branch-flow-gate exempts; they are cut from
#   and merged to places other than dev on purpose.
#
# OVERRIDE: DIVERGENCE_GATE=off git push   (prints a note, checks nothing)
#
# OFFLINE: if the target cannot be fetched, the gate warns and lets the push
#   through. A stale local ref is never used as the answer. A push to a URL
#   rather than a configured remote is not checked either (there is no
#   remote-tracking ref to compare with).
#
# USAGE:   tools/pre-push-divergence-gate.sh [<remote-name>] < <pre-push stdin>
#          tools/pre-push-divergence-gate.sh --help
#          stdin lines: <local-ref> <local-sha> <remote-ref> <remote-sha>
#
# EXIT:    0 = every pushed branch contains its target (or was skipped)
#          1 = at least one pushed branch is behind its target
#          2 = usage error
# -----------------------------------------------------------------------------
set -euo pipefail

# Git sets GIT_DIR for hooks under a linked worktree; it would override the
# cwd-based repo discovery the fetch and rev-list below rely on.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

usage() {
    echo "Usage: tools/pre-push-divergence-gate.sh [<remote-name>] < <pre-push stdin>"
    awk 'NR>2 && /^#/ {sub(/^# ?/,""); if ($0 !~ /^-+$/) print; next} NR>2 {exit}' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option '$1' (see --help)" >&2; exit 2 ;;
esac
REMOTE="${1:-origin}"

ZERO_SHA="0000000000000000000000000000000000000000"
EXEMPT_PREFIXES=(hotfix/ release/ backport/ tagged-release/)

if [[ "${DIVERGENCE_GATE:-on}" == "off" ]]; then
    echo "  divergence gate: DIVERGENCE_GATE=off, not checked"
    exit 0
fi

target_for() {
    local branch="$1" p
    for p in "${EXEMPT_PREFIXES[@]}"; do
        [[ "$branch" == "$p"* ]] && { echo "exempt:$p"; return; }
    done
    case "$branch" in
        main)                               echo "" ;;
        dev|promote/*|*sync-dev-with-main*) echo "main" ;;
        *)                                  echo "dev" ;;
    esac
}

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "  divergence gate: '$REMOTE' is not a configured remote, not checked"
    exit 0
fi

BEHIND=0
FETCHED=" "   # targets fetched successfully this run, space-delimited
FAILED=" "    # targets whose fetch failed this run

while read -r _local_ref local_sha remote_ref _remote_sha; do
    [[ -n "${local_sha:-}" ]] || continue
    [[ "$local_sha" == "$ZERO_SHA" ]] && continue          # branch deletion
    [[ "$remote_ref" == refs/heads/* ]] || continue        # tags, notes, etc.
    branch="${remote_ref#refs/heads/}"
    target="$(target_for "$branch")"

    if [[ -z "$target" ]]; then
        echo "  ✓ $branch: no target branch to compare against"
        continue
    fi
    if [[ "$target" == exempt:* ]]; then
        echo "  ✓ $branch: exempt (${target#exempt:} branches are not merged through dev)"
        continue
    fi

    if [[ "$FAILED" == *" $target "* ]]; then
        echo "  ⚠ $branch: could not fetch $REMOTE/$target, divergence not checked"
        continue
    fi
    if [[ "$FETCHED" != *" $target "* ]]; then
        if git fetch --quiet "$REMOTE" "refs/heads/$target:refs/remotes/$REMOTE/$target" 2>/dev/null; then
            FETCHED+="$target "
        else
            FAILED+="$target "
            echo "  ⚠ $branch: could not fetch $REMOTE/$target (offline?), divergence not checked"
            continue
        fi
    fi

    if ! missing="$(git rev-list --count "$local_sha..refs/remotes/$REMOTE/$target" 2>/dev/null)"; then
        echo "  ⚠ $branch: could not compare with $REMOTE/$target, divergence not checked"
        continue
    fi
    if [[ "$missing" -gt 0 ]]; then
        BEHIND=$((BEHIND + 1))
        word="commits"; [[ "$missing" -eq 1 ]] && word="commit"
        echo "  ❌ $branch is missing $missing $word that $REMOTE/$target already has."
        echo "     Bring them in, re-run your checks, then push again:"
        echo "       git rebase $REMOTE/$target"
        echo "     (Override for this push only: DIVERGENCE_GATE=off git push)"
    else
        echo "  ✓ $branch: contains $REMOTE/$target"
    fi
done

[[ "$BEHIND" -eq 0 ]]
