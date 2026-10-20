#!/usr/bin/env bash
# Linuxium ISO builder: Debian 12 (bookworm) + Cinnamon, using live-build.
# Run on Debian/Ubuntu (or inside a Debian VM/container with root access).
#
# Usage:  ./build-linuxium.sh [wallpaper.png] [logo.png] [grub-background.png]
#   wallpaper.png        desktop + login wallpaper          (default ./wallpaper.png)
#   logo.png             boot splash (Plymouth) + neofetch  (default ./lynx.png)
#   grub-background.png  GRUB / boot menu background        (default ./Untitled118_20261019185732.png)
set -euo pipefail

WALLPAPER="${1:-./wallpaper.png}"
LOGO="${2:-./lynx.png}"
GRUB_BG="${3:-./Untitled118_20261019185732.png}"
WORK="linuxium-build"

for f in "$WALLPAPER" "$LOGO" "$GRUB_BG"; do
  if [ ! -f "$f" ]; then
    echo "File not found: $f"
    echo "Usage: $0 [wallpaper.png] [logo.png] [grub-background.png]"
    exit 1
  fi
done
WALLPAPER="$(realpath "$WALLPAPER")"
LOGO="$(realpath "$LOGO")"
GRUB_BG="$(realpath "$GRUB_BG")"

# 1. Build tools
sudo apt-get update
sudo apt-get install -y live-build debootstrap squashfs-tools xorriso \
  isolinux syslinux-efi grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
  imagemagick

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
# Init system: without these the live image can boot to
# "No init found" because /sbin/init is missing from the squashfs
init
systemd-sysv

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

# Branding
plymouth
plymouth-themes
neofetch
chafa

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

# 5b. Logo for neofetch
mkdir -p config/includes.chroot/usr/share/linuxium
cp "$LOGO" config/includes.chroot/usr/share/linuxium/logo.png

# 5c. Boot splash (Plymouth theme using the logo)
PLY_DIR="config/includes.chroot/usr/share/plymouth/themes/linuxium"
mkdir -p "$PLY_DIR"
convert "$LOGO" -resize 256x256 "$PLY_DIR/logo.png"

cat > "$PLY_DIR/linuxium.plymouth" <<'EOF'
[Plymouth Theme]
Name=Linuxium
Description=Linuxium boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/linuxium
ScriptFile=/usr/share/plymouth/themes/linuxium/linuxium.script
EOF

# White background to match the logo image. Change the numbers (0 to 1) for another colour.
cat > "$PLY_DIR/linuxium.script" <<'EOF'
Window.SetBackgroundTopColor(1, 1, 1);
Window.SetBackgroundBottomColor(1, 1, 1);

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetX() + (Window.GetWidth() - logo.image.GetWidth()) / 2);
logo.sprite.SetY(Window.GetY() + (Window.GetHeight() - logo.image.GetHeight()) / 2);
EOF

# 5d. Boot menu backgrounds (GRUB for UEFI, syslinux for BIOS)
TMP="$(mktemp -d)"
PAD="$(convert "$GRUB_BG" -format '%[pixel:p{5,5}]' info:)"
convert "$GRUB_BG" -resize 1920x1080 -background "$PAD" -gravity center -extent 1920x1080 "$TMP/grub-bg.png"
convert "$GRUB_BG" -resize 640x480   -background "$PAD" -gravity center -extent 640x480   "$TMP/syslinux-bg.png"

mkdir -p config/bootloaders
cp -a /usr/share/live/build/bootloaders/. config/bootloaders/

echo "Bootloader images available to replace:"
find -H config/bootloaders -type f \( -name '*.png' -o -name '*.svg' \) | sed 's/^/  /'

GRUB_DONE=0
while IFS= read -r f; do
  cp "$TMP/grub-bg.png" "$f"
  GRUB_DONE=1
done < <(find -H config/bootloaders -path '*grub*' -type f \( -name 'splash.png' -o -name 'background.png' \))
[ "$GRUB_DONE" = 1 ] || echo "WARNING: no GRUB background image found to replace (check the list above)"

SYS_DONE=0
while IFS= read -r f; do
  cp "$TMP/syslinux-bg.png" "$f"
  SYS_DONE=1
done < <(find -H config/bootloaders \( -path '*isolinux*' -o -path '*syslinux*' \) -type f -name 'splash.png')
[ "$SYS_DONE" = 1 ] || echo "WARNING: no syslinux splash.png found to replace (check the list above)"

rm -rf "$TMP"

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
ID=debian
HOME_URL="https://example.com/linuxium"
OSR

printf 'Linuxium 1.0 \\n \\l\n\n' > /etc/issue
echo "Linuxium 1.0" > /etc/issue.net

# Make sure LightDM is the display manager
echo /usr/sbin/lightdm > /etc/X11/default-display-manager

# Boot splash: select the theme and rebuild the initramfs so it is included
plymouth-set-default-theme linuxium
update-initramfs -u -k all

# Neofetch: show the Linuxium logo for every new user
mkdir -p /etc/skel/.config/neofetch
if neofetch --print_config > /tmp/nf.conf 2>/dev/null && [ -s /tmp/nf.conf ]; then
  sed -i 's|^image_backend=.*|image_backend="chafa"|; s|^image_source=.*|image_source="/usr/share/linuxium/logo.png"|' /tmp/nf.conf
  mv /tmp/nf.conf /etc/skel/.config/neofetch/config.conf
else
  printf 'image_backend="chafa"\nimage_source="/usr/share/linuxium/logo.png"\n' > /etc/skel/.config/neofetch/config.conf
fi
EOF
chmod +x config/hooks/normal/0100-linuxium.hook.chroot

# 10. Build the ISO
sudo lb build

# 11. Sanity check: the ISO must contain a kernel, an initrd and the root filesystem
ISO="$(ls -1 ./*.iso | head -n1)"
LISTING="$(xorriso -indev "$ISO" -find /live -type f 2>/dev/null || true)"
for part in vmlinuz initrd.img filesystem.squashfs; do
  if ! grep -q "$part" <<<"$LISTING"; then
    echo "ERROR: $part is missing from /live in $ISO"
    exit 1
  fi
done

echo
echo "Done. ISO: $(pwd)/linuxium-amd64.hybrid.iso"
echo "Test it with:  qemu-system-x86_64 -m 4096 -enable-kvm -cdrom linuxium-amd64.hybrid.iso"
