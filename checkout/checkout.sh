#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

uid="$(id -u)"
chown=
if [ "$uid" = '0' ]; then
	# must be a Docker action running in a container 🙃
	# https://docs.github.com/en/actions/sharing-automations/creating-actions/dockerfile-support-for-github-actions#user
	chown="$(stat --format '%u:%g' "$PWD")"
	if command -v gosu > /dev/null && [ "${chown%:*}" != '0' ]; then
		# if we have "gosu" installed, let's side-step the problem entirely by swapping to the user we *should* be running as
		exec gosu "$chown" "$BASH_SOURCE" "$@"
	fi
	# TODO delete this whole block and all downstream effects of it when we're composite
fi

git --version

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/input-helper.ts#L38-L52
# https://nodejs.org/docs/latest-v26.x/api/path.html#pathresolvepaths
path="$PWD${INPUT_PATH:+/${INPUT_PATH#/}}"
# TODO do we care about allowing our `path` input to start with `/` like upstream?  they then constrain it to the workspace anyhow so probably not?
# they also make it relative to GITHUB_WORKSPACE, not PWD, which seems annoying?  and doesn't matter for most users

_truthy() {
	case "$1" in # macOS bash is too old for "${1,,}" here
		true | yes | 1) return 0 ;;
		*)              return 1 ;;
	esac
}

: set-safe-directory "${INPUT_SET_SAFE_DIRECTORY=true}"
if _truthy "$INPUT_SET_SAFE_DIRECTORY" && [ "$uid" = 0 ]; then
	# only needed when running as root with a differently-owned workspace; after a gosu re-exec we already own the workspace so git's ownership check doesn't fire
	git config --global --add safe.directory "$path"
	# (composite still can run as root, especially on other platforms or with bring-your-own-runner so this is still needed after Docker/gosu go away)
	# TODO we might need this in more cases, because of containers? https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L47
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L25-L28
if [ -f "$path" ]; then
	rm -f "$path"
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-directory-helper.ts#L90-L124
: clean "${INPUT_CLEAN=true}"
if _truthy "$INPUT_CLEAN" && [ -e "$path" ]; then
	if ! git -C "$path" clean -ffdx || ! git -C "$path" reset --hard HEAD; then
		find "$path" -mindepth 1 -delete
	fi
fi

mkdir -p "$path" # has to stay "-p" for macOS's sake (no GNU coreutils; --verbose unavailable too)

git init --quiet "$path"
cd "$path"

host="${INPUT_GITHUB_SERVER_URL:-${GITHUB_SERVER_URL:-https://github.com}}"
host="${host%/}"

: repository "${INPUT_REPOSITORY:=$GITHUB_REPOSITORY}"

git remote remove origin || :
git remote add origin "$host/$INPUT_REPOSITORY.git"

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L458-L464 (tryDisableAutomaticGarbageCollection)
git config --local gc.auto 0

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L152-L155
# (happening earlier than upstream because this doesn't need auth)
: lfs "${INPUT_LFS=false}"
if _truthy "$INPUT_LFS"; then
	git lfs install --local
fi

# TODO creds handling was revamped in v6 / df4cb1c069e1874edd31b4311f1884172cec0e10 -- we need to update checkout/.upstream after we review https://github.com/actions/checkout/compare/9f265659d3bb64ab1440b03b12f4d47a24320917..v6#diff-3d2b59189eeedc2d428ddd632e97658fe310f587f7cb63b01f9b98ffc11c0197 down and make sure this is all that needed to update for v6
if [ -n "${INPUT_TOKEN:+x}" ]; then
	# write credentials to a file in RUNNER_TEMP; reference it via includeIf.gitdir: so the token never appears as a git config value or process argument
	# https://github.com/actions/checkout/blob/df4cb1c069e1874edd31b4311f1884172cec0e10/src/git-auth-helper.ts#L326-L410
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

# calculate ref (and commit)
# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/input-helper.ts#L59-L79
ref="${INPUT_REF:-}"
commit=
if [ -z "$ref" ]; then
	if [ "$INPUT_REPOSITORY" = "$GITHUB_REPOSITORY" ]; then
		commit="${GITHUB_SHA:-}"
		ref="${GITHUB_REF:-}"
		if [ -n "$commit" ] && [ -n "$ref" ] && [[ "$ref" != refs/* ]]; then
			ref="refs/heads/$ref"
		fi
	fi
fi
# + https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L136-L150 -> https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L298-L324 (getDefaultBranch)
if [ -z "$ref" ] && [ -z "$commit" ]; then
	lsRemote="$(git ls-remote --quiet --exit-code --symref origin HEAD)"
	ref="$(awk <<<"$lsRemote" '/^ref:[[:space:]]|[[:space:]]HEAD$/ { gsub("^ref:[[:space:]]+|[[:space:]]+HEAD$", ""); print; exit }')"
	# after this command, "ref" might be a commit reference again (this awk handles two separate output forms)
fi
if [[ "$ref" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
	commit="$ref"
	ref=
fi
if [ -z "$ref" ] && [ -z "$commit" ]; then
	echo >&2 "error: ref cannot be empty (we tried to look up HEAD on $host/$INPUT_REPOSITORY and it was *also* empty)"
	exit 1
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L254-L296
fetchArgs=(
	-c protocol.version=2
	fetch
	--prune
	--no-recurse-submodules
	origin
)

# lmao https://github.com/actions/checkout/issues/1453 (upstream carefully preserves the "showProgress" input, passes it all the way down, then *doesn't* pass it to the `git.fetch` function so it doesn't actually apply)
# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L163
: show-progress "${INPUT_SHOW_PROGRESS=true}"
if _truthy "$INPUT_SHOW_PROGRESS"; then
	fetchArgs+=( --progress )
else
	# upstream doesn't bother with `--no-progress` but `git` defaults to `--progress` if stderr is a TTY so this is safer and makes the `show-progress` input provide a useful opt-out
	fetchArgs+=( --no-progress )
fi

# filter (sparse-checkout implies blob:none unless overridden by filter:)
# https://github.com/actions/checkout/blob/44c2b7a8a4ea60a981eaca3cf939b5f4305c123b/src/git-source-provider.ts#L166-L170 
: filter "${INPUT_FILTER:-}"
: sparse-checkout "${INPUT_SPARSE_CHECKOUT:-}"
if [ -n "$INPUT_FILTER" ]; then
	fetchArgs+=( "--filter=$INPUT_FILTER" )
elif _truthy "$INPUT_SPARSE_CHECKOUT"; then
	fetchArgs+=( '--filter=blob:none' )
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/ref-helper.ts#L79-L128 (getRefSpec)
# in the normal case, this is only needed in the case of INPUT_FETCH_DEPTH > 0, but sometimes when we fetch all we have to do a *second* fetch (force push of the remote branch while we were fetching, for example) to get the commit we actually need, so we calculate this every time in case we need it for that second hit
case "$ref" in
	refs/heads/*) getRefSpec=( "+${commit:-$ref}:refs/remotes/origin/${ref#refs/heads/}" ) ;;
	refs/pull/*)  getRefSpec=( "+${commit:-$ref}:refs/remotes/pull/${ref#refs/pull/}" ) ;;
	refs/tags/*)  getRefSpec=( "+${commit:-$ref}:$ref" ) ;;
	*)
		if [ -n "$commit" ]; then
			getRefSpec=( "$commit" )
		else
			getRefSpec=(
				"+refs/heads/$ref*:refs/remotes/origin/$ref*"
				"+refs/tags/$ref*:refs/tags/$ref*"
			)
		fi
		;;
esac

# Build fetch refspecs based on ref type and depth
# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L172-L191
: fetch-depth "${INPUT_FETCH_DEPTH:=1}"
fetchRefspecs=()
maybeFetchAgain=
if [ "$INPUT_FETCH_DEPTH" -le '0' ]; then
	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L279-L285
	if [ -e .git/shallow ]; then
		fetchArgs+=( --unshallow )
	fi

	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/ref-helper.ts#L69-L77 (getRefSpecForAllHistory)
	fetchRefspecs+=( '+refs/heads/*:refs/remotes/origin/*' )
	INPUT_FETCH_TAGS='true' # override the "fetch-tags" input (upstream just ignores it completely)
	case "$ref" in
		refs/pull/*)
			fetchRefspecs+=( "+${commit:-$ref}:refs/remotes/pull/${ref#refs/pull/}" )
			;;
	esac

	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L180-L185
	maybeFetchAgain=1
else # INPUT_FETCH_DEPTH > 0
	fetchArgs+=( "--depth=$INPUT_FETCH_DEPTH" )
	fetchRefspecs+=( "${getRefSpec[@]}" )
fi

: fetch-tags "${INPUT_FETCH_TAGS=false}"
if _truthy "$INPUT_FETCH_TAGS"; then
	fetchRefspecs+=( '+refs/tags/*:refs/tags/*' )
else
	fetchArgs+=( --no-tags )
fi

git "${fetchArgs[@]}" "${fetchRefspecs[@]}"

# might have to fetch a second time to make sure we get the commit we're actually interested in (https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L180-L185)
if [ -n "$maybeFetchAgain" ]; then
	skipFetch=
	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/ref-helper.ts#L133-L182 (testRef)
	if [ -z "$commit" ]; then
		skipFetch=1 # no commit sha, nothing to check
	elif [ -z "$ref" ]; then
		# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L386-L390 (shaExists)
		if git rev-parse --verify --quiet "$commit^{object}"; then
			skipFetch=1
		fi
	else
		# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L377-L380 (revParse)
		case "$ref" in
			refs/heads/*)
				# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L104-L113 (branchExists)
				if \
					remote="$(git branch --list --remote "origin/${ref#ref/heads/}")" \
					&& [ -n "$remote" ] \
					&& revParse="$(git rev-parse "refs/remotes/origin/${ref#ref/heads/}")" \
					&& [ "$commit" = "$revParse" ] \
				; then
					skipFetch=1
				fi
				;;
			refs/tags/*)
				# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L432-L435 (tagExists)
				if \
					tag="$(git tag --list "${ref#refs/tags/}")" \
					&& [ -n "$tag" ] \
					&& revParse="$(git rev-parse "$ref")" \
					&& [ "$commit" = "$revParse" ] \
				; then
					skipFetch=1
				fi
				;;
			*)
				echo >&2 "warning: unexpected ref format '$ref' when testing ref info"
				skipFetch=1
				;;
		esac
	fi
	if [ -z "$skipFetch" ]; then
		git "${fetchArgs[@]}" "${getRefSpec[@]}"
	fi
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L194-L201
# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/ref-helper.ts#L13-L67 (getCheckoutInfo)
checkoutRef=
checkoutStartPoint=
if [ -z "$ref" ]; then
	checkoutRef="$commit"
else
	case "$ref" in
		refs/heads/*)
			checkoutRef="${ref#refs/heads/}"
			checkoutStartPoint="refs/remotes/origin/${ref#refs/heads/}"
			;;
		refs/pull/*)
			checkoutRef="refs/remotes/pull/${ref#refs/pull/}"
			;;
		refs/tags/*)
			checkoutRef="$ref"
			;;
		refs/*)
			checkoutRef="${commit:-$ref}"
			;;
		*)
			if \
				remote="$(git branch --list --remote "origin/$ref")" \
				&& [ -n "$remote" ] \
			; then
				checkoutRef="$ref"
				checkoutStartPoint="refs/remotes/origin/$ref"
			elif \
				tag="$(git tag --list "$ref")" \
				&& [ -n "$tag" ] \
			; then
				checkoutRef="$ref"
			else
				echo >&2 "error: branch or tag with name '$ref' not found"
				exit 1
			fi
			;;
	esac
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L203-L211
if _truthy "$INPUT_LFS" && [ -z "$INPUT_SPARSE_CHECKOUT" ]; then
	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L343-L350 (lfsFetch)
	git lfs fetch origin "${checkoutStartPoint:-$checkoutRef}"
fi

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L213-L228
if [ -z "$INPUT_SPARSE_CHECKOUT" ]; then
	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L179-L183 (disableSparseCheckout)
	git sparse-checkout disable
	git config --local --unset-all extensions.worktreeConfig || :
else
	: sparse-checkout-cone-mode "${INPUT_SPARSE_CHECKOUT_CONE_MODE=true}"
	if _truthy "$INPUT_SPARSE_CHECKOUT_CONE_MODE"; then
		# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L185-L187 (sparseCheckout)
		git sparse-checkout set --stdin <<<"$INPUT_SPARSE_CHECKOUT"
	else
		# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L189-L204 (sparseCheckoutNonConeMode)
		git config core.sparseCheckout true
		output="$(git rev-parse --git-path info/sparse-checkout)"
		cat <<<"$INPUT_SPARSE_CHECKOUT" >> "$output"
	fi
fi

# https://github.com/actions/checkout/blob/e8d4307400f9427dba7cb98e488d6ab85f1cec5f/src/git-command-manager.ts#L223-L232 (checkout)
checkoutArgs=( -c advice.detachedHead=false checkout --progress --force )
if [ -n "$checkoutStartPoint" ]; then
	checkoutArgs+=( -B "$checkoutRef" "$checkoutStartPoint" )
else
	checkoutArgs+=( "$checkoutRef" )
fi
git "${checkoutArgs[@]}"

# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L235-L258
: submodules "${INPUT_SUBMODULES=false}"
if _truthy "$INPUT_SUBMODULES" || [ "$INPUT_SUBMODULES" = 'recursive' ]; then
	# TODO configureGlobalAuth

	submoduleRecursive=()
	if [ "$INPUT_SUBMODULES" = 'recursive' ]; then
		submoduleRecursive+=( --recursive )
	fi

	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L403-L410 (submoduleSync)
	git submodule sync "${submoduleRecursive[@]}"

	# https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-command-manager.ts#L412-L424 (submoduleUpdate)
	submoduleArgs=(
		-c protocol.version=2
		submodule update
		--init
		--force
		"${submoduleRecursive[@]}"
	)
	if [ "$INPUT_FETCH_DEPTH" -gt 0 ]; then
		submoduleArgs+=( "--depth=$INPUT_FETCH_DEPTH" )
	fi
	git "${submoduleArgs[@]}"

	git submodule foreach "${submoduleRecursive[@]}" 'git config --local gc.auto 0'

	# TODO credentials persistence too 😬
fi

git log -1

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	commit="$(git log -1 --format=%H)"
	{
		echo "commit=$commit"
		echo "ref=$ref"
	} >> "$GITHUB_OUTPUT"
fi

# TODO replicate checkCommitInfo safety checks?  https://github.com/actions/checkout/blob/9f265659d3bb64ab1440b03b12f4d47a24320917/src/git-source-provider.ts#L267-L276

if [ -n "$chown" ]; then
	echo "::group::chown $chown $path"
	# TODO delete this (and gosu bits above) when we're composite
	chown --recursive --changes "$chown" .
	echo '::endgroup::'
fi

if [ -n "${INPUT_TOKEN:+x}" ]; then
	: persist-credentials "${INPUT_PERSIST_CREDENTIALS=false}"
	if ! _truthy "$INPUT_PERSIST_CREDENTIALS"; then
		rm -f "$credsConfig" # macOS has no GNU coreutils
		git config --local --unset "includeIf.gitdir:${gitDir}.path" || :
		git config --local --unset "includeIf.gitdir:${gitDir}/worktrees/*.path" || :
		git config --local --unset "includeIf.gitdir:${hostGitDir}.path" || :
		git config --local --unset "includeIf.gitdir:${hostGitDir}/worktrees/*.path" || :
	fi
fi
