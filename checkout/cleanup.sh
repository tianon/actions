#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

: host "${host:=${GITHUB_SERVER_URL%/}}"
path="$PWD${INPUT_PATH:+/${INPUT_PATH#/}}"
if [ ! -e "$path" ]; then
	# if our target path doesn't exist, there's nothing to clean
	exit 0
fi
cd "$path"

git config --local --unset "http.$host/.extraheader" || :
git remote remove origin || :
