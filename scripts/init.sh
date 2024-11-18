#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -eE -o functrace
failure() {
    local lineno=$2
    local fn=$3
    local exitstatus=$4
    local msg=$5
    local lineno_fns=${1% 0}
    if [[ "$lineno_fns" != "0" ]] ; then
        lineno="${lineno} ${lineno_fns}"
    fi
    echo "${BASH_SOURCE[1]}:${fn}[${lineno}] Failed with status ${exitstatus}: $msg"
}
trap 'failure "${BASH_LINENO[*]}" "$LINENO" "${FUNCNAME[*]:-script}" "$?" "$BASH_COMMAND"' ERR

ARCH=$(uname -m)

sudo_cmd() {
    sudo "$@"
}
sudo_function_cmd() {
    local func_name="$1"
    # Check if the function exists and call it with sudo
    if declare -f "$func_name" > /dev/null; then
        shift
        sudo bash -c "$func_name \"\$@\""
    else
        sudo "$@"
    fi
}
environment_setup(){
    log "Setting up environment..."
    chezmoi_bin_dir="$HOME/.local/share/chezmoi/home/dot_local/bin/"
    # Loop through all files starting with 'executable_' in chezmoi_bin_dir
    for script in "$chezmoi_bin_dir"/executable_*; do
        # Check if the file exists
        if [[ -f "$script" ]]; then
            # Get the base name of the script without the path
            script_name=$(basename "$script")
            
            # Create a function with the same name as the script (remove 'executable_' prefix)
            function_name="${script_name#executable_}" # Remove 'executable_' prefix
            if ! command -v "$function_name" &> /dev/null; then
                if [[ -x "$script" ]]; then
                    # Define the function for executable scripts
                    eval "$function_name() { \"$script\" \"\$@\"; }"
                else
                    # Define the function for non-executable scripts
                    eval "$function_name() { bash \"$script\" \"\$@\"; }"
                fi
            fi
        fi
    done
}
# Function to check for required tools
check_required_tools() {
    local required_tools=("git" "openssl" "curl" "ssh-keygen" "gpg" "systemctl")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "Error: Required tool '$tool' is not installed. Please install it before running the script."
            exit 1
        fi
    done
    log "All required tools are installed."
}
log() { 
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

configure_pacman() {
    log "Configuring pacman..."
    sudo_cmd sed -Ei '/Color/s/^#//' "/etc/pacman.conf"
    sudo_cmd sed -i '/^Color$/a ILoveCandy' "/etc/pacman.conf"
}

update_package_lists() {
    log "Updating package lists..."
    sudo_cmd pacman -Syy || { log "Failed to update package lists"; exit 1; }
}

configure_pamac() {
    log "Configuring PAMAC..."
    sudo_cmd sed -Ei '/EnableAUR/s/^#//' "/etc/pamac.conf"
}

arm_swich_to_testing(){
    if [[ "$ARCH" == "aarch64" ]]; then 
        log "Setting pacman to use testing repo by default I wish I could use the standard repository but there are several packages missing in the ARM repository"
        sudo_cmd pacman-mirrors --api --set-branch testing
        sudo_cmd pacman-mirrors --fasttrack 5 
        sudo_cmd pacman -Syu
    fi
}

install_dev_tools() {
    log "Installing development tools..."
    if ! sudo_cmd pacman -Sy --needed --noconfirm yay base-devel patch tk cmake zsh; then
        log "Failed to install development tools"
        exit 1
    fi
}

install_additional_packages() {
    log "Installing additional packages..."
    x86_64_packages="git-credential-manager git-credential-manager-extras google-chrome chromedriver anydesk-bin carapace-bin tailscale python-pipx atuin xmousepasteblock rustdesk-bin"
    aarch64_packages="git-credential-github xclip"
    common_packages="teamviewer fwupd geckodriver yaycache-hook paccache-hook jq xsel sxhkd openssh input-leap fzf"
    case "$ARCH" in
        "x86_64")
            yay -S --needed --noconfirm $x86_64_packages
            ;;
        "aarch64")
            yay -S --needed --noconfirm $aarch64_packages
            ;;
    esac
    yay -S --needed --noconfirm $common_packages

    if [[ "$ARCH" == "aarch64" ]]; then
        sudo_cmd "$HOME/.local/share/chezmoi/home/dot_local/bin/executable_arm-pacman" install tailscale
        sudo_cmd "$HOME/.local/share/chezmoi/home/dot_local/bin/executable_arm-pacman" install atuin
        if ! command -v "xclip" &> /dev/null; then
            sudo_cmd "$HOME/.local/share/chezmoi/home/dot_local/bin/executable_arm-pacman" install xclip
        fi
    fi
}

configure_git_credentials() {
    if [[ "$ARCH" == "x86_64" ]]; then
        log "Setting up Git Credential Manager..."
        git-credential-manager configure
    fi
}

start_services() {
    log "Starting services..."
    sudo_cmd systemctl enable --now tailscaled
    sudo_cmd systemctl enable --now teamviewerd.service
    sudo_cmd systemctl enable --now paccache.timer
    sudo_cmd systemctl enable --now yaycache.timer
    sudo_cmd systemctl enable --now systemd-timesyncd.service
    sudo_cmd systemctl enable --now sshd.service
    sudo_cmd systemctl enable --now avahi-daemon.service
    if [[ "$ARCH" == "x86_64" ]]; then
        sudo_cmd systemctl enable --now anydesk.service
    fi
    
}




configure_firewall() {
    log "Setting up firewall configuration for Tailscaled..."
    sudo_cmd firewall-cmd --permanent --add-masquerade
}

setup_tailscale() {
    log "Configuring Tailscale..."
    sudo_cmd tailscale login --advertise-tags=tag:bots
    sudo_cmd tailscale set --webclient
    sudo_cmd tailscale set --advertise-routes=192.168.0.0/16,10.0.0.0/8
    sudo_cmd tailscale set --ssh
    sudo_cmd tailscale set --accept-routes
    sudo_cmd tailscale set --advertise-exit-node
    # sudo_cmd tailscale set --exit-node-allow-lan-access
}

setup_ssl() {
    local SERVICE_NAME="$1"
    local SSL_PATH="$2"
    local CERT_FILE="$SSL_PATH/$SERVICE_NAME.pem"
    local FINGERPRINT_PATH="$SSL_PATH/Fingerprints"
    local LOCAL_FINGERPRINT_FILE="$FINGERPRINT_PATH/Local.txt"

    log "Setting up $SERVICE_NAME SSL certificate..."

    # Create the SSL directory and Fingerprints directory if they don't exist
    mkdir -p "$SSL_PATH" "$FINGERPRINT_PATH"

    if ! openssl req -x509 -nodes -days 365 -subj "/CN=$SERVICE_NAME" -newkey rsa:4096 \
        -keyout "$CERT_FILE" -out "$CERT_FILE"; then
        log "Failed to generate $SERVICE_NAME SSL certificate"
        exit 1
    fi
    # Set permissions on the certificate
    chmod 600 "$CERT_FILE"

    # Create the fingerprint files if they don't exist
    for filename in Local.txt TrustedClients.txt TrustedServers.txt; do
        touch "$FINGERPRINT_PATH/$filename"
    done

    # Get the fingerprints
    sha256_fingerprint=$(openssl x509 -fingerprint -sha256 -noout -in "$CERT_FILE" | cut -d"=" -f2 | tr -d ':')
    sha1_fingerprint=$(openssl x509 -fingerprint -sha1 -noout -in "$CERT_FILE" | cut -d"=" -f2 | tr -d ':')

    # Save the fingerprints to the Local.txt file
    echo "v2:sha1:$sha1_fingerprint" > "$LOCAL_FINGERPRINT_FILE"
    echo "v2:sha256:$sha256_fingerprint" >> "$LOCAL_FINGERPRINT_FILE"
}

setup_kvm() {
    # Usage for Barrier
    setup_ssl "Barrier" "$HOME/.local/share/barrier/SSL"

    # Usage for InputLeap
    setup_ssl "InputLeap" "$HOME/.config/InputLeap/SSL"
}

generate_ssh_keys() {
    log "Generating SSH keys..."
    ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_github" -N ""
    ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_epf" -N ""
}

generate_gpg_keys() {
    log "Generating GPG keys..."
    local name email gpg_config
    name=$(whoami)
    email="${name}@$(hostname).local"
    gpg_config=$(mktemp)
    cat > "$gpg_config" <<-EOF
        %no-protection
        %echo Generating a basic OpenPGP key
        Key-Type: default
        Key-Length: 4096
        Subkey-Type: default
        Name-Real: $name
        Name-Email: $email
        Expire-Date: 0
EOF
    gpg --batch --gen-key "$gpg_config"
    trap 'rm -f "$gpg_config"' EXIT
}

setup_ntp_sync() {
    log "Setting up NTP server synchronization..."
    sudo_cmd timedatectl set-ntp true
}

install_pipx_packages() {
    log "Installing pipx packages..."
    pipx install pyqt5 cutelog
}

install_updates() {
    log "Installing pacman updates..."
    sudo_cmd pacman -Suy
}

install_nerdfonts() {
    log "Installing NerdFonts..."
    sudo_cmd "$HOME/.local/share/chezmoi/home/dot_local/bin/executable_getnf" -gi Hack
}

setup_mise() {
    log "Setting up Mise..."
    case "$ARCH" in
        "x86_64")
            sudo_cmd sh -c "curl https://mise.jdx.dev/mise-latest-linux-x64 > /usr/bin/mise"
            ;;
        "aarch64")
            sudo_cmd sh -c "curl https://mise.jdx.dev/mise-latest-linux-arm64 > /usr/bin/mise"
            ;;
    esac
    sudo_cmd chmod +x /usr/bin/mise
    eval "$(mise activate bash)"
}

install_mise_plugins() {
    log "Installing Mise plugins..."
    mise plugin add asdf-plugin-manager asdf:asdf-community/asdf-plugin-manager
    mise plugin add atuin asdf:nklmilojevic/asdf-atuin
    mise plugin add bfs asdf:virtualroot/asdf-bfs
    mise plugin add bitwarden-secrets-manager asdf:FIAV1/asdf-bitwarden-secrets-manager
    mise plugin add gitconfig asdf:0ghny/asdf-gitconfig
    mise plugin add github-cli asdf:bartlomiejdanek/asdf-github-cli
    mise plugin add jetbrains asdf:asdf-community/asdf-jetbrains
    mise plugin add lazygit asdf:nklmilojevic/asdf-lazygit
    mise plugin add php asdf:Tarik02/asdf-php
    mise plugin add pipenv asdf:and-semakin/asdf-pipenv
    mise plugin add poetry asdf:asdf-community/asdf-poetry
    mise plugin add pre-commit asdf:jonathanmorley/asdf-pre-commit
    mise plugin add sphinx asdf:amrox/asdf-pyapp
    mise plugin add starship asdf:gr1m0h/asdf-starship
    mise plugin add tmux asdf:aphecetche/asdf-tmux
    mise plugin add vars asdf:excid3/asdf-vars
    mise plugin add vim asdf:tsuyoshicho/asdf-vim
    mise plugin add youtube-dl asdf:iul1an/asdf-youtube-dl
    mise plugin add yq asdf:sudermanjr/asdf-yq
    mise plugin add yt-dlp asdf:duhow/asdf-yt-dlp
}

install_mise_programs() {
    log "Installing Mise programs..."
    mise self-update
    mise install
}

x86_64(){
    echo "x86 Addons"
}
aarch64(){
    echo "aarch64 Addons"
    echo "Setting up carapace..."
    "$HOME/.local/share/chezmoi/home/dot_local/bin/executable_ghrd" --regex -a 'carapace-bin_linux_arm64.tar.gz' carapace-sh/carapace-bin
    mkdir -p carapace
    tar -xzvf carapace-bin_linux_arm64.tar.gz -C carapace
    sudo_cmd chmod +x carapace/carapace
    sudo_cmd mv carapace/carapace /usr/bin/carapace
}

ui_settup(){
    plasma-apply-colorscheme BreezeDark

}

main() {
    log "Running initialization script for $ARCH architecture..."
    cd "$HOME" || exit 1 
    # environment_setup
    check_required_tools
    arm_swich_to_testing
    configure_pacman
    update_package_lists
    configure_pamac
    install_dev_tools
    install_additional_packages
    configure_git_credentials
    start_services
    configure_firewall
    setup_tailscale
    setup_kvm
    generate_ssh_keys
    generate_gpg_keys
    setup_ntp_sync
    install_updates
    install_nerdfonts
    setup_mise
    # install_mise_plugins
    install_mise_programs
    ui_settup
    case $ARCH in
        x86_64)
            x86_64
            install_pipx_packages
            ;;
        aarch64)
            aarch64
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            ;;
    esac
    log "Initialization script for $ARCH completed successfully."
}

main "$@"
