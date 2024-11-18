#!/bin/bash
echo "Running ARM initialization script..."

echo "Configuring pacman..."
sudo sed -Ei '/Color/s/^#//' /etc/pacman.conf
sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf

echo "Updating package lists..."
sudo pacman -Syy

echo "Configuring PAMAC..."
sudo sed -Ei '/EnableAUR/s/^#//' /etc/pamac.conf

echo "Installing dev tools"
sudo pacman -Sy yay base-devel patch tk barrier cmake 

echo "Installing anitional packages"
# arm only
yay -S git-credential-github
# end arm only
yay -S teamviewer fwupd geckodriver python-pipx tailscale yaycache-hook paccache-hook jq

echo "Starting Services..."
sudo systemctl enable --now tailscaled
sudo systemctl enable --now teamviewerd.service
sudo systemctl enable --now paccache.timer
sudo systemctl enable --now yaycache.timer
sudo systemctl enable --now systemd-timesyncd.service

echo "Setting up firewall configuration for Tailscaled"
sudo firewall-cmd --permanent --add-masquerade

echo "Setting up Tailscale login"
sudo tailscale login --advertise-tags=tag:bots

echo "Setting Tailscaled settings"
sudo tailscale set --webclient
sudo tailscale set --advertise-routes=192.168.0.0/16,10.0.0.0/8
sudo tailscale set --ssh
sudo tailscale set --accept-routes
sudo tailscale set --advertise-exit-node
sudo tailscale set --exit-node-allow-lan-access

echo "Setting up Barrier SSL certificate"

BARRIER_SSL_PATH=~/.local/share/barrier/SSL/
openssl req -x509 -nodes -days 365 -subj /CN=Barrier -newkey rsa:4096 -keyout ${BARRIER_SSL_PATH}/Barrier.pem -out ${BARRIER_SSL_PATH}/Barrier.pem

echo "Generating SSH keys..."
ssh-keygen -t rsa -b 4096  -f "${HOME}/.ssh/id_github" -N ""
ssh-keygen -t rsa -b 4096  -f "${HOME}/.ssh/id_epf" -N ""

echo "Generating GPG keys..."
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
rm -f "$gpg_config"

echo "Setting up ntp server synchronization..."
sudo timedatectl set-ntp true

echo "Installing final pipx packages..."
pipx install pyqt5 cutelog

echo "Installing pacman updates..."
sudo pacman -Suy

echo "Installing NerdFonts..."
sudo getnf -gi Hack


echo "Setting up mise..."
sudo sh -c "curl https://mise.jdx.dev/mise-latest-linux-arm64 > /usr/bin/mise"
sudo chmod +x /usr/bin/mise
eval "$(mise activate bash)"

# ARM ONLY
alias github-release="~/.local/bin/ghrd"
cd ~ || exit
echo "Setting up carapace..."
github-release --regex -a 'carapace-bin_linux_arm64.tar.gz' carapace-sh/carapace-bin
mkdir -p carapace
tar -xzvf carapace-bin_linux_arm64.tar.gz -C carapace
sudo chmod +x carapace/carapace
sudo mv carapace/carapace /usr/bin/carapace
# END ARM ONLY

echo "Installing mise plugins..."

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


echo "Installing mise programs..."
mise install

echo "ARM Installation script completed successfully."
