#!/bin/bash

REPO_URL="https://api.github.com/jdx/mise/releases/repository/releases/latest"
DEST_DIR="/usr/local/bin"
PROGRAM_NAME="mise-v2024.10.11"

download_and_install() {
    local os_arch
    os_arch=$(detect_os_arch)

    local download_url
    download_url=$(get_download_url "$os_arch")

    if [[ -z $download_url ]]; then
        printf "No compatible release found for %s\n" "$os_arch" >&2
        return 1
    fi

    printf "Downloading latest release from: %s\n" "$download_url"
    local tmp_file; tmp_file=$(mktemp)

    if ! curl -L "$download_url" -o "$tmp_file"; then
        printf "Failed to download release.\n" >&2
        return 1
    fi

    if [[ "$tmp_file" == *.tar.gz || "$tmp_file" == *.zip ]]; then
        printf "Unpacking archive...\n"
        if [[ "$tmp_file" == *.tar.gz ]]; then
            tar -xzf "$tmp_file" -C "$DEST_DIR"
        else
            unzip -d "$DEST_DIR" "$tmp_file"
        fi
    else
        chmod +x "$tmp_file"
        mv "$tmp_file" "$DEST_DIR/$PROGRAM_NAME-$os_arch"
    fi

    printf "Installation completed: %s\n" "$DEST_DIR/$PROGRAM_NAME-$os_arch"
}

detect_os_arch() {
    local os arch
    os=$(uname | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case $arch in
        x86_64) arch="x86_64|x64" ;;
        aarch64) arch="arm64" ;;
        arm*) arch="arm" ;;
        i*86) arch="i386|x86" ;;
        *) printf "Unsupported architecture: %s\n" "$arch" >&2; return 1 ;;
    esac

    printf "%s-(%s)" "$os" "$arch"
}

get_download_url() {
    local os_arch=$1
    local release_info download_url

    if ! release_info=$(curl -s "$REPO_URL"); then
        printf "Failed to fetch release information.\n" >&2
        return 1
    fi

    download_url=$(echo "$release_info" | jq -r --arg os_arch "$os_arch" '
        .assets[] | select(.browser_download_url | test($os_arch)) | .browser_download_url' | head -n 1)

    if [[ -z $download_url || $download_url == "null" ]]; then
        printf "No suitable binary found for %s\n" "$os_arch" >&2
        return 1
    fi

    printf "%s" "$download_url"
}

main() {
    if [[ -z $REPO_URL ]]; then
        printf "Repository URL not defined.\n" >&2
        exit 1
    fi

    if [[ ! -d $DEST_DIR ]]; then
        mkdir -p "$DEST_DIR" || { printf "Failed to create destination directory.\n" >&2; exit 1; }
    fi

    download_and_install
}

main "$@"
