#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

: repository "${INPUT_REPOSITORY:=$GITHUB_REPOSITORY}"
: ref "${FETCH_REF:=${INPUT_REF:-${GITHUB_SHA:-HEAD}}}"
: fetch-depth "${depth:=${INPUT_FETCH_DEPTH:-1}}"

host="${INPUT_GITHUB_SERVER_URL:-${GITHUB_SERVER_URL:-https://github.com}}"
host="${host%/}"
: host "$host"

uid="$(id -u)"
if [ "$uid" = '0' ]; then
	# must be a Docker action running in a container 🙃
	# https://docs.github.com/en/actions/sharing-automations/creating-actions/dockerfile-support-for-github-actions#user
	chown="$(stat --format '%u:%g' "$PWD")"
	if command -v gosu > /dev/null && [ "${chown%:*}" != '0' ]; then
		# if we have "gosu" installed, let's side-step the problem entirely by swapping to the user we *should* be running as
		exec gosu "$chown" "$BASH_SOURCE" "$@"
	fi
	# TODO delete this whole block and all downstream effects of it when we're composite
else
	chown=
fi
path="$PWD${INPUT_PATH:+/${INPUT_PATH#/}}"

git --version

: set-safe-directory "${INPUT_SET_SAFE_DIRECTORY=true}"
case "$INPUT_SET_SAFE_DIRECTORY" in
	true | yes | 1)
		# only needed when running as root with a differently-owned workspace; after a gosu re-exec we already own the workspace so git's ownership check doesn't fire
		if [ "$uid" = 0 ]; then
			git config --global --add safe.directory "$path"
		fi
		;;
esac

: clean "${INPUT_CLEAN=true}"
case "$INPUT_CLEAN" in
	true | yes | 1)
		# https://github.com/actions/checkout/blob/cbb722410c2e876e24abbe8de2cc27693e501dcb/src/git-directory-helper.ts#L90-L124
		if [ -e "$path" ] && { ! git -C "$path" clean -ffdx || ! git -C "$path" reset --hard HEAD; }; then
			find "$path" -mindepth 1 -delete
		fi
		;;
esac

mkdir -p "$path" # has to stay "-p" for macOS's sake (no GNU coreutils; --verbose unavailable too)
git init --quiet "$path"
cd "$path"
git remote remove origin || :
git remote add origin "$host/${INPUT_REPOSITORY%.git}.git"
git config --local gc.auto 0

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L152-L155
: lfs "${INPUT_LFS=false}"
case "$INPUT_LFS" in
	true | yes | 1) git lfs install --local ;;
esac

if [ -n "${INPUT_TOKEN:+x}" ]; then
	# write credentials to a file in RUNNER_TEMP; reference it via includeIf.gitdir: so the token never appears as a git config value or process argument
	# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/git-auth-helper.ts#L326-L409
	credsConfig="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/git-credentials-XXXXXXXXXX.config")"
	if [ -n "$chown" ]; then
		# TODO delete this (and gosu bits above) when we're composite
		chown "$chown" "$credsConfig"
	fi
	set +x
	b64token="$(tr -d '\n' <<<"x-access-token:$INPUT_TOKEN" | base64 --wrap=0)"
	printf '[http "%s/"]\n\textraheader = AUTHORIZATION: basic %s\n' "$host" "$b64token" > "$credsConfig"
	unset b64token
	set -x
	gitDir="$(git rev-parse --absolute-git-dir)"
	gitDir="$(readlink -f "$gitDir")" # -f instead of --canonicalize for macOS's sake (no GNU coreutils)
	git config --local "includeIf.gitdir:${gitDir}.path" "$credsConfig"
	git config --local "includeIf.gitdir:${gitDir}/worktrees/*.path" "$credsConfig"
	# best-effort host-side entries so that regular (non-container) job steps also get credentials when persist-credentials: true
	# we can't know the real host paths from inside the container, so we assume the standard GitHub-hosted runner layout:
	#   RUNNER_TEMP  -> /home/runner/work/_temp
	#   workspace    -> /home/runner/work/REPONAME/REPONAME
	# fails silently (no credentials for host git commands) when the assumption is wrong -- eg, self-hosted runners or Forgejo
	# correct fix: become a composite action running on the host, which knows the real paths natively (see CLAUDE.md)
	# TODO https://github.com/actions/runner/issues/1478
	repoName="${INPUT_REPOSITORY##*/}"
	hostGitDir="/home/runner/work/${repoName}/${repoName}${INPUT_PATH:+/${INPUT_PATH#/}}/.git"
	hostCredsConfig="/home/runner/work/_temp/${credsConfig##*/}"
	git config --local "includeIf.gitdir:${hostGitDir}.path" "$hostCredsConfig"
	git config --local "includeIf.gitdir:${hostGitDir}/worktrees/*.path" "$hostCredsConfig"
fi

fetchArgs=(
	--prune
	--no-tags
	--no-recurse-submodules # TODO optional submodules
	origin
)

: show-progress "${INPUT_SHOW_PROGRESS=true}"
case "$INPUT_SHOW_PROGRESS" in
	true | yes | 1) fetchArgs+=( --progress ) ;;
	*) fetchArgs+=( --no-progress ) ;;
esac

# Filter (sparse-checkout implies blob:none unless overridden by filter:)
# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/git-source-provider.ts#L163-L170
if [ -n "${INPUT_FILTER:-}" ]; then
	fetchArgs+=( "--filter=$INPUT_FILTER" )
elif [ -n "${INPUT_SPARSE_CHECKOUT:-}" ]; then
	fetchArgs+=( '--filter=blob:none' )
fi

# Build fetch refspecs based on ref type and depth
# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/ref-helper.ts#L69-L148
if [ "$depth" = '0' ]; then
	# All history: fetch all branches and tags; add PR head explicitly if applicable
	fetchRefspecs=( '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' )
	case "$FETCH_REF" in
		refs/pull/*)
			prBranch="${FETCH_REF#refs/}"
			fetchRefspecs+=( "+${FETCH_REF}:refs/remotes/${prBranch}" )
			;;
		refs/*) ;;
		*)
			# SHA: fetch explicitly in case it's not reachable from any branch or tag
			fetchRefspecs+=( "${FETCH_REF}:" )
			;;
	esac
else
	fetchArgs+=( "--depth=$depth" )
	case "$FETCH_REF" in
		refs/heads/*)
			branch="${FETCH_REF#refs/heads/}"
			fetchRefspecs=( "+${FETCH_REF}:refs/remotes/origin/${branch}" )
			;;
		refs/tags/*)
			fetchRefspecs=( "+${FETCH_REF}:${FETCH_REF}" )
			;;
		refs/pull/*)
			prBranch="${FETCH_REF#refs/}"
			fetchRefspecs=( "+${FETCH_REF}:refs/remotes/${prBranch}" )
			;;
		refs/*)
			fetchRefspecs=( "+${FETCH_REF}:${FETCH_REF}" )
			;;
		*)
			# SHA or unqualified ref -- no local ref name; object lands in object store via FETCH_HEAD
			fetchRefspecs=( "${FETCH_REF}:" )
			;;
	esac
	: fetch-tags "${INPUT_FETCH_TAGS=false}"
	case "$INPUT_FETCH_TAGS" in
		true | yes | 1) fetchRefspecs+=( '+refs/tags/*:refs/tags/*' ) ;;
	esac
fi
git fetch "${fetchArgs[@]}" "${fetchRefspecs[@]}"

# Sparse checkout (must be configured before git checkout)
# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/git-source-provider.ts#L236-L249
if [ -n "${INPUT_SPARSE_CHECKOUT:-}" ]; then
	: sparse-checkout-cone-mode "${INPUT_SPARSE_CHECKOUT_CONE_MODE=true}"
	# init sets the mode; set --stdin then reads patterns from stdin
	# --cone/--no-cone on 'set' were only added in git 2.36; 'init' has had them since 2.25
	case "$INPUT_SPARSE_CHECKOUT_CONE_MODE" in
		true | yes | 1) git sparse-checkout init --cone ;;
		*) git sparse-checkout init ;;
	esac
	printf '%s\n' "$INPUT_SPARSE_CHECKOUT" | git sparse-checkout set --stdin
fi

# Checkout with local branch creation
# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/ref-helper.ts#L13-L67
case "$FETCH_REF" in
	refs/heads/*)
		branch="${FETCH_REF#refs/heads/}"
		git checkout --progress --force -B "$branch" "refs/remotes/origin/$branch"
		;;
	refs/tags/*)
		git checkout --progress --force "$FETCH_REF"
		;;
	refs/pull/*)
		prBranch="${FETCH_REF#refs/}"
		git checkout --progress --force "refs/remotes/$prBranch"
		;;
	refs/*)
		git checkout --progress --force "$FETCH_REF"
		;;
	*)
		git checkout --progress --force FETCH_HEAD
		;;
esac

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L203-L209
case "$INPUT_LFS" in
	true | yes | 1) git lfs pull ;;
esac

if [ -n "$chown" ]; then
	echo "::group::chown $chown $path"
	# TODO delete this (and gosu bits above) when we're composite
	chown --recursive --changes "$chown" .
	echo '::endgroup::'
fi

git log -1

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "ref=$FETCH_REF" >> "$GITHUB_OUTPUT"
	echo "commit=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
fi

if [ -n "${INPUT_TOKEN:+x}" ]; then
	: persist-credentials "${INPUT_PERSIST_CREDENTIALS=false}"
	case "$INPUT_PERSIST_CREDENTIALS" in
		true | yes | 1) : ;;
		*)
			rm -f "$credsConfig" # macOS has no GNU coreutils
			git config --local --unset "includeIf.gitdir:${gitDir}.path" || :
			git config --local --unset "includeIf.gitdir:${gitDir}/worktrees/*.path" || :
			git config --local --unset "includeIf.gitdir:${hostGitDir}.path" || :
			git config --local --unset "includeIf.gitdir:${hostGitDir}/worktrees/*.path" || :
			;;
	esac
fi
