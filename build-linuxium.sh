#!/usr/bin/env bash
# Linuxium ISO builder: Debian 12 (bookworm) + Cinnamon, using live-build.
# Run on Debian/Ubuntu (or inside a Debian VM/container with root access).
#
# Usage:  ./build-linuxium.sh /path/to/wallpaper.png
set -euo pipefail

WALLPAPER="${1:-./wallpaper.png}"
WORK="linuxium-build"

if [ ! -f "$WALLPAPER" ]; then
  echo "Wallpaper not found: $WALLPAPER"
  echo "Usage: $0 /path/to/wallpaper.png"
  exit 1
fi
WALLPAPER="$(realpath "$WALLPAPER")"

# 1. Build tools
sudo apt-get update
sudo apt-get install -y live-build debootstrap squashfs-tools xorriso \
  isolinux syslinux-efi grub-pc-bin grub-efi-amd64-bin mtools dosfstools

# 2. Fresh working tree
sudo rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# 3. Base configuration
lb config \
  --distribution bookworm \
  --architectures amd64 \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --bootloaders "syslinux,grub-efi" \
  --debian-installer live \
  --iso-application "Linuxium" \
  --iso-publisher "Linuxium" \
  --iso-volume "LINUXIUM" \
  --image-name "linuxium" \
  --bootappend-live "boot=live components quiet splash username=linuxium hostname=linuxium locales=en_US.UTF-8 keyboard-layouts=us" \
  --memtest none

# 4. Package list
mkdir -p config/package-lists
cat > config/package-lists/linuxium.list.chroot <<'EOF'
# Desktop
cinnamon-desktop-environment
lightdm
lightdm-gtk-greeter
nemo
gnome-terminal
gnome-system-monitor
gedit
file-roller
dconf-cli

# Network / audio / hardware
network-manager
network-manager-gnome
pipewire
pipewire-pulse
wireplumber
pavucontrol
firmware-linux
firmware-misc-nonfree
firmware-iwlwifi
firmware-realtek
firmware-atheros

# Apps
firefox-esr
libreoffice-writer
libreoffice-calc
vlc
eog

# System / live
sudo
curl
wget
git
nano
fonts-noto
fonts-dejavu
live-boot
live-config
live-config-systemd
EOF

# 5. Wallpaper
WP_DIR="config/includes.chroot/usr/share/backgrounds/linuxium"
mkdir -p "$WP_DIR"
cp "$WALLPAPER" "$WP_DIR/linuxium.png"

# 6. Default settings: Cinnamon wallpaper via system-wide dconf defaults
mkdir -p config/includes.chroot/etc/dconf/profile
mkdir -p config/includes.chroot/etc/dconf/db/local.d

cat > config/includes.chroot/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF

cat > config/includes.chroot/etc/dconf/db/local.d/00-linuxium <<'EOF'
[org/cinnamon/desktop/background]
picture-uri='file:///usr/share/backgrounds/linuxium/linuxium.png'
picture-options='zoom'
primary-color='#525252'
secondary-color='#525252'
color-shading-type='solid'

[org/cinnamon/desktop/interface]
gtk-theme='Adwaita-dark'

[org/cinnamon/theme]
name='Adwaita'
EOF

# 7. Login screen background
mkdir -p config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d/50-linuxium.conf <<'EOF'
[greeter]
background=/usr/share/backgrounds/linuxium/linuxium.png
user-background=false
EOF

# 8. Live user gets autologin into Cinnamon
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/50-linuxium.conf <<'EOF'
[Seat:*]
user-session=cinnamon
EOF

# 9. Branding + dconf compile hook (runs inside the chroot at build time)
mkdir -p config/hooks/normal
cat > config/hooks/normal/0100-linuxium.hook.chroot <<'EOF'
#!/bin/sh
set -e

# Compile the dconf defaults
dconf update

# Branding (ID stays "debian" so tools keep working)
cat > /etc/os-release <<'OSR'
PRETTY_NAME="Linuxium 1.0"
NAME="Linuxium"
VERSION_ID="1.0"
VERSION="1.0 (Tux)"
VERSION_CODENAME=bookworm
ID=linuxium
ID_LIKE=debian
HOME_URL="https://example.com/linuxium"
OSR

echo "Linuxium 1.0 \n \l" > /etc/issue
echo "Linuxium 1.0" > /etc/issue.net

# Make sure LightDM is the display manager
echo /usr/sbin/lightdm > /etc/X11/default-display-manager
EOF
chmod +x config/hooks/normal/0100-linuxium.hook.chroot

# 10. Build the ISO
sudo lb build

echo
echo "Done. ISO: $(pwd)/linuxium-amd64.hybrid.iso"
echo "Test it with:  qemu-system-x86_64 -m 4096 -enable-kvm -cdrom linuxium-amd64.hybrid.iso"
