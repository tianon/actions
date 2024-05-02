#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

: host "${host:=${GITHUB_SERVER_URL%/}}"

git config --local --unset "http.$host/.extraheader" || :
git remote remove origin || :
