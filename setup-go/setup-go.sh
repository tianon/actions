#!/usr/bin/env bash
set -Eeuo pipefail -x

# TODO add "debug-env" input or something?
#env | sort

: go-version "${INPUT_GO_VERSION:-}"
: go-version-file "${INPUT_GO_VERSION_FILE:-}"

if [ -n "${INPUT_GO_VERSION:-}" ] && [ -n "${INPUT_GO_VERSION_FILE:-}" ]; then
	echo '::warning::Both go-version and go-version-file specified; go-version takes precedence'
fi

versionSpec="${INPUT_GO_VERSION:-}"

if [ -z "$versionSpec" ] && [ -n "${INPUT_GO_VERSION_FILE:-}" ]; then
	versionFile="$INPUT_GO_VERSION_FILE"
	if [ ! -f "$versionFile" ]; then
		echo "::error::go-version-file not found: $versionFile"
		exit 1
	fi
	base="$(basename "$versionFile")"
	case "$base" in
		go.mod | go.work)
			# https://github.com/actions/setup-go/blob/78961f6f84d799cd858575bb931c3e51d3b13290/src/installer.ts#L653-L681
			# toolchain directive takes precedence unless GOTOOLCHAIN=local is already in the environment
			if [ "${GOTOOLCHAIN:-}" != 'local' ]; then
				versionSpec="$(jq --null-input --raw-input --raw-output '
					first(
						inputs
						| select(startswith("toolchain go"))
						| ltrimstr("toolchain go")
					)
				' "$versionFile")"
			fi
			if [ -z "$versionSpec" ]; then
				versionSpec="$(jq --null-input --raw-input --raw-output '
					first(
						inputs
						| select(startswith("go "))
						| ltrimstr("go ")
						| split(" ")[0]
					)
				' "$versionFile")"
			fi
			;;
		.tool-versions)
			versionSpec="$(jq --null-input --raw-input --raw-output '
				first(
					inputs
					| select(startswith("golang "))
					| ltrimstr("golang ")
					| split(" ")[0]
				)
			' "$versionFile")"
			;;
		*)
			versionSpec="$(< "$versionFile")"
			versionSpec="${versionSpec//[[:space:]]/}"
			;;
	esac
	if [ -z "$versionSpec" ]; then
		echo "::error::no Go version found in $versionFile"
		exit 1
	fi
	: "resolved from $versionFile" "$versionSpec"
fi

if [ -z "$versionSpec" ]; then
	versionSpec='stable'
fi

versionSpec="${versionSpec#go}"
: versionSpec "$versionSpec"

# OS detection — $RUNNER_OS is set by the GitHub Actions runner; fall back to uname -s
# for self-hosted runners that may not set it
os="$(uname -s)"
os="${RUNNER_OS:=$os}"
case "$os" in
	Linux*) os='linux' ;;
	macOS | Darwin*) os='darwin' ;;
	Windows | MINGW* | MSYS* | CYGWIN*) os='windows' ;;
	*)
		echo "::error::unsupported OS: $os"
		exit 1
		;;
esac
export os
: os "$os"

# Prefer dpkg/apk (userspace arch) over uname -m (kernel arch); see:
# https://github.com/docker-library/bashbrew/blob/6c47dbbb89c2665758a08e580424c128f5f423da/scripts/bashbrew-host-arch.sh
arch=
if [ -n "${INPUT_ARCHITECTURE:-}" ]; then
	arch="$INPUT_ARCHITECTURE"
elif command -v apk > /dev/null && tryArch="$(apk --print-arch 2>/dev/null)"; then
	arch="$tryArch"
elif command -v dpkg > /dev/null && tryArch="$(dpkg --print-architecture 2>/dev/null)"; then
	arch="${tryArch##*-}"
elif command -v rpm > /dev/null && tryArch="$(rpm --query --queryformat='%{ARCH}' rpm 2>/dev/null)"; then
	arch="$tryArch"
else
	echo '::warning::neither apk nor dpkg nor rpm found; falling back to uname -m for arch detection'
	arch="$(uname -m)"
fi
unset tryArch
case "$arch" in
	386 | i386 | i[3456]86 | x86) arch='386' ;;
	amd64 | x86_64) arch='amd64' ;;
	arm | armv6* | armv7* | armv8* | armhf) arch='armv6l' ;;
	arm64 | aarch64) arch='arm64' ;;
	mips64le | mips64el) arch='mips64le' ;;
	ppc64le | ppc64el) arch='ppc64le' ;;
	riscv64) arch='riscv64' ;;
	s390x) arch='s390x' ;;
	*)
		echo "::error::unsupported architecture: $arch"
		exit 1
		;;
esac
export arch
: arch "$arch"

toolCache="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"

version=''
case "$versionSpec" in
	*.*.*)
		toolDir="${toolCache}/go/${versionSpec}/${arch}"
		if [ -f "${toolDir}.complete" ]; then
			echo "Found Go ${versionSpec} in cache at ${toolDir}"
			version="$versionSpec"
		fi
		;;
esac

if [ -z "$version" ]; then
	echo '::group::Fetching Go release list'
	dist="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all')"
	echo '::endgroup::'

	case "$versionSpec" in
		stable)
			version="$(jq <<<"$dist" --raw-output '
				first(
					.[]
					| select(.stable == true)
					| select(any(.files[]; .os == env.os and .arch == env.arch and .kind == "archive"))
					| .version
					| ltrimstr("go")
				)
				// error("no stable version found for \(env.os)/\(env.arch)")
			')"
			;;
		oldstable)
			version="$(jq <<<"$dist" --raw-output '
				(
					first(
						.[]
						| select(.stable == true)
						| select(any(.files[]; .os == env.os and .arch == env.arch and .kind == "archive"))
						| .version
						| ltrimstr("go")
						| split(".")[0:2]
						| join(".")
					)
					// error("no stable version found for \(env.os)/\(env.arch)")
				) as $latest
				| first(
					.[]
					| select(.stable == true)
					| select(any(.files[]; .os == env.os and .arch == env.arch and .kind == "archive"))
					| select((.version | ltrimstr("go") | split(".")[0:2] | join(".")) != $latest)
					| .version
					| ltrimstr("go")
				)
				// error("no oldstable version found for \(env.os)/\(env.arch)")
			')"
			;;
		*.*.*)
			version="$(jq <<<"$dist" --raw-output --arg spec "$versionSpec" '
				first(
					.[]
					| select(.version == ("go" + $spec))
					| select(any(.files[]; .os == env.os and .arch == env.arch and .kind == "archive"))
					| .version
					| ltrimstr("go")
				)
				// error("version go\($spec) not found for \(env.os)/\(env.arch)")
			')"
			;;
		*.*)
			version="$(jq <<<"$dist" --raw-output --arg spec "$versionSpec" '
				(
					first(
						.[]
						| select(.stable == true)
						| select(.version | ltrimstr("go") | startswith($spec + "."))
						| select(any(.files[]; .os == env.os and .arch == env.arch and .kind == "archive"))
						| .version
						| ltrimstr("go")
					)
					// first(
						.[]
						| select(.version == ("go" + $spec))
						| select(any(.files[]; .os == env.os and .arch == env.arch and .kind == "archive"))
						| .version
						| ltrimstr("go")
					)
				)
				// error("no version matching \($spec) found for \(env.os)/\(env.arch)")
			')"
			;;
		*)
			echo "::error::unsupported version spec '${versionSpec}' (expected: stable, oldstable, 1.21, 1.21.0, etc.)"
			exit 1
			;;
	esac
	export version

	shell="$(jq <<<"$dist" --raw-output '
		first(
			.[]
			| select(.version == ("go" + env.version))
			| .files[]
			| select(.os == env.os and .arch == env.arch and .kind == "archive")
		)
		| "sha256=\(.sha256 | @sh) filename=\(.filename | @sh)"
	')"
	eval "$shell"
fi

: resolved-version "$version"

toolDir="${toolCache}/go/${version}/${arch}"
if [ ! -f "${toolDir}.complete" ]; then
	echo "::group::Downloading Go ${version}"
	tmpFile="$(mktemp --tmpdir="${RUNNER_TEMP:-/tmp}" "go-XXXXXXXXXX")"
	curl -fL -o "$tmpFile" "https://dl.google.com/go/${filename}"
	sha256sum <<<"${sha256} *${tmpFile}" -c - # these flags have to be silly for macOS's sake (it has no GNU coreutils)
	case "$filename" in
		*.tar.gz)
			mkdir -p "$toolDir" # has to stay "-p" for macOS's sake (again, no GNU coreutils)
			tar \
				--extract \
				--gzip \
				--file="$tmpFile" \
				--strip-components=1 \
				--directory="$toolDir"
			;;
		*.zip)
			mkdir --parents "${toolDir%/*}"
			unzip -q "$tmpFile" -d "${toolDir%/*}"
			mv "${toolDir%/*}/go" "$toolDir"
			;;
	esac
	rm -f "$tmpFile" # macOS GNU coreutils strikes again
	touch "${toolDir}.complete"
	echo '::endgroup::'
fi

echo "${toolDir}/bin" >> "$GITHUB_PATH"
echo "${GOPATH:-$HOME/go}/bin" >> "$GITHUB_PATH"
# https://go.dev/doc/toolchain — prevent Go 1.21+ from auto-downloading a different toolchain
echo 'GOTOOLCHAIN=local' >> "$GITHUB_ENV"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "go-version=$version" >> "$GITHUB_OUTPUT"
fi

goVersion="$("${toolDir}/bin/go" version)"
echo "::notice::${goVersion}"

echo '::group::go env'
"${toolDir}/bin/go" env
echo '::endgroup::'
