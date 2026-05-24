#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

uid="$(id -u)"
if [ "$uid" = 0 ] && command -v gosu > /dev/null; then
	owner="$(stat --format '%u:%g' "$PWD")"
	exec gosu "$owner" "$BASH_SOURCE" "$@"
	# TODO delete this whole block when we're composite
fi

path="$PWD${INPUT_PATH:+/${INPUT_PATH#/}}"
if [ ! -e "$path" ]; then
	# if our target path doesn't exist, there's nothing to clean
	exit 0
fi
cd "$path"

# Remove credentials config file and the includeIf entries referencing it.
# With persist-credentials: false, checkout.sh already removed them; rm --force is a no-op.
# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/git-auth-helper.ts#L232-L244
gitDir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
gitDir="$(readlink -f "$gitDir")" # -f instead of --canonicalize for macOS's sake (no GNU coreutils)
credsConfig="$(git config --local --get "includeIf.gitdir:${gitDir}.path" 2>/dev/null || :)"
if [ -n "$credsConfig" ]; then
	rm -vf "$credsConfig" # has to stay short for macOS's sake (no GNU coreutils)
fi
git config --local --unset "includeIf.gitdir:${gitDir}.path" || :
git config --local --unset "includeIf.gitdir:${gitDir}/worktrees/*.path" || :
# Best-effort removal of host-side entries (see checkout.sh for the layout assumption)
repoName="${INPUT_REPOSITORY:=$GITHUB_REPOSITORY}"
repoName="${repoName##*/}"
hostGitDir="/home/runner/work/${repoName}/${repoName}${INPUT_PATH:+/${INPUT_PATH#/}}/.git"
git config --local --unset "includeIf.gitdir:${hostGitDir}.path" || :
git config --local --unset "includeIf.gitdir:${hostGitDir}/worktrees/*.path" || :
