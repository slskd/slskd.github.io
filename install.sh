#!/usr/bin/env bash
#
# slskd install script for Linux and macOS
#
# Usage:
#   curl -fsSL https://slskd.org/install.sh | bash
#   curl -fsSL https://slskd.org/install.sh | bash -s -- --version 0.26.1
#   curl -fsSL https://slskd.org/install.sh | bash -s -- --channel canary
#
# Run with --help for all options.

# everything is wrapped in main() so that a partially downloaded script does nothing
set -euo pipefail

REPO="slskd/slskd"
GITHUB_API="https://api.github.com/repos/${REPO}"
GITHUB_DOWNLOAD="https://github.com/${REPO}/releases/download"
NIGHTLY_LINK="https://nightly.link/${REPO}/actions/runs"
CANARY_WORKFLOW="ci.yml"
CANARY_BRANCH="master"
CANARY_MAX_RUNS=10

channel="release"
version=""
install_dir="${SLSKD_INSTALL_DIR:-${HOME}/.local/lib/slskd}"
bin_dir="${SLSKD_BIN_DIR:-${HOME}/.local/bin}"
os_override=""
arch_override=""
no_link=false
dry_run=false
verbose=false
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

tmp_dir=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'; c_dim=$'\033[2m'
else
    c_reset=""; c_bold=""; c_red=""; c_yellow=""; c_green=""; c_dim=""
fi

say() { printf '%s\n' "slskd-install: $*"; }
say_verbose() { if [ "$verbose" = true ]; then printf '%s\n' "${c_dim}slskd-install: $*${c_reset}" >&2; fi; }
say_warning() { printf '%s\n' "${c_yellow}slskd-install: warning: $*${c_reset}" >&2; }
say_success() { printf '%s\n' "${c_green}slskd-install: $*${c_reset}"; }
die() { printf '%s\n' "${c_red}slskd-install: error: $*${c_reset}" >&2; exit 1; }

usage() {
    cat <<EOF
${c_bold}slskd install script${c_reset}

Installs slskd for the current user.

${c_bold}USAGE${c_reset}
    install.sh [options]

${c_bold}OPTIONS${c_reset}
    -c, --channel <channel>    Channel to install from: 'release' (default) or 'canary'.
                               canary installs the latest successful build of the
                               ${CANARY_BRANCH} branch from GitHub Actions.
    -v, --version <version>    Release version to install, e.g. 0.26.1 (default: latest).
                               Must be a tag from https://github.com/${REPO}/releases.
                               Not valid with --channel canary.
    -i, --install-dir <dir>    Directory to install slskd into.
                               Default: ~/.local/lib/slskd (or \$SLSKD_INSTALL_DIR)
    -b, --bin-dir <dir>        Directory in which to create the 'slskd' symlink.
                               Default: ~/.local/bin (or \$SLSKD_BIN_DIR)
        --no-link              Do not create a symlink in the bin directory.
        --os <os>              Override OS detection: linux, linux-musl, osx.
        --arch <arch>          Override architecture detection: x64, arm64, arm.
        --dry-run              Show what would be downloaded and installed, then exit.
        --verbose              Print diagnostic output.
    -h, --help                 Show this help.

${c_bold}ENVIRONMENT${c_reset}
    GITHUB_TOKEN, GH_TOKEN     GitHub token used for API calls and canary downloads.
                               Optional; without one, canary builds are downloaded via
                               nightly.link and API calls are subject to rate limits.

${c_bold}EXAMPLES${c_reset}
    curl -fsSL https://slskd.org/install.sh | bash
    curl -fsSL https://slskd.org/install.sh | bash -s -- --version 0.26.1
    curl -fsSL https://slskd.org/install.sh | bash -s -- --channel canary
EOF
}

cleanup() {
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
        rm -rf "$tmp_dir"
    fi
}

machine_has() {
    command -v "$1" >/dev/null 2>&1
}

parse_args() {
    local opt value

    while [ $# -gt 0 ]; do
        opt="$1"
        value=""

        # support both '--option value' and '--option=value'
        case "$opt" in
            --*=*) value="${opt#*=}"; opt="${opt%%=*}" ;;
            -c|--channel|-v|--version|-i|--install-dir|-b|--bin-dir|--os|--arch)
                [ $# -ge 2 ] && [ -n "$2" ] || die "${opt} requires a value"
                value="$2"
                shift
                ;;
        esac

        case "$opt" in
            -c|--channel) channel="$value" ;;
            -v|--version) version="$value" ;;
            -i|--install-dir) install_dir="$value" ;;
            -b|--bin-dir) bin_dir="$value" ;;
            --os) os_override="$value" ;;
            --arch) arch_override="$value" ;;
            --no-link) no_link=true ;;
            --dry-run) dry_run=true ;;
            --verbose) verbose=true ;;
            -h|--help|-\?) usage; exit 0 ;;
            *) die "unknown option '${opt}'. Run with --help for usage." ;;
        esac
        shift
    done

    channel="$(printf '%s' "$channel" | tr '[:upper:]' '[:lower:]')"
    case "$channel" in
        release|canary) ;;
        *) die "invalid channel '${channel}'. Valid channels are 'release' and 'canary'." ;;
    esac

    # accept 'v0.26.1' as well as '0.26.1'
    version="${version#v}"

    if [ "$channel" = "canary" ] && [ -n "$version" ]; then
        die "--version can't be used with --channel canary. Canary always installs the latest ${CANARY_BRANCH} build."
    fi

    [ -n "$install_dir" ] || die "--install-dir requires a value"
    [ -n "$bin_dir" ] || die "--bin-dir requires a value"
}

get_os() {
    if [ -n "$os_override" ]; then
        case "$os_override" in
            linux|linux-musl|osx) printf '%s' "$os_override"; return ;;
            *) die "invalid --os '${os_override}'. Valid values are linux, linux-musl and osx." ;;
        esac
    fi

    local uname_s
    uname_s="$(uname -s)"

    case "$uname_s" in
        Darwin) printf 'osx' ;;
        Linux)
            if is_musl; then
                printf 'linux-musl'
            else
                printf 'linux'
            fi
            ;;
        FreeBSD) die "FreeBSD isn't supported by this script. See https://github.com/${REPO}#installation" ;;
        CYGWIN*|MINGW*|MSYS*) die "use install.ps1 to install on Windows: irm https://slskd.org/install.ps1 | iex" ;;
        *) die "unsupported OS '${uname_s}'" ;;
    esac
}

is_musl() {
    if [ -f /etc/alpine-release ]; then
        return 0
    fi

    if ls /lib/ld-musl-* >/dev/null 2>&1; then
        return 0
    fi

    if machine_has ldd && ldd --version 2>&1 | grep -qi musl; then
        return 0
    fi

    return 1
}

get_arch() {
    local os="$1"

    if [ -n "$arch_override" ]; then
        case "$arch_override" in
            x64|amd64|x86_64) printf 'x64' ;;
            arm64|aarch64) printf 'arm64' ;;
            arm|armhf|armv7l|armv6l) printf 'arm' ;;
            *) die "invalid --arch '${arch_override}'. Valid values are x64, arm64 and arm." ;;
        esac
        return
    fi

    local machine
    machine="$(uname -m)"

    # a shell running under Rosetta on Apple silicon reports x86_64; prefer the native binary
    if [ "$os" = "osx" ] && [ "$machine" = "x86_64" ]; then
        if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
            say_verbose "running under Rosetta; selecting arm64"
            machine="arm64"
        fi
    fi

    # a 32-bit userland on a 64-bit ARM kernel (e.g. older Raspberry Pi OS) can't run arm64 binaries
    if [ "$machine" = "aarch64" ] && [ "$os" != "osx" ] && machine_has getconf; then
        if [ "$(getconf LONG_BIT 2>/dev/null || true)" = "32" ]; then
            say_verbose "64-bit kernel with 32-bit userland; selecting arm"
            machine="armv7l"
        fi
    fi

    case "$machine" in
        x86_64|amd64) printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7*|armv6*|armhf|arm) printf 'arm' ;;
        i386|i686) die "32-bit x86 isn't supported" ;;
        *) die "unsupported architecture '${machine}'" ;;
    esac
}

validate_rid() {
    case "$1" in
        linux-x64|linux-arm64|linux-arm|linux-musl-x64|linux-musl-arm64|linux-musl-arm|osx-x64|osx-arm64) ;;
        *) die "no slskd build is available for '${1}'" ;;
    esac
}

check_dependencies() {
    if ! machine_has curl && ! machine_has wget; then
        die "curl or wget is required to download slskd"
    fi

    if ! machine_has unzip && ! machine_has python3 && ! machine_has bsdtar; then
        die "unzip is required to extract slskd. Install it with your package manager (e.g. 'apt install unzip')"
    fi
}

# http_get <url> [output file]
# writes to stdout if no output file is given. adds the GitHub token to api.github.com requests.
http_get() {
    local url="$1"
    local out="${2:--}"
    local auth=()

    case "$url" in
        https://api.github.com/*)
            if [ -n "$token" ]; then
                auth=("Authorization: Bearer ${token}")
            fi
            ;;
    esac

    say_verbose "GET ${url}"

    if machine_has curl; then
        local args=(--fail --silent --show-error --location --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -o "$out")
        if [ "${#auth[@]}" -gt 0 ]; then
            args+=(-H "${auth[0]}")
        fi
        if [ "$out" != "-" ] && [ -t 2 ]; then
            args=("${args[@]/--silent/--progress-bar}")
        fi
        curl "${args[@]}" "$url"
    else
        local args=(--quiet --tries=3 --https-only -O "$out")
        if [ "${#auth[@]}" -gt 0 ]; then
            args+=(--header="${auth[0]}")
        fi
        if [ "$out" != "-" ] && [ -t 2 ]; then
            args+=(--show-progress)
        fi
        wget "${args[@]}" "$url"
    fi
}

# extracts the value of the first "key": "value" (string) pair in pretty printed JSON from stdin
json_string() {
    grep -o "\"$1\": *\"[^\"]*\"" | head -n 1 | sed -E "s/\"$1\": *\"([^\"]*)\"/\1/"
}

get_latest_release() {
    local response tag
    response="$(http_get "${GITHUB_API}/releases/latest")" || die "failed to fetch the latest release from GitHub"
    tag="$(printf '%s' "$response" | json_string tag_name)"
    [ -n "$tag" ] || die "failed to determine the latest release version"
    printf '%s' "$tag"
}

# finds the newest successful canary build that has a non-expired artifact for the given rid.
# prints "<run id> <artifact name> <artifact download url>"
find_canary_artifact() {
    local rid="$1"
    local runs run_urls run_url artifacts match

    runs="$(http_get "${GITHUB_API}/actions/workflows/${CANARY_WORKFLOW}/runs?branch=${CANARY_BRANCH}&event=push&status=success&per_page=${CANARY_MAX_RUNS}")" \
        || die "failed to fetch canary builds from GitHub. If you're rate limited, set GITHUB_TOKEN and try again."

    # each run has exactly one artifacts_url, which makes it a reliable way to enumerate runs without jq
    run_urls="$(printf '%s' "$runs" | grep -o '"artifacts_url": *"[^"]*"' | sed -E 's/.*"(https[^"]*)"/\1/')" || true
    [ -n "$run_urls" ] || die "no successful canary builds found on the ${CANARY_BRANCH} branch"

    for run_url in $run_urls; do
        artifacts="$(http_get "${run_url}?per_page=100")" || continue

        # artifacts look like slskd-0.26.1.65534+6a450e41-linux-x64. find the one for this rid
        # and make sure it hasn't expired
        match="$(printf '%s\n' "$artifacts" | awk -v rid="$rid" '
            /"name":/ {
                name = $0; sub(/.*"name": *"/, "", name); sub(/".*/, "", name)
                found = (name ~ ("^slskd-.*-" rid "$")) && (name !~ /\.dockerbuild$/)
                url = ""
                next
            }
            found && /"archive_download_url":/ {
                url = $0; sub(/.*"archive_download_url": *"/, "", url); sub(/".*/, "", url)
                next
            }
            found && /"expired":/ {
                if ($0 ~ /false/) { print name " " url; exit }
                found = 0
            }
        ')"

        if [ -n "$match" ]; then
            local run_id="${run_url%/artifacts}"
            run_id="${run_id##*/}"
            printf '%s %s' "$run_id" "$match"
            return
        fi

        say_verbose "no usable ${rid} artifact in ${run_url}"
    done

    die "no canary build with an unexpired ${rid} artifact was found in the last ${CANARY_MAX_RUNS} runs"
}

extract_zip() {
    local zip="$1"
    local dest="$2"

    mkdir -p "$dest"

    if machine_has unzip; then
        unzip -q -o "$zip" -d "$dest"
    elif machine_has bsdtar; then
        bsdtar -xf "$zip" -C "$dest"
    else
        python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest"
    fi
}

# replaces the contents of install_dir with the contents of staging_dir
install_files() {
    local staging_dir="$1"

    [ -f "${staging_dir}/slskd" ] || die "the downloaded archive doesn't contain an slskd binary"

    # zips produced by GitHub Actions don't preserve the executable bit
    chmod +x "${staging_dir}/slskd"

    if [ -e "$install_dir" ]; then
        [ -d "$install_dir" ] || die "${install_dir} exists and isn't a directory"

        # refuse to delete a directory that doesn't look like a previous slskd install
        if [ -n "$(ls -A "$install_dir" 2>/dev/null)" ] && [ ! -f "${install_dir}/slskd" ]; then
            die "${install_dir} is not empty and doesn't contain a previous slskd install. Choose a different --install-dir."
        fi
    fi

    mkdir -p "$(dirname "$install_dir")"

    local new_dir="${install_dir}.new.$$"
    local old_dir="${install_dir}.old.$$"

    # copy then rename so that an existing install is replaced in one step
    cp -R "$staging_dir" "$new_dir"

    if [ -d "$install_dir" ]; then
        mv "$install_dir" "$old_dir"
    fi

    if ! mv "$new_dir" "$install_dir"; then
        [ -d "$old_dir" ] && mv "$old_dir" "$install_dir"
        die "failed to move slskd into ${install_dir}"
    fi

    rm -rf "$old_dir"
}

link_binary() {
    mkdir -p "$bin_dir"

    local link="${bin_dir}/slskd"

    if [ -e "$link" ] && [ ! -L "$link" ]; then
        say_warning "${link} exists and isn't a symlink; not replacing it"
        return
    fi

    ln -sf "${install_dir}/slskd" "$link"
}

print_path_hint() {
    case ":${PATH}:" in
        *":${bin_dir}:"*) return ;;
    esac

    local rc
    case "$(basename "${SHELL:-}")" in
        zsh) rc="~/.zshrc" ;;
        bash) rc="~/.bashrc" ;;
        fish) rc="~/.config/fish/config.fish" ;;
        *) rc="your shell's profile" ;;
    esac

    echo
    say_warning "${bin_dir} is not in your PATH"
    if [ "$(basename "${SHELL:-}")" = "fish" ]; then
        printf '  Add it by running:\n\n    fish_add_path %s\n\n' "$bin_dir"
    else
        printf '  Add it by adding the following line to %s:\n\n    export PATH="%s:$PATH"\n\n' "$rc" "$bin_dir"
    fi
}

main() {
    parse_args "$@"
    check_dependencies

    local os arch rid
    os="$(get_os)"
    arch="$(get_arch "$os")"
    rid="${os}-${arch}"
    validate_rid "$rid"

    say_verbose "channel: ${channel}, platform: ${rid}"

    local download_url description

    if [ "$channel" = "canary" ]; then
        local found run_id artifact_name artifact_url
        found="$(find_canary_artifact "$rid")"
        read -r run_id artifact_name artifact_url <<<"$found"

        if [ -n "$token" ] && machine_has curl; then
            download_url="$artifact_url"
        else
            # GitHub requires authentication to download artifacts, even for public repositories.
            # nightly.link proxies the download for anonymous users.
            download_url="${NIGHTLY_LINK}/${run_id}/${artifact_name}.zip"
        fi

        description="canary build ${artifact_name#slskd-} (https://github.com/${REPO}/actions/runs/${run_id})"
    else
        if [ -z "$version" ]; then
            version="$(get_latest_release)"
        fi

        download_url="${GITHUB_DOWNLOAD}/${version}/slskd-${version}-${rid}.zip"
        description="slskd ${version} (${rid})"
    fi

    if [ "$dry_run" = true ]; then
        say "dry run; nothing will be installed"
        say "  version:     ${description}"
        say "  download:    ${download_url}"
        say "  install dir: ${install_dir}"
        if [ "$no_link" = false ]; then
            say "  symlink:     ${bin_dir}/slskd"
        fi
        exit 0
    fi

    tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t slskd)"
    trap cleanup EXIT

    say "downloading ${description}"

    local zip="${tmp_dir}/slskd.zip"
    local download_ok=true

    if [ "$channel" = "canary" ] && [ -n "$token" ] && machine_has curl; then
        # artifact downloads redirect to blob storage, which rejects the Authorization header,
        # so resolve the redirect first and then download without the token
        local blob_url
        blob_url="$(curl --silent --show-error --fail -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer ${token}" "$download_url" 2>/dev/null || true)"
        if [ -n "$blob_url" ]; then
            http_get "$blob_url" "$zip" || download_ok=false
        else
            say_verbose "failed to resolve artifact download with token; falling back to nightly.link"
            http_get "${NIGHTLY_LINK}/${run_id}/${artifact_name}.zip" "$zip" || download_ok=false
        fi
    else
        http_get "$download_url" "$zip" || download_ok=false
    fi

    if [ "$download_ok" = false ]; then
        if [ "$channel" = "release" ]; then
            die "failed to download ${download_url}. Make sure version '${version}' exists at https://github.com/${REPO}/releases and has a ${rid} build."
        fi
        die "failed to download ${download_url}"
    fi

    say "extracting"
    extract_zip "$zip" "${tmp_dir}/extracted"

    say "installing to ${install_dir}"
    install_files "${tmp_dir}/extracted"

    if [ "$no_link" = false ]; then
        link_binary
    fi

    echo
    say_success "slskd was installed successfully!"

    if [ "$no_link" = false ]; then
        print_path_hint
    fi

    local app_dir="~/.local/share/slskd"
    if [ "$os" = "osx" ]; then
        app_dir="~/Library/Application Support/slskd"
    fi

    cat <<EOF

  Run 'slskd' to start it, then browse to http://localhost:5030.
  The default username and password are both 'slskd'.

  Configuration and data are stored in ${app_dir} by default.
  See https://github.com/${REPO}/blob/master/docs/config.md for configuration options.

EOF
}

main "$@"
