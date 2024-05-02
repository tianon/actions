#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

: repository "${INPUT_REPOSITORY:=$GITHUB_REPOSITORY}"
: ref "${FETCH_REF:=${INPUT_REF:-$GITHUB_SHA}}"
: fetch-depth "${depth:=${INPUT_FETCH_DEPTH:-1}}"

: host "${host:=${GITHUB_SERVER_URL%/}}"

git --version

: set-safe-directory "${INPUT_SET_SAFE_DIRECTORY=true}"
case "${INPUT_SET_SAFE_DIRECTORY,,}" in
	true|yes|1) git config --global --add safe.directory "$PWD" ;;
esac

git init --quiet "$PWD"
git remote add origin "$host/${INPUT_REPOSITORY%.git}.git"
git config --local gc.auto 0

set +x # TODO
: "${INPUT_TOKEN:=$ACTIONS_RUNTIME_TOKEN}"
b64token="$(tr -d '\n' <<<"x-access-token:$INPUT_TOKEN" | base64 -w0)"
git config --local "http.$host/.extraheader" "Authorization: Basic $b64token"
set -x # TODO

# TODO (local) branch
fetchArgs=(
	--prune
	--progress
	--no-tags # TODO optional tags
	--no-recurse-submodules # TODO optional submodules
	origin
)
if [ "$depth" = '0' ]; then
	: # TODO this is supposed to imply *all* branches and *all* tags, but for now it'll just imply no --depth
	# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/ref-helper.ts#L65-L73
	#fetchArgs+=( '+refs/heads/*:refs/remotes/origin/*' )
	#if [[ "$FETCH_REF" == refs/pull/* ]]; then ...
else
	fetchArgs+=( "--depth=$depth" )
	# TODO https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/ref-helper.ts#L75-L124
fi
git fetch "${fetchArgs[@]}" "$FETCH_REF":

git checkout --progress --force FETCH_HEAD # TODO make a branch
git log -1
