#!/bin/sh
set -eu

GITHUB_REPO=revoltify/mysql
REF=${MYSQLCTL_REF:-main}

fail() {
    printf 'mysqlctl install: %s\n' "$*" >&2
    exit 1
}

require_tools() {
    for tool in "$@"; do
        command -v "$tool" > /dev/null 2>&1 || fail "$tool is required"
    done
}

commit_of() {
    curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/commits/$1" 2> /dev/null \
        | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)",$/\1/p' | head -n 1
}

install_dir() {
    [ -n "${MYSQLCTL_INSTALL_DIR:-}" ] && { printf '%s' "$MYSQLCTL_INSTALL_DIR"; return; }
    [ -w /usr/local/bin ] || command -v sudo > /dev/null 2>&1 && { printf '/usr/local/bin'; return; }
    printf '%s/.local/bin' "$HOME"
}

place() {
    if mkdir -p "$2" 2> /dev/null && [ -w "$2" ]; then
        install -m 755 "$1" "$2/mysqlctl"
        return
    fi
    printf 'mysqlctl install: %s is not writable, using sudo\n' "$2" >&2
    sudo mkdir -p "$2"
    sudo install -m 755 "$1" "$2/mysqlctl"
}

on_path() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
        *) return 1 ;;
    esac
}

main() {
    require_tools curl sed bash ssh openssl awk base64
    commit=$(commit_of "$REF")
    [ -n "$commit" ] || commit=$REF
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$commit/ops/mysqlctl" -o "$workdir/source" \
        || fail "cannot download mysqlctl from github.com/$GITHUB_REPO at $commit"
    sed "s/^MYSQLCTL_REF=.*/MYSQLCTL_REF=$commit/" "$workdir/source" > "$workdir/mysqlctl"
    bash -n "$workdir/mysqlctl" || fail "downloaded mysqlctl is not valid bash"

    dir=$(install_dir)
    place "$workdir/mysqlctl" "$dir"
    mkdir -p "${MYSQLCTL_HOME:-$HOME/.mysqlctl}/clusters"
    chmod 700 "${MYSQLCTL_HOME:-$HOME/.mysqlctl}" "${MYSQLCTL_HOME:-$HOME/.mysqlctl}/clusters"

    printf 'installed mysqlctl %s to %s/mysqlctl\n' "$(printf '%s' "$commit" | cut -c1-12)" "$dir"
    on_path "$dir" || printf "add %s to your PATH, e.g.: echo 'export PATH=\"%s:\$PATH\"' >> ~/.zshrc\n" "$dir" "$dir"
    printf 'next: mysqlctl init <cluster-name>   (remove later with: mysqlctl uninstall)\n'
}

main
