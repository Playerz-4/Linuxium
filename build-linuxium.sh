#!/usr/bin/env bash
# Linuxium ISO builder: Debian 12 (bookworm) + Cinnamon, using live-build.
# Run on Debian/Ubuntu (or inside a Debian VM/container with root access).
#
# Usage:  ./build-linuxium.sh [wallpaper.png] [logo.png] [grub-background.png] [extra-wallpapers-dir]
#   wallpaper.png        desktop + login wallpaper          (default ./wallpaper.png)
#   logo.png             boot splash (Plymouth) + neofetch  (default ./lynx.png)
#   grub-background.png  boot-menu background               (default ./grub-bg.png)
#   extra-wallpapers-dir optional folder of your own .jpg/.png wallpapers
#                                                              (default ./wallpapers)
#
# What changed in this fixed version:
#   * Boot-menu background actually works in BOTH firmware modes. The old
#     script searched the live-build templates for files called splash.png /
#     background.png, but in Debian 12's live-build the only template image
#     is syslinux_common/splash.svg, so both searches matched NOTHING and
#     the custom image was silently never installed. BIOS/MBR boot on this
#     image is ISOLINUX, not GRUB, so this version writes the exact two
#     files the bootloaders look for, at the exact sizes they use:
#         config/bootloaders/syslinux_common/splash.png   640x480  (BIOS)
#         config/bootloaders/grub-pc/splash.png           800x600  (UEFI)
#   * UEFI Secure Boot: "--uefi-secure-boot enable" (the default "auto"
#     silently falls back to an UNSIGNED image) plus the Debian-signed
#     shim/GRUB packages inside the image, and a post-build signature check.
#   * Linuxium Experience custom installer (dark GTK app with circular
#     step buttons) + Calamares fallback + a "Welcome to Linuxium" popup.
#   * Wine 8.0 + Winetricks for Windows apps, VMware Open VM Tools +
#     vmwgfx 3D support, and a Tetris-style Plymouth boot splash where
#     falling blocks build Lynx the penguin.
#   * Extra wallpapers (New York City, mountains, beach, forest, canyon,
#     Tokyo, Nebula) downloaded from Wikimedia Commons, plus anything you
#     drop in ./wallpapers/.
#   * The scary "[drm:vmw_host_log [vmwgfx]] *ERROR* Failed to send host
#     log message" seen in VirtualBox is a harmless vmwgfx/VMSVGA quirk,
#     not your ISO failing. "loglevel=3" keeps it off the splash screen,
#     and the failsafe boot entry (which now adds "nomodeset") still shows
#     the full log when you actually need to debug something.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LINUXIUM_VERSION="1.1"
# Outer .iso.xz compression preset (0..9). Level 6 is xz's sweet spot:
# within ~1% of -9 ratio while needing ~94 MiB/thread instead of 674 MiB/thread.
LINUXIUM_XZ_LEVEL="${LINUXIUM_XZ_LEVEL:-6}"
case "$LINUXIUM_XZ_LEVEL" in
  [0-9]) ;;
  *)
    echo "ERROR: LINUXIUM_XZ_LEVEL must be a single digit 0..9 (got '$LINUXIUM_XZ_LEVEL')" >&2
    exit 1
    ;;
esac
# Resolve the script's own directory first: the default images, the extra
# wallpapers folder, the download cache and the build tree all live next
# to the script, NOT in whatever directory the caller happens to be in.
# (Previously, running /path/to/build-linuxium.sh from another directory
# died with "File not found: ./wallpaper.png" on its own shipped files.)
SCRIPT_DIR="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")"
WALLPAPER="${1:-$SCRIPT_DIR/wallpaper.png}"
LOGO="${2:-$SCRIPT_DIR/lynx.png}"
GRUB_BG="${3:-$SCRIPT_DIR/grub-bg.png}"
EXTRA_WALLPAPERS_DIR="${4:-$SCRIPT_DIR/wallpapers}"
WORK="linuxium-build"

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo); fi

usage() {
  echo "Usage: $0 [wallpaper.png] [logo.png] [grub-background.png] [extra-wallpapers-dir]"
  echo "  All arguments are optional; the defaults are the images shipped in this repository."
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
if [ "$#" -gt 4 ]; then
  echo "ERROR: too many arguments (expected at most 4)" >&2
  usage >&2
  exit 1
fi

VERIFY_DIR=""
cleanup() {
  if [ -n "${VERIFY_DIR:-}" ] && [ -d "${VERIFY_DIR}" ]; then
    rm -rf "${VERIFY_DIR}"
  fi
}
trap cleanup EXIT

for f in "$WALLPAPER" "$LOGO" "$GRUB_BG"; do
  if [ ! -f "$f" ]; then
    echo "File not found: $f"
    usage
    exit 1
  fi
done
WALLPAPER="$(realpath "$WALLPAPER")"
LOGO="$(realpath "$LOGO")"
GRUB_BG="$(realpath "$GRUB_BG")"
EXTRA_WALLPAPERS_DIR="$(realpath -m "$EXTRA_WALLPAPERS_DIR")"
# Downloaded wallpaper sources are cached OUTSIDE the build tree so that
# local rebuilds do not re-download them every time.
DOWNLOAD_CACHE="$SCRIPT_DIR/wallpapers-extra-downloads"
mkdir -p "$DOWNLOAD_CACHE"
# From here on, relative paths (the build tree, live-build's config/) are
# anchored at the script's directory. Any user-supplied paths above were
# already made absolute with realpath, so this loses nothing.
cd "$SCRIPT_DIR"

# 1. Build tools
# IMPORTANT: do not use --no-install-recommends here. In Debian 12,
# live-build only *Recommends* several tools it genuinely needs. cpio is
# one of them: installer_debian-installer calls cpio directly, and without
# it the build dies late with exit code 127 ("cpio: not found"). Install
# Recommends explicitly (even if the host's apt config disables them) and
# also name cpio so the requirement is obvious and guaranteed.
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y --install-recommends \
  live-build debootstrap cpio squashfs-tools xz-utils xorriso apt-utils \
  isolinux syslinux-common grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
  imagemagick curl ca-certificates librsvg2-bin sbsigntool

# ImageMagick 7 calls it "magick", ImageMagick 6 (Debian 12) uses "convert".
# NOTE: "identify" is a separate program in IM6, so "convert identify ..."
# does NOT work there; keep a dedicated array for it instead of guessing.
if command -v magick >/dev/null 2>&1; then
  IM=(magick)
  IM_IDENTIFY=(magick identify)
else
  IM=(convert)
  IM_IDENTIFY=(identify)
fi

# 2. Fresh working tree
"${SUDO[@]}" rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# 3. Base configuration
#    --bootloaders "syslinux,grub-efi": BIOS/MBR = ISOLINUX (this is also the
#    only combination for which Debian 12's live-build adds an isohybrid MBR,
#    so a USB stick written with dd/Rufus-dd still boots on BIOS machines),
#    UEFI = GRUB. The same artwork is installed for both (see section 5d).
#    --uefi-secure-boot enable: fail the build instead of silently shipping
#    an unsigned image if the signed shim/GRUB cannot be found.
#    --debian-installer live: keeps the classic installer as an "advanced"
#    option AND makes live-build put grub-pc, grub-efi-amd64,
#    grub-efi-amd64-signed, shim-signed, cryptsetup, ... into /pool on the
#    ISO. Calamares (Debian's sources-media helper) installs the bootloader
#    from that pool, so installing to disk works fully OFFLINE on both BIOS
#    and UEFI/Secure Boot machines. Do not remove this unless you also
#    rework how Calamares gets its bootloader packages.
#    The failsafe line deliberately avoids live-build's ancient stock
#    failsafe words: bare "memtest" starts the kernel's boot-time RAM
#    tester (Bookworm has CONFIG_MEMTEST=y), while noapic/nolapic/nosmp
#    can make modern hardware harder, not easier, to boot. Safe graphics
#    (nomodeset + Cinnamon software rendering) is the job of this entry.
lb config \
  --distribution bookworm \
  --architectures amd64 \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --chroot-squashfs-compression-type xz \
  --bootloaders "syslinux,grub-efi" \
  --uefi-secure-boot enable \
  --debian-installer live \
  --iso-application "Linuxium ${LINUXIUM_VERSION}" \
  --iso-publisher "Linuxium" \
  --iso-volume "LINUXIUM" \
  --image-name "linuxium" \
  --bootappend-live "boot=live components quiet splash loglevel=3 username=linuxium hostname=linuxium locales=en_US.UTF-8 keyboard-layouts=us" \
  --bootappend-live-failsafe "boot=live components nosplash nomodeset username=linuxium hostname=linuxium locales=en_US.UTF-8 keyboard-layouts=us linuxium-session=cinnamon2d" \
  --memtest none

# 3b. Image compression & rootfs exclusions
#     * Compress initramfs with XZ instead of Bookworm's default zstd (~50%
#       smaller /live/initrd.img and /boot/initrd.img). Note: initramfs-tools
#       sources /etc/initramfs-tools/conf.d/* with run-parts naming rules, so
#       the filename must NOT contain a dot.
#     * Exclude transient APT package indexes, build caches, backup state and
#       logs from filesystem.squashfs via live-build's config/rootfs/excludes
#       (keeping them in chroot/ during the build so binary_grub-efi and
#       binary_package-lists can still query APT cleanly).
mkdir -p config/includes.chroot/etc/initramfs-tools/conf.d config/includes.chroot/etc/initramfs-tools config/rootfs
cat > config/includes.chroot/etc/initramfs-tools/conf.d/linuxium-compress <<'EOF'
COMPRESS=xz
EOF
# VMware guest drivers in the initramfs so the live ISO and installed
# systems boot on VMware SVGA (vmwgfx) with 3D acceleration and VMCI
# transport available before / is mounted. These modules ship with the
# Debian kernel; listing them here only bakes them into the initramfs.
cat > config/includes.chroot/etc/initramfs-tools/modules <<'EOF'
vmwgfx
vmw_balloon
vmw_vmci
vmw_vsock_vmci_transport
EOF
cat > config/rootfs/excludes <<'EOF'
boot/*.old
tmp/*
var/tmp/*
var/cache/apt/archives/*.deb
var/cache/apt/archives/lock
var/cache/apt/pkgcache.bin
var/cache/apt/srcpkgcache.bin
var/cache/debconf/*-old
var/lib/apt/lists/*_*
var/lib/apt/lists/auxfiles/*
var/lib/apt/lists/lock
var/lib/dpkg/*-old
var/log/*.log
var/log/apt/*
EOF

# 4. Package list
mkdir -p config/package-lists
cat > config/package-lists/linuxium.list.chroot <<'EOF'
# Init system: without these the live image can boot to
# "No init found" because /sbin/init is missing from the squashfs.
# Name the decisive pieces explicitly instead of trusting another
# package's Depends/Recommends to keep bringing them along forever,
# including PAM/logind session registration (uaccess ACLs on /dev/dri/*
# and XDG_RUNTIME_DIR), session D-Bus, and Polkit.
init
systemd
systemd-sysv
libpam-systemd
udev
dbus
dbus-user-session
dbus-x11
polkitd
pkexec
kmod
procps
psmisc
pciutils
initramfs-tools

# Graphics: X server plus video/input drivers and Mesa runtime. Name the
# critical VM and failsafe framebuffer drivers explicitly alongside
# xserver-xorg-video-all so VMSVGA/VMware, QXL/SPICE, UEFI efifb and
# BIOS VESA can never go missing.
xorg
xserver-xorg-video-all
xserver-xorg-video-vmware
xserver-xorg-video-qxl
xserver-xorg-video-fbdev
xserver-xorg-video-vesa
xserver-xorg-input-all
libgl1-mesa-dri
libegl-mesa0
libgbm1
mesa-vulkan-drivers

# Desktop (cinnamon-core instead of cinnamon-desktop-environment: keeps the
# full Cinnamon desktop + Nemo + control center + screensaver while skipping
# ~1 GB of unrequested metapackage bloat such as Thunderbird, HexChat,
# Sound Juicer, Totem, and all-weight Noto font bundles).
cinnamon-core
lightdm
lightdm-gtk-greeter
papirus-icon-theme
librsvg2-common
dmz-cursor-theme
nemo
nemo-fileroller
gvfs-backends
gvfs-fuse
xdg-user-dirs
xdg-user-dirs-gtk
blueman
system-config-printer
sound-theme-freedesktop
libreoffice-gtk3
gnome-terminal
gnome-system-monitor
gedit
file-roller
dconf-cli

# Network / audio / hardware
network-manager
network-manager-gnome
# Use Debian's complete PipeWire audio bundle (ALSA + PulseAudio
# compatibility, WirePlumber and Bluetooth audio), and explicitly keep
# the legacy PulseAudio daemon out. Cinnamon's Recommends otherwise pull
# it in through Blueman; its user socket conflicts with PipeWire-Pulse
# on the same runtime path and can win, leaving only a dummy output.
pipewire-audio
pulseaudio-
pavucontrol
firmware-linux
firmware-misc-nonfree
firmware-iwlwifi
firmware-realtek
firmware-atheros
# Common hardware that otherwise appears "dead" on first boot: Broadcom
# Wi-Fi, Intel/SOF audio DSP firmware, and early CPU microcode updates.
firmware-brcm80211
firmware-intel-sound
firmware-sof-signed
intel-microcode
amd64-microcode

# Apps
firefox-esr
gimp
inkscape
libreoffice-writer
libreoffice-calc
libreoffice-impress
evince
vlc
rhythmbox
eog
flameshot
gnome-screenshot
cheese
gnome-calculator
gnome-disk-utility
baobab
transmission-gtk
synaptic
gdebi
htop

# Windows app support: Wine 8.0 (Bookworm) + Winetricks.
# wine/wine64/libwine/fonts-wine/wine-binfmt are all in Bookworm main;
# winetricks is in contrib (enabled via --archive-areas). wine-binfmt
# registers .exe/.msi handling so double-clicking a Windows installer
# opens Wine. cabextract/p7zip-full/unzip are Winetricks helpers for
# extracting VC++ runtimes, fonts and DLLs into a Wine prefix.
# NOTE: 32-bit Windows apps need the i386 architecture
# (dpkg --add-architecture i386 && apt install wine32 libwine:i386);
# the live image ships 64-bit Wine out of the box so the ISO stays
# amd64-only. See /usr/share/doc/linuxium/README.md.
wine
wine64
libwine
fonts-wine
wine-binfmt
winetricks
cabextract
p7zip-full
unzip

# Graphical installer: Calamares + Debian's tested live configuration
# (offline pool handling, EFI bootloader helpers, "install-debian" launcher).
# Linuxium branding for it is added in section 5f / the hook in section 9.
# Calamares stays installed as a fallback backend; the primary installer
# is the custom "Linuxium Experience" (section 5h) which does its own
# partitioning/copy/GRUB install and only falls back to Calamares if
# the user explicitly asks for advanced partitioning.
calamares
calamares-settings-debian

# Tools Calamares, Linuxium Experience and disk work need in the live session
squashfs-tools
rsync
efibootmgr
dosfstools
parted
btrfs-progs
xfsprogs
lvm2
cryptsetup
# Encrypted Calamares installs need the initramfs cryptroot hooks in the
# copied target system; do not make that depend on the ISO package pool
# (or on having a network connection) at install time.
cryptsetup-initramfs
keyutils
gparted
os-prober

# Secure Boot chain inside the installed system: Microsoft-signed shim ->
# Debian-signed GRUB -> Debian-signed kernel. The *-bin packages let
# grub-install work for both BIOS and UEFI; grub-pc / grub-efi-amd64
# themselves are installed onto the target disk by Calamares from the
# ISO's /pool (they conflict with each other, so they cannot both live
# in the live system). Linuxium Experience uses the same *-bin packages
# from the live system directly (grub-install --target=...), so it also
# works fully offline without the /pool.
grub-common
grub2-common
grub-pc-bin
grub-efi-amd64-bin
grub-efi-amd64-signed
shim-signed
mokutil

# Linuxium Welcome + Linuxium Experience installer (Python + GTK 3)
python3-gi
gir1.2-gtk-3.0
xdg-utils

# Guest integration for QEMU/KVM, SPICE viewers and VMware hosts.
# open-vm-tools units use ConditionVirtualization=vmware so they stay
# completely inert on bare metal, VirtualBox and QEMU/KVM.
# VMware: open-vm-tools (vmtoolsd daemon, time sync, shared folders,
# power ops) + open-vm-tools-desktop (clipboard, drag-and-drop, display
# resize for graphical guests) + xserver-xorg-video-vmware (legacy
# SVGA) + vmwgfx KMS (modern SVGA 3D via Mesa). libdrm/libgbm1 are
# named explicitly so vmwgfx never goes missing. The vmwgfx kernel
# modules are also baked into the initramfs via
# /etc/initramfs-tools/modules (section 3b).
qemu-guest-agent
spice-vdagent
open-vm-tools
open-vm-tools-desktop
libdrm
libgbm1

# Branding
plymouth
plymouth-x11
plymouth-themes
plymouth-label
neofetch
chafa
# Neofetch's chafa backend still needs ImageMagick's convert/identify
# before it will even try to draw an image; xdotool/x11-utils let it find
# the pixel size of a VTE terminal (GNOME Terminal). Without them it
# silently falls back to the generic Tux ASCII art.
imagemagick
xdotool
x11-utils

# System / live
sudo
curl
wget
git
nano
xz-utils
fonts-liberation
fonts-noto-core
fonts-noto-ui-core
fonts-noto-mono
fonts-noto-color-emoji
fonts-noto-extra-
fonts-noto-ui-extra-
fonts-noto-cjk-extra-
fonts-dejavu-core
live-boot
live-config
live-config-systemd
# Critical live-config helpers. live-config only *Recommends* several of
# these, but 0030-user-setup silently skips creating the live user if
# user-setup is absent, locales are needed by 0050-locales, and
# console-setup provides setupcon/ckbcomp for console + installer use.
user-setup
locales
kbd
console-setup
keyboard-configuration
iproute2
live-tools
EOF

# 5. Wallpapers
WP_DIR="config/includes.chroot/usr/share/backgrounds/linuxium"
mkdir -p "$WP_DIR"
# Normalize (do not just rename) the main wallpaper: GRUB, LightDM and
# Cinnamon all read this file, and an input that merely *ends* in .png
# while really being a 16-bit/interlaced/other-format image can make
# one of those early graphical stages fail or fall back badly.
"${IM[@]}" "$WALLPAPER" -auto-orient -background '#525252' -alpha remove \
  -alpha off -resize '1920x1080>' -strip "PNG24:$WP_DIR/linuxium.png"

WP_NAMES=("Linuxium")
WP_FILES=("linuxium.png")
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# 5a. Extra wallpapers from Wikimedia Commons (freely licensed; credits are
#     shipped in /usr/share/doc/linuxium-wallpapers/CREDITS.txt).
#     Format: output-file|display name|download URL|credit line
DOC_DIR="config/includes.chroot/usr/share/doc/linuxium-wallpapers"
mkdir -p "$DOC_DIR"
cat > "$DOC_DIR/CREDITS.txt" <<'EOF'
Linuxium extra wallpapers
=========================

These photographs come from Wikimedia Commons. They were resized/cropped
to 1920x1080 by the Linuxium build script; apart from that they are
unmodified. Please keep this file with the images.

EOF

WIKI_WALLPAPERS=(
  "new-york-city.jpg|New York City at dusk|https://commons.wikimedia.org/wiki/Special:FilePath/Lower_Manhattan_from_Brooklyn_May_2015_panorama.jpg?width=3840|New York City: \"Lower Manhattan from Brooklyn May 2015 panorama\" by King of Hearts, CC BY-SA 3.0, https://commons.wikimedia.org/wiki/File:Lower_Manhattan_from_Brooklyn_May_2015_panorama.jpg"
  "mountain-lake.jpg|Mountain lake|https://commons.wikimedia.org/wiki/Special:FilePath/1_moraine_lake_pano_2019.jpg?width=2560|Mountain lake (Moraine Lake): \"1 moraine lake pano 2019\" by Chensiyuan, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:1_moraine_lake_pano_2019.jpg"
  "tropical-beach.jpg|Tropical beach|https://commons.wikimedia.org/wiki/Special:FilePath/USVI_IMG_5166_-_Tropical_foliage_frames_a_serene_beach_and_turquoise_water_with_palm_trees_swaying_gently_in_the_breeze.jpg?width=2560|Tropical beach: Government of the United States Virgin Islands, public domain, https://commons.wikimedia.org/wiki/File:USVI_IMG_5166_-_Tropical_foliage_frames_a_serene_beach_and_turquoise_water_with_palm_trees_swaying_gently_in_the_breeze.jpg"
  "forest.jpg|Forest light|https://commons.wikimedia.org/wiki/Special:FilePath/D%C3%BClmen%2C_Rorup%2C_NSG_Roruper_Holz_--_2021_--_8187-91_%28cinematic%29.jpg?width=2560|Forest light: \"Duelmen, Rorup, NSG Roruper Holz -- 2021 -- 8187-91 (cinematic)\" by Dietmar Rabich, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:D%C3%BClmen,_Rorup,_NSG_Roruper_Holz_--_2021_--_8187-91_(cinematic).jpg"
  "monument-valley.jpg|Monument Valley|https://commons.wikimedia.org/wiki/Special:FilePath/Monument_Valley%2C_Utah%2C_USA_%2823611451292%29.jpg?width=2560|Monument Valley: \"Monument Valley, Utah, USA\" by Domenico Convertini, CC BY-SA 2.0, https://commons.wikimedia.org/wiki/File:Monument_Valley,_Utah,_USA_(23611451292).jpg"
  "tokyo-sunset.jpg|Tokyo at sunset|https://commons.wikimedia.org/wiki/Special:FilePath/Tokyo_-_Sunset_Skyline.jpg?width=2560|Tokyo at sunset: \"Tokyo - Sunset Skyline\" by Fred Cherrygarden, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:Tokyo_-_Sunset_Skyline.jpg"
  "cats-eye-nebula.jpg|Cat's Eye Nebula|https://commons.wikimedia.org/wiki/Special:FilePath/Euclid_and_Hubble%27s_view_of_Cat%27s_Eye_Nebula_%28potm2602c%29.jpg?width=2560|Cat's Eye Nebula: ESA/Hubble and NASA, ESA Euclid/Euclid Consortium/NASA, CC BY 4.0, https://commons.wikimedia.org/wiki/File:Euclid_and_Hubble%27s_view_of_Cat%27s_Eye_Nebula_(potm2602c).jpg"
)

for entry in "${WIKI_WALLPAPERS[@]}"; do
  IFS='|' read -r wp_out wp_name wp_url wp_credit <<<"$entry"
  wp_cache="$DOWNLOAD_CACHE/${wp_out%.jpg}-source.jpg"
  if [ ! -s "$wp_cache" ]; then
    echo "Downloading wallpaper: $wp_name"
    if ! curl -fL --retry 3 --connect-timeout 20 \
         -A "Linuxium/${LINUXIUM_VERSION} build script (wallpaper download)" \
         -o "$wp_cache.part" "$wp_url"; then
      echo "WARNING: could not download $wp_url - skipping this wallpaper" >&2
      rm -f "$wp_cache.part"
      continue
    fi
    mv "$wp_cache.part" "$wp_cache"
  fi
  # Validate the cached file before trusting it. A download that "succeeded"
  # at the HTTP level can still be an error page or a truncated file, and an
  # unvalidated bad cache entry would otherwise poison every later rebuild:
  # it exists and is non-empty, so it would never be re-downloaded, yet it
  # would fail conversion (and be silently skipped) forever.
  if ! "${IM_IDENTIFY[@]}" "$wp_cache" >/dev/null 2>&1; then
    echo "WARNING: $wp_cache is not a readable image - deleting it so the next build re-downloads it" >&2
    rm -f "$wp_cache"
    continue
  fi
  if "${IM[@]}" "$wp_cache" -auto-orient -resize '1920x1080^' -gravity center \
       -extent 1920x1080 -strip -quality 88 "$WP_DIR/$wp_out"; then
    WP_NAMES+=("$wp_name")
    WP_FILES+=("$wp_out")
    printf '%s\n' "$wp_credit" >> "$DOC_DIR/CREDITS.txt"
  else
    echo "WARNING: could not convert $wp_cache - deleting the cached copy and skipping this wallpaper" >&2
    rm -f "$wp_cache"
  fi
done

# 5b. Your own extra wallpapers: anything in ./wallpapers/ (or $4).
if [ -d "$EXTRA_WALLPAPERS_DIR" ]; then
  shopt -s nullglob
  EXTRA_SRC=("$EXTRA_WALLPAPERS_DIR"/*.jpg "$EXTRA_WALLPAPERS_DIR"/*.jpeg
             "$EXTRA_WALLPAPERS_DIR"/*.png "$EXTRA_WALLPAPERS_DIR"/*.webp
             "$EXTRA_WALLPAPERS_DIR"/*.JPG "$EXTRA_WALLPAPERS_DIR"/*.JPEG
             "$EXTRA_WALLPAPERS_DIR"/*.PNG "$EXTRA_WALLPAPERS_DIR"/*.WEBP)
  shopt -u nullglob
  for src in "${EXTRA_SRC[@]}"; do
    base="$(basename "$src")"
    stem="${base%.*}"
    slug="$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]' | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//')"
    [ -n "$slug" ] || slug="wallpaper"
    out="custom-$slug.jpg"
    n=2
    while [ -e "$WP_DIR/$out" ]; do out="custom-$slug-$n.jpg"; n=$((n + 1)); done
    pretty="$(printf '%s' "$stem" | tr '_-' '  ')"
    if "${IM[@]}" "$src" -auto-orient -resize '1920x1080^' -gravity center \
         -extent 1920x1080 -strip -quality 88 "$WP_DIR/$out"; then
      WP_NAMES+=("$pretty")
      WP_FILES+=("$out")
    else
      echo "WARNING: could not convert $src - skipping" >&2
    fi
  done
fi

# 5c. Wallpaper picker entries (Cinnamon reads the cinnamon- and
#     gnome-background-properties directories; install both as linuxium.xml
#     so cs_backgrounds.py names the sidebar category "Linuxium", and
#     section 9 consolidates all package-provided wallpapers into this one
#     category so individual GNOME wallpapers do not each create their own
#     1-wallpaper category).
for props in cinnamon-background-properties gnome-background-properties; do
  mkdir -p "config/includes.chroot/usr/share/$props"
  rm -f "config/includes.chroot/usr/share/$props/linuxium-wallpapers.xml"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">'
    printf '%s\n' '<wallpapers>'
    for i in "${!WP_FILES[@]}"; do
      printf '  <wallpaper deleted="false">\n'
      printf '    <name>%s</name>\n' "$(xml_escape "${WP_NAMES[$i]}")"
      printf '    <filename>/usr/share/backgrounds/linuxium/%s</filename>\n' "$(xml_escape "${WP_FILES[$i]}")"
      printf '    <options>zoom</options>\n    <pcolor>#525252</pcolor>\n    <scolor>#525252</scolor>\n    <shade_type>solid</shade_type>\n'
      printf '  </wallpaper>\n'
    done
    printf '%s\n' '</wallpapers>'
  } > "config/includes.chroot/usr/share/$props/linuxium.xml"
done
echo "Wallpapers in this build: ${WP_FILES[*]}"

# 5d. Logo for neofetch, pixmaps, hicolor icon theme and taskbar menu button
# Preserve RGBA transparency (PNG32 with -background none) so Neofetch's
# chafa backend renders the Lynx directly over the terminal background
# without an opaque white square. If a custom source logo has an opaque
# pure-white outer background, floodfill only the outer corners to
# transparent so interior white details (eye/belly) stay intact.
mkdir -p config/includes.chroot/usr/share/linuxium config/includes.chroot/usr/share/pixmaps
LOGO_CORNER="$("${IM[@]}" "$LOGO" -auto-orient -format '%[fx:p{0,0}.a>0.95 && p{0,0}.r>0.96 && p{0,0}.g>0.96 && p{0,0}.b>0.96 ? 1 : 0]' info: 2>/dev/null || echo 0)"
if [ "$LOGO_CORNER" = "1" ]; then
  LOGO_DIMS="$("${IM[@]}" "$LOGO" -auto-orient -format '%wx%h' info:)"
  LOGO_MAX_X=$(( ${LOGO_DIMS%x*} - 1 ))
  LOGO_MAX_Y=$(( ${LOGO_DIMS#*x} - 1 ))
  "${IM[@]}" "$LOGO" -auto-orient -alpha set -fuzz 6% -fill none \
    -draw "matte 0,0 floodfill" \
    -draw "matte ${LOGO_MAX_X},0 floodfill" \
    -draw "matte 0,${LOGO_MAX_Y} floodfill" \
    -draw "matte ${LOGO_MAX_X},${LOGO_MAX_Y} floodfill" \
    -trim +repage -background none -gravity center \
    -resize 460x460 -extent 512x512 -strip \
    "PNG32:config/includes.chroot/usr/share/linuxium/logo.png"
else
  "${IM[@]}" "$LOGO" -auto-orient -alpha set \
    -trim +repage -background none -gravity center \
    -resize 460x460 -extent 512x512 -strip \
    "PNG32:config/includes.chroot/usr/share/linuxium/logo.png"
fi
"${IM[@]}" "config/includes.chroot/usr/share/linuxium/logo.png" \
  -background none -resize 512x512 -strip \
  "PNG32:config/includes.chroot/usr/share/pixmaps/linuxium.png"
# Trim outer transparent whitespace so the lynx fills the Cinnamon panel
# start-menu button cleanly at 24-32 px instead of shrinking into padding.
"${IM[@]}" "config/includes.chroot/usr/share/linuxium/logo.png" \
  -trim +repage -background none \
  -gravity center -resize 116x116 -extent 128x128 -strip \
  "PNG32:config/includes.chroot/usr/share/linuxium/panel-icon.png"
for icon_px in 16 24 32 48 64 128 256; do
  icon_dir="config/includes.chroot/usr/share/icons/hicolor/${icon_px}x${icon_px}/apps"
  mkdir -p "$icon_dir"
  "${IM[@]}" "config/includes.chroot/usr/share/linuxium/panel-icon.png" \
    -background none -resize "${icon_px}x${icon_px}" -strip \
    "PNG32:${icon_dir}/linuxium.png"
done

# 5e. Boot splash: Tetris-style Plymouth theme where falling blocks build
#     Lynx the penguin. Dark background (#0f1219) with a 10x16 Tetris well;
#     coloured blocks drop from the top, stack up, and once enough blocks
#     have landed the Lynx logo + "Linuxium" title fade in above the stack
#     with a gentle bob. The password/message callbacks are not decoration:
#     a Plymouth script theme without them gives an encrypted installed
#     system no visible unlock prompt, which looks exactly like a boot hang.
PLY_DIR="config/includes.chroot/usr/share/plymouth/themes/linuxium"
mkdir -p "$PLY_DIR"
# Lynx logo sized for the Tetris theme (dark background so it blends).
"${IM[@]}" "$LOGO" -auto-orient -background '#0f1219' -alpha remove -alpha off \
  -resize 128x128 -strip "PNG24:$PLY_DIR/logo.png"
# Tetris block images (22x22, classic Tetris colours, dark border).
for _block_idx in 0 1 2 3 4 5 6; do
  case "$_block_idx" in
    0) _block_color='#00f0f0' ;;
    1) _block_color='#f0f000' ;;
    2) _block_color='#a000f0' ;;
    3) _block_color='#00f000' ;;
    4) _block_color='#f00000' ;;
    5) _block_color='#3b82f6' ;;
    6) _block_color='#f0a000' ;;
  esac
  "${IM[@]}" -size 22x22 "xc:${_block_color}" -stroke '#0f1219' -strokewidth 2 \
    -draw "rectangle 1,1 20,20" -strip "PNG24:$PLY_DIR/block-${_block_idx}.png"
done
# Tetris well background (228x360: 10x16 grid of 22px cells + 4px border).
"${IM[@]}" -size 228x360 xc:'#1a1e28' -stroke '#3b82f6' -strokewidth 2 \
  -draw "rectangle 1,1 226,358" -strip "PNG24:$PLY_DIR/well.png"
# Kept for compatibility with older sanity checks (unused by Tetris theme).
"${IM[@]}" -size 192x4 xc:'#2a3040' -strip "PNG24:$PLY_DIR/progress-track.png"
"${IM[@]}" -size 56x4 xc:'#3b82f6' -strip "PNG24:$PLY_DIR/progress-bar.png"

cat > "$PLY_DIR/linuxium.plymouth" <<'EOF'
[Plymouth Theme]
Name=Linuxium
Description=Linuxium Tetris boot splash - blocks build Lynx
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/linuxium
ScriptFile=/usr/share/plymouth/themes/linuxium/linuxium.script
EOF

cat > "$PLY_DIR/linuxium.script" <<'EOF'
Window.SetBackgroundTopColor(0.06, 0.07, 0.10);
Window.SetBackgroundBottomColor(0.06, 0.07, 0.10);

block_size = 22;
well_cols = 10;
well_rows = 16;
well_w = block_size * well_cols;
well_h = block_size * well_rows;
well_x = Window.GetX() + (Window.GetWidth() - well_w) / 2;
well_y = Window.GetY() + (Window.GetHeight() - well_h) / 2 + 24;

well.image = Image("well.png");
well.sprite = Sprite(well.image);
well.sprite.SetPosition(well_x - 4, well_y - 4, 90);

for (c = 0; c < 7; c++)
	block_images[c] = Image("block-" + c + ".png");

max_blocks = 40;
for (i = 0; i < max_blocks; i++)
{
	block_sprites[i] = Sprite();
	block_sprites[i].SetOpacity(0);
	block_col[i] = 0;
	block_row[i] = 0;
	block_falling[i] = 0;
	block_landed[i] = 0;
	block_color[i] = 0;
}

for (c = 0; c < well_cols; c++)
	stack[c] = 0;

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetOpacity(0);
logo.x = Window.GetX() + (Window.GetWidth() - logo.image.GetWidth()) / 2;
logo.y = well_y - logo.image.GetHeight() - 18;
logo.sprite.SetPosition(logo.x, logo.y, 110);

title.image = Image.Text("Linuxium", 1, 1, 1);
title.sprite = Sprite(title.image);
title.sprite.SetOpacity(0);
title.x = Window.GetX() + (Window.GetWidth() - title.image.GetWidth()) / 2;
title.y = well_y + well_h + 18;
title.sprite.SetPosition(title.x, title.y, 110);

dialog_active = 0;
tick = 0;
spawn_timer = 0;
fall_timer = 0;
landed_count = 0;
lynx_built = 0;
logo_opacity = 0;

prompt_sprite = Sprite();
prompt_sprite.SetPosition(0, 0, 10000);
prompt_sprite.SetOpacity(0);

entry_sprite = Sprite();
entry_sprite.SetPosition(0, 0, 10001);
entry_sprite.SetOpacity(0);

message_sprite = Sprite();
message_sprite.SetPosition(0, 0, 10002);
message_sprite.SetOpacity(0);

fun refresh_callback()
{
	tick++;
	if (dialog_active == 0)
	{
		if (lynx_built == 0)
		{
			spawn_timer++;
			if (spawn_timer > 16)
			{
				spawn_timer = 0;
				spawned = 0;
				for (i = 0; i < max_blocks; i++)
				{
					if (spawned == 0 && block_landed[i] == 0 && block_falling[i] == 0)
					{
						block_col[i] = Math.Int(tick * 7 + i * 3) % well_cols;
						block_row[i] = 0;
						block_color[i] = Math.Int(tick + i) % 7;
						block_falling[i] = 1;
						block_sprites[i].SetImage(block_images[block_color[i]]);
						block_sprites[i].SetOpacity(1);
						spawned = 1;
					}
				}
			}
			fall_timer++;
			if (fall_timer > 4)
			{
				fall_timer = 0;
				for (i = 0; i < max_blocks; i++)
				{
					if (block_falling[i] == 1)
					{
						block_row[i]++;
						col = block_col[i];
						if (block_row[i] >= well_rows - stack[col])
						{
							block_row[i] = well_rows - stack[col] - 1;
							block_falling[i] = 0;
							block_landed[i] = 1;
							stack[col]++;
							landed_count++;
						}
						bx = well_x + block_col[i] * block_size;
						by = well_y + block_row[i] * block_size;
						block_sprites[i].SetPosition(bx, by, 100);
					}
				}
			}
			for (i = 0; i < max_blocks; i++)
			{
				if (block_falling[i] == 1)
				{
					bx = well_x + block_col[i] * block_size;
					by = well_y + block_row[i] * block_size;
					block_sprites[i].SetPosition(bx, by, 100);
				}
			}
			if (landed_count >= 28)
				lynx_built = 1;
		}
		else
		{
			if (logo_opacity < 1)
			{
				logo_opacity += 0.02;
				if (logo_opacity > 1)
					logo_opacity = 1;
				logo.sprite.SetOpacity(logo_opacity);
				title.sprite.SetOpacity(logo_opacity);
			}
			bob = Math.Sin(tick / 20.0) * 4;
			logo.sprite.SetY(logo.y + bob);
		}
	}
	else
	{
		for (i = 0; i < max_blocks; i++)
			block_sprites[i].SetOpacity(0);
		well.sprite.SetOpacity(0);
		logo.sprite.SetOpacity(0);
		title.sprite.SetOpacity(0);
	}
}

fun hide_dialog()
{
	dialog_active = 0;
	prompt_sprite.SetOpacity(0);
	entry_sprite.SetOpacity(0);
}

fun display_normal_callback()
{
	hide_dialog();
}

fun display_password_callback(prompt_text, bullets)
{
	dialog_active = 1;
	if (!prompt_text || prompt_text == "")
		prompt_text = "Password:";
	prompt_image = Image.Text(prompt_text, 1, 1, 1);
	if (prompt_image)
	{
		prompt_x = Math.Max(Window.GetX(),
			Window.GetX() + (Window.GetWidth() - prompt_image.GetWidth()) / 2);
		prompt_y = well_y + well_h + 18;
		prompt_sprite.SetImage(prompt_image);
		prompt_sprite.SetPosition(prompt_x, prompt_y, 10000);
		prompt_sprite.SetOpacity(1);
		entry_y = prompt_y + prompt_image.GetHeight() + 8;
	}
	else
	{
		entry_y = well_y + well_h + 42;
	}

	bullet_text = "";
	for (bullet_index = 0; bullet_index < bullets; bullet_index++)
		bullet_text += "*";

	if (bullets > 0)
	{
		entry_image = Image.Text(bullet_text, 1, 1, 1);
		if (entry_image)
		{
			entry_x = Math.Max(Window.GetX(),
				Window.GetX() + (Window.GetWidth() - entry_image.GetWidth()) / 2);
			entry_sprite.SetImage(entry_image);
			entry_sprite.SetPosition(entry_x, entry_y, 10001);
			entry_sprite.SetOpacity(1);
		}
	}
	else
	{
		entry_sprite.SetOpacity(0);
	}
}

fun display_question_callback(prompt_text, entry_text)
{
	dialog_active = 1;
	if (!prompt_text || prompt_text == "")
		prompt_text = "Input:";
	if (!entry_text)
		entry_text = "";
	question_image = Image.Text(prompt_text + " " + entry_text, 1, 1, 1);
	if (question_image)
	{
		question_x = Math.Max(Window.GetX(),
			Window.GetX() + (Window.GetWidth() - question_image.GetWidth()) / 2);
		question_y = well_y + well_h + 18;
		prompt_sprite.SetImage(question_image);
		prompt_sprite.SetPosition(question_x, question_y, 10000);
		prompt_sprite.SetOpacity(1);
	}
	entry_sprite.SetOpacity(0);
}

fun display_message_callback(message_text)
{
	if (!message_text || message_text == "")
	{
		message_sprite.SetOpacity(0);
		return;
	}
	message_image = Image.Text(message_text, 1, 1, 1);
	if (message_image)
	{
		message_x = Math.Max(Window.GetX(),
			Window.GetX() + (Window.GetWidth() - message_image.GetWidth()) / 2);
		message_y = Window.GetY() + Window.GetHeight() * 0.85;
		message_sprite.SetImage(message_image);
		message_sprite.SetPosition(message_x, message_y, 10002);
		message_sprite.SetOpacity(1);
	}
}

fun hide_message_callback(message_text)
{
	message_sprite.SetOpacity(0);
}

Plymouth.SetRefreshFunction(refresh_callback);
Plymouth.SetDisplayNormalFunction(display_normal_callback);
Plymouth.SetDisplayPasswordFunction(display_password_callback);
Plymouth.SetDisplayQuestionFunction(display_question_callback);
Plymouth.SetDisplayMessageFunction(display_message_callback);
Plymouth.SetHideMessageFunction(hide_message_callback);
EOF

# 5f. Boot-menu backgrounds -- THE fix for "no custom image in MBR mode".
#
# How Debian 12 live-build really works (verified against live-build
# 1:20230502):
#   * BIOS/MBR boot uses ISOLINUX. Its file stdmenu.cfg says
#     "menu background splash.png" -> /isolinux/splash.png on the ISO,
#     which must be 640x480. User files in config/bootloaders/
#     syslinux_common/ are copied into the isolinux directory.
#   * UEFI boot uses GRUB. config/bootloaders/grub-pc/ files are copied to
#     /boot/grub/, its theme (live-theme/theme.txt) loads "../splash.png",
#     and GRUB's gfxmode is fixed at 800x600 by the stock config.cfg.
#   * The stock templates only ship a splash.svg. binary_syslinux converts
#     it ONLY if no splash.png already exists, so providing our own
#     splash.png wins in both places. No template tree is copied any more.
# PNG24 (8-bit RGB, no alpha, non-interlaced) is what both the syslinux
# vesamenu and GRUB's png module reliably accept.
PAD="$("${IM[@]}" "$GRUB_BG" -background white -alpha remove -alpha off -format '%[pixel:p{5,5}]' info: 2>/dev/null || echo black)"
mkdir -p config/bootloaders/grub-pc config/bootloaders/syslinux_common
"${IM[@]}" "$GRUB_BG" -auto-orient -background "$PAD" -flatten \
  -resize 800x600 -gravity center -extent 800x600 -strip \
  "PNG24:config/bootloaders/grub-pc/splash.png"
"${IM[@]}" "$GRUB_BG" -auto-orient -background "$PAD" -flatten \
  -resize 640x480 -gravity center -extent 640x480 -strip \
  "PNG24:config/bootloaders/syslinux_common/splash.png"
echo "Boot-menu backgrounds written:"
"${IM_IDENTIFY[@]}" config/bootloaders/grub-pc/splash.png config/bootloaders/syslinux_common/splash.png || true

# Give the boot menus a Linuxium title (based on the installed templates,
# so this keeps working even if the templates change a little).
GRUB_THEME_SRC="/usr/share/live/build/bootloaders/grub-pc/live-theme/theme.txt"
if [ -f "$GRUB_THEME_SRC" ]; then
  mkdir -p config/bootloaders/grub-pc/live-theme
  cp "$GRUB_THEME_SRC" config/bootloaders/grub-pc/live-theme/theme.txt
  sed -i 's/^title-text[[:space:]]*:.*/title-text: "Linuxium"/' config/bootloaders/grub-pc/live-theme/theme.txt
fi
SYS_MENU_SRC="/usr/share/live/build/bootloaders/syslinux_common/menu.cfg"
if [ -f "$SYS_MENU_SRC" ]; then
  cp "$SYS_MENU_SRC" config/bootloaders/syslinux_common/menu.cfg
  # ISOLINUX directives are case-insensitive and templates vary in case;
  # match "menu title" in any case (GNU sed I flag).
  sed -i 's/^menu title.*/menu title Linuxium/I' config/bootloaders/syslinux_common/menu.cfg
fi

# Bookworm live-build adds findiso=${iso_path} to the normal GRUB live
# entries but not to GRUB's fail-safe entries. On a plain DVD/USB that
# omission is harmless; when GRUB loopback-boots the ISO as a file
# (Ventoy and similar), live-boot needs that parameter to find the live
# filesystem inside the ISO. Patch only the generated GRUB config in a
# binary hook - putting the GRUB variable in the shared failsafe append
# would make ISOLINUX pass the literal text to the kernel instead.
mkdir -p config/hooks/normal
cat > config/hooks/normal/0100-linuxium-grub-failsafe.hook.binary <<'EOF'
#!/bin/sh
set -e

GRUB_CFG="boot/grub/grub.cfg"
if [ ! -f "$GRUB_CFG" ]; then
  echo "ERROR: $GRUB_CFG not found; cannot patch the GRUB fail-safe entry" >&2
  exit 1
fi

TMP_CFG="${GRUB_CFG}.tmp.$$"
trap 'rm -f "$TMP_CFG"' EXIT HUP INT TERM

awk '
  /^[[:space:]]*menuentry .*fail-safe mode/ { failsafe = 1 }
  /^[[:space:]]*}/ { failsafe = 0 }
  failsafe && /^[[:space:]]*linux[[:space:]]/ {
    seen++
    if ($0 !~ /findiso=/) $0 = $0 " findiso=${iso_path}"
  }
  { print }
  END { if (!seen) exit 1 }
' "$GRUB_CFG" > "$TMP_CFG"

chmod --reference="$GRUB_CFG" "$TMP_CFG" 2>/dev/null || chmod 644 "$TMP_CFG"
mv "$TMP_CFG" "$GRUB_CFG"
trap - EXIT HUP INT TERM
EOF
chmod +x config/hooks/normal/0100-linuxium-grub-failsafe.hook.binary

# 5g. Calamares installer branding (the Debian configuration itself is kept;
#     only the branding component is replaced, see the hook in section 9).
CALA_BRAND="config/includes.chroot/etc/calamares/branding/linuxium"
mkdir -p "$CALA_BRAND"
"${IM[@]}" "$LOGO" -auto-orient -resize 256x256 "$CALA_BRAND/logo.png"
"${IM[@]}" "$WALLPAPER" -auto-orient -resize '520x340^' -gravity center -extent 520x340 "$CALA_BRAND/welcome.png"
"${IM[@]}" "$WALLPAPER" -auto-orient -resize '800x480^' -gravity center -extent 800x480 "$CALA_BRAND/slide1.png"
if [ -f "$WP_DIR/new-york-city.jpg" ]; then SLIDE2_SRC="$WP_DIR/new-york-city.jpg"; else SLIDE2_SRC="$WALLPAPER"; fi
"${IM[@]}" "$SLIDE2_SRC" -auto-orient -resize '800x480^' -gravity center -extent 800x480 "$CALA_BRAND/slide2.png"
if [ -f "$WP_DIR/cats-eye-nebula.jpg" ]; then SLIDE3_SRC="$WP_DIR/cats-eye-nebula.jpg"; else SLIDE3_SRC="$WALLPAPER"; fi
"${IM[@]}" "$SLIDE3_SRC" -auto-orient -resize '800x480^' -gravity center -extent 800x480 "$CALA_BRAND/slide3.png"

cat > "$CALA_BRAND/branding.desc" <<EOF
---
componentName: linuxium
welcomeStyleCalamares: true
welcomeExpandingLogo: true
windowExpanding: normal
windowSize: 800px,520px
windowPlacement: center

strings:
    productName: Linuxium
    shortProductName: Linuxium
    version: "${LINUXIUM_VERSION}"
    shortVersion: "${LINUXIUM_VERSION}"
    versionedName: Linuxium ${LINUXIUM_VERSION}
    shortVersionedName: Linuxium ${LINUXIUM_VERSION}
    bootloaderEntryName: Linuxium
    supportUrl: https://www.debian.org/support
    knownIssuesUrl: https://bugs.debian.org/
    releaseNotesUrl: https://www.debian.org/releases/bookworm/releasenotes

images:
    productLogo: "logo.png"
    productIcon: "logo.png"
    productWelcome: "welcome.png"

slideshow: "show.qml"
slideshowAPI: 2

style:
    sidebarBackground: "#20242a"
    sidebarText: "#FFFFFF"
    sidebarTextSelect: "#FFFFFF"
    sidebarTextHighlight: "#3b82f6"
EOF

cat > "$CALA_BRAND/show.qml" <<'QMLEOF'
/* Linuxium Calamares slideshow, adapted from the Debian one (GPL). */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Timer {
        interval: 15000
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Image {
            id: image1
            source: "slide1.png"
            width: 467; height: 280
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
        }
        Text {
            anchors.horizontalCenter: image1.horizontalCenter
            anchors.top: image1.bottom
            text: qsTr("Welcome to Linuxium :) luv from playerz<br/>" +
                  "Sit back - the rest of the installation is automatic.")
            wrapMode: Text.WordWrap
            width: 600
            horizontalAlignment: Text.Center
        }
    }

    Slide {
        Image {
            id: image2
            source: "slide2.png"
            width: 467; height: 280
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
        }
        Text {
            anchors.horizontalCenter: image2.horizontalCenter
            anchors.top: image2.bottom
            text: qsTr("Make it yours: new wallpapers (New York City and friends)<br/>" +
                  "are waiting in Settings, Backgrounds.")
            wrapMode: Text.WordWrap
            width: 600
            horizontalAlignment: Text.Center
        }
    }

    Slide {
        Image {
            id: image3
            source: "slide3.png"
            width: 467; height: 280
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
        }
        Text {
            anchors.horizontalCenter: image3.horizontalCenter
            anchors.top: image3.bottom
            text: qsTr("Firefox, GIMP, Inkscape, LibreOffice and VLC are ready to go.<br/>" +
                  "Almost there...")
            wrapMode: Text.WordWrap
            width: 600
            horizontalAlignment: Text.Center
        }
    }
}
QMLEOF

# 5h. Live-only startup welcome popup + "Linuxium Experience" installer
# NOTE: The intro is strictly a one-time live-session popup dialog (not an
# openable application in the menu, taskbar, search bar, or $PATH).
# The primary installer is the custom "Linuxium Experience" (dark GTK app
# with circular step buttons); Calamares stays installed as a fallback
# backend for advanced partitioning.
BIN_INC="config/includes.chroot/usr/bin"
LIB_LINUXIUM="config/includes.chroot/usr/lib/linuxium"
APP_INC="config/includes.chroot/usr/share/applications"
AUTO_INC="config/includes.chroot/etc/xdg/autostart"
DOC_LINUXIUM="config/includes.chroot/usr/share/doc/linuxium"
mkdir -p "$BIN_INC" "$LIB_LINUXIUM" "$APP_INC" "$AUTO_INC" "$DOC_LINUXIUM"

cat > "$LIB_LINUXIUM/welcome-popup" <<'PYEOF'
#!/usr/bin/env python3
"""Linuxium Welcome - live-session startup popup dialog (GTK 3)."""
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gtk  # noqa: E402

LOGO = "/usr/share/pixmaps/linuxium.png"
DISABLE_FILE = Path.home() / ".config" / "linuxium" / "no-welcome"


class WelcomePopup(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="Welcome to Linuxium")
        self.set_default_size(460, -1)
        self.set_resizable(False)
        self.set_border_width(20)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.connect("destroy", Gtk.main_quit)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(outer)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, 64, 64, True)
            header.pack_start(Gtk.Image.new_from_pixbuf(pixbuf), False, False, 0)
        except Exception:
            pass

        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        titles.set_valign(Gtk.Align.CENTER)
        title = Gtk.Label()
        title.set_markup(
            '<span size="x-large" weight="bold">Welcome to Linuxium :)</span>'
        )
        title.set_halign(Gtk.Align.START)
        subtitle = Gtk.Label()
        subtitle.set_markup('<span size="medium">luv from playerz</span>')
        subtitle.set_halign(Gtk.Align.START)
        titles.pack_start(title, False, False, 0)
        titles.pack_start(subtitle, False, False, 0)
        header.pack_start(titles, False, False, 0)
        outer.pack_start(header, False, False, 0)

        info = Gtk.Label()
        info.set_markup(
            "You are running the <b>Linuxium</b> live session — everything works "
            "right out of the box without touching your hard drive.\n\n"
            "Ready to install permanently? Click <b>Linuxium Experience</b> below or "
            "use the <b>Linuxium Experience</b> shortcut right on your desktop."
        )
        info.set_line_wrap(True)
        info.set_max_width_chars(54)
        info.set_xalign(0)
        outer.pack_start(info, False, False, 0)

        bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        toggle = Gtk.CheckButton(label="Don't show again")
        toggle.connect("toggled", self.on_toggle)
        bottom.pack_start(toggle, False, False, 0)

        dismiss_btn = Gtk.Button(label="Start Exploring")
        dismiss_btn.connect("clicked", lambda _b: self.destroy())

        install_btn = Gtk.Button(label="Linuxium Experience")
        install_btn.get_style_context().add_class("suggested-action")
        install_btn.connect("clicked", self.on_install)

        bottom.pack_end(install_btn, False, False, 0)
        bottom.pack_end(dismiss_btn, False, False, 0)
        outer.pack_start(bottom, False, False, 4)

    def on_toggle(self, button):
        try:
            if button.get_active():
                DISABLE_FILE.parent.mkdir(parents=True, exist_ok=True)
                DISABLE_FILE.write_text("disabled by user\n", encoding="utf-8")
            else:
                DISABLE_FILE.unlink(missing_ok=True)
        except OSError:
            pass

    def on_install(self, _button):
        try:
            subprocess.Popen(
                ["/usr/bin/linuxium-experience"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            pass
        self.destroy()


def main():
    if DISABLE_FILE.exists() and "--force" not in sys.argv:
        return 0
    popup = WelcomePopup()
    popup.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$LIB_LINUXIUM/welcome-popup"

cat > "$LIB_LINUXIUM/welcome-autostart" <<'EOF'
#!/bin/sh
# Show the Welcome popup once per LIVE session only and guarantee the
# "Linuxium Experience" desktop icon is present and trusted.
# An installed system has neither "boot=live" on its kernel command line
# nor /run/live/medium, so this quietly does nothing after installation.
case " $(cat /proc/cmdline 2>/dev/null) " in
  *" boot=live "*) : ;;
  *) [ -d /run/live/medium ] || exit 0 ;;
esac

_DESKTOP_DIR="$HOME/Desktop"
if command -v xdg-user-dir >/dev/null 2>&1; then
  _XDG_DESK="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  if [ -n "$_XDG_DESK" ]; then
    _DESKTOP_DIR="$_XDG_DESK"
  fi
fi
mkdir -p "$_DESKTOP_DIR" 2>/dev/null || true
if [ -f /usr/share/applications/linuxium-experience.desktop ] && [ ! -f "$_DESKTOP_DIR/linuxium-experience.desktop" ]; then
  cp -f /usr/share/applications/linuxium-experience.desktop "$_DESKTOP_DIR/linuxium-experience.desktop" 2>/dev/null || true
fi
if [ -f /usr/share/applications/install-linuxium.desktop ] && [ ! -f "$_DESKTOP_DIR/install-linuxium.desktop" ]; then
  cp -f /usr/share/applications/install-linuxium.desktop "$_DESKTOP_DIR/install-linuxium.desktop" 2>/dev/null || true
fi

# Mark desktop shortcuts executable + trusted in GVFS so Nemo/GIO never show
# a lock emblem or untrusted-launcher prompt in the live session.
if [ -d "$_DESKTOP_DIR" ]; then
  for _desk_file in "$_DESKTOP_DIR"/*.desktop; do
    [ -f "$_desk_file" ] || continue
    chmod 0755 "$_desk_file" 2>/dev/null || true
    if command -v gio >/dev/null 2>&1; then
      gio set --type=string "$_desk_file" metadata::trusted true 2>/dev/null || true
    fi
    touch "$_desk_file" 2>/dev/null || true
  done
fi

[ -e "$HOME/.config/linuxium/no-welcome" ] && exit 0
shown="${XDG_RUNTIME_DIR:-/tmp}/linuxium-welcome.shown"
[ -e "$shown" ] && exit 0
lock="${XDG_RUNTIME_DIR:-/tmp}/linuxium-welcome.lock"
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM
: > "$shown" 2>/dev/null || true
# Give the desktop a moment to come up first.
sleep 2
/usr/lib/linuxium/welcome-popup
exit $?
EOF
chmod +x "$LIB_LINUXIUM/welcome-autostart"

cat > "$LIB_LINUXIUM/linuxium-experience" <<'PYEOF'
#!/usr/bin/env python3
"""Linuxium Experience - custom Linuxium installer (GTK 3, dark theme).

Smooth dark UI with circular step buttons that rotate around the centre.
Performs a real install: partition -> format -> copy live filesystem ->
fstab -> GRUB -> user -> cleanup. Runs as root (see /usr/bin wrapper).
Calamares remains available as an advanced fallback.
"""
import math
import os
import re
import subprocess
import sys
import threading

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # noqa: E402

LOGO = "/usr/share/pixmaps/linuxium.png"
VERSION = "1.1"
TARGET = "/tmp/linuxium-target"

DARK_CSS = """
window { background-color: #12141a; }
headerbar { background-color: #1a1e28; }
button { background-color: #2a3040; color: #ffffff; border-radius: 10px; border: 1px solid #3a4155; padding: 8px 18px; }
button:hover { background-color: #3b82f6; }
button:disabled { background-color: #1e2128; color: #6b7280; }
button.suggested-action { background-color: #3b82f6; color: #ffffff; }
button.suggested-action:hover { background-color: #2563eb; }
entry, combobox entry { background-color: #1a1e28; color: #ffffff; border: 1px solid #3a4155; border-radius: 8px; padding: 6px 10px; }
label { color: #ffffff; }
label.muted { color: #9aa0b0; }
progressbar { background-color: #2a3040; border-radius: 8px; }
progressbar progress { background-color: #3b82f6; border-radius: 8px; }
textview { background-color: #0f1219; color: #d1d5db; }
"""

STEPS = ["Welcome", "Disk", "User", "Install", "Finish"]


def run(cmd, log=None):
    if log:
        log("  $ " + " ".join(cmd))
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log and p.stdout:
        for line in p.stdout.splitlines():
            log("  " + line)
    if p.returncode != 0:
        raise RuntimeError("Command failed (%d): %s" % (p.returncode, " ".join(cmd)))
    return p.stdout


def list_disks():
    out = subprocess.run(
        ["lsblk", "-d", "-o", "NAME,SIZE,MODEL,TRAN", "--noheadings"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    ).stdout
    disks = []
    for line in out.strip().splitlines():
        parts = line.split(None, 1)
        if not parts:
            continue
        name = parts[0].strip()
        rest = parts[1].strip() if len(parts) > 1 else ""
        if not name.startswith(("sd", "nvme", "vd", "hd", "mmcblk")):
            continue
        disks.append((name, rest))
    return disks


def is_live_disk(name):
    # Live medium is mounted at /run/live/medium; find its source disk.
    try:
        out = subprocess.run(
            ["findmnt", "-n", "-o", "SOURCE", "/run/live/medium"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        ).stdout.strip()
        if out:
            # e.g. /dev/sdb1 or /dev/loop0
            dev = out.split()[0]
            if dev.startswith("/dev/"):
                base = dev[5:]
                # strip partition suffix: sdb1 -> sdb, nvme0n1p1 -> nvme0n1
                m = re.match(r"^(nvme\d+n\d+|mmcblk\d+|sd[a-z]+|vd[a-z]+|hd[a-z]+)", base)
                if m and m.group(1) == name:
                    return True
    except Exception:
        pass
    return False


def is_efi():
    return os.path.isdir("/sys/firmware/efi")


class CircularNav(Gtk.DrawingArea):
    def __init__(self, on_select):
        super().__init__()
        self.set_size_request(240, 240)
        self.on_select = on_select
        self.current = 0
        self.rotation = 0.0
        self.target_rotation = 0.0
        self.anim_id = None
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("button-press-event", self._on_press)

    def set_current(self, idx):
        self.current = idx
        # Rotate so current step sits at the top (-90 degrees).
        self.target_rotation = -math.pi / 2 - idx * (2 * math.pi / len(STEPS))
        if self.anim_id is None:
            self.anim_id = GLib.timeout_add(16, self._animate)

    def _animate(self):
        diff = self.target_rotation - self.rotation
        if abs(diff) < 0.01:
            self.rotation = self.target_rotation
            self.queue_draw()
            self.anim_id = None
            return False
        self.rotation += diff * 0.18
        self.queue_draw()
        return True

    def _positions(self):
        cx, cy, r = 120, 120, 82
        pts = []
        for i in range(len(STEPS)):
            ang = self.rotation + i * (2 * math.pi / len(STEPS))
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
        return pts

    def _on_press(self, widget, event):
        pts = self._positions()
        for i, (x, y) in enumerate(pts):
            if math.hypot(event.x - x, event.y - y) <= 26:
                self.on_select(i)
                return True
        return False

    def do_draw(self, cr):
        alloc = self.get_allocation()
        cr.set_source_rgb(0.07, 0.08, 0.11)
        cr.rectangle(0, 0, alloc.width, alloc.height)
        cr.fill()
        cx, cy, r = 120, 120, 82
        # Connecting circle
        cr.set_source_rgb(0.23, 0.26, 0.33)
        cr.set_line_width(2)
        cr.arc(cx, cy, r, 0, 2 * math.pi)
        cr.stroke()
        pts = self._positions()
        for i, (x, y) in enumerate(pts):
            if i == self.current:
                cr.set_source_rgb(0.23, 0.51, 0.96)
            else:
                cr.set_source_rgb(0.16, 0.18, 0.25)
            cr.arc(x, y, 24, 0, 2 * math.pi)
            cr.fill()
            cr.set_source_rgb(1, 1, 1)
            cr.set_line_width(1.5)
            cr.arc(x, y, 24, 0, 2 * math.pi)
            cr.stroke()
            cr.set_source_rgb(1, 1, 1)
            cr.select_font_face("Sans")
            cr.set_font_size(15)
            cr.move_to(x - 4, y + 5)
            cr.show_text(str(i + 1))
        # Centre label
        cr.set_source_rgb(0.60, 0.63, 0.69)
        cr.set_font_size(11)
        cr.move_to(cx - 32, cy + 4)
        cr.show_text(STEPS[self.current])


class Experience(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="Linuxium Experience")
        self.set_default_size(920, 640)
        self.set_resizable(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", Gtk.main_quit)
        self.step = 0
        self.selected_disk = None
        self.cancelled = False
        self.install_thread = None

        css = Gtk.CssProvider()
        css.load_from_data(DARK_CSS.encode())
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(outer)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header.set_border_width(14)
        try:
            pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, 48, 48, True)
            header.pack_start(Gtk.Image.new_from_pixbuf(pix), False, False, 0)
        except Exception:
            pass
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        t = Gtk.Label()
        t.set_markup('<span size="x-large" weight="bold">Linuxium Experience</span>')
        t.set_halign(Gtk.Align.START)
        s = Gtk.Label()
        s.set_markup('<span size="small" color="#9aa0b0">Install Linuxium %s — luv from playerz</span>' % VERSION)
        s.set_halign(Gtk.Align.START)
        titles.pack_start(t, False, False, 0)
        titles.pack_start(s, False, False, 0)
        header.pack_start(titles, False, False, 0)
        outer.pack_start(header, False, False, 0)

        mid = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        mid.set_border_width(16)
        outer.pack_start(mid, True, True, 0)

        self.nav = CircularNav(self.goto_step)
        mid.pack_start(self.nav, False, False, 0)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(300)
        mid.pack_start(self.stack, True, True, 0)

        self.stack.add_named(self._welcome_page(), "welcome")
        self.stack.add_named(self._disk_page(), "disk")
        self.stack.add_named(self._user_page(), "user")
        self.stack.add_named(self._install_page(), "install")
        self.stack.add_named(self._finish_page(), "finish")

        bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        bottom.set_border_width(14)
        self.back_btn = Gtk.Button(label="Back")
        self.back_btn.connect("clicked", lambda b: self.goto_step(self.step - 1))
        self.next_btn = Gtk.Button(label="Next")
        self.next_btn.get_style_context().add_class("suggested-action")
        self.next_btn.connect("clicked", self.on_next)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda b: self.destroy())
        bottom.pack_start(self.back_btn, False, False, 0)
        bottom.pack_end(self.next_btn, False, False, 0)
        bottom.pack_end(cancel, False, False, 0)
        outer.pack_start(bottom, False, False, 0)

        self._refresh_nav()

    # ---------- pages ----------
    def _welcome_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(20)
        try:
            pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, 128, 128, True)
            img = Gtk.Image.new_from_pixbuf(pix)
            img.set_halign(Gtk.Align.CENTER)
            box.pack_start(img, False, False, 0)
        except Exception:
            pass
        title = Gtk.Label()
        title.set_markup('<span size="xx-large" weight="bold">Welcome to Linuxium :)</span>')
        title.set_halign(Gtk.Align.CENTER)
        box.pack_start(title, False, False, 0)
        info = Gtk.Label()
        info.set_markup(
            "This is the <b>Linuxium Experience</b> — a smooth, dark installer.\n"
            "Click the circular buttons to move between steps.\n\n"
            "• Windows apps: Wine + Winetricks are preinstalled\n"
            "• VMware: Open VM Tools + vmwgfx 3D are ready\n"
            "• Boot splash: Tetris blocks build Lynx the penguin"
        )
        info.set_halign(Gtk.Align.CENTER)
        info.set_line_wrap(True)
        box.pack_start(info, False, False, 0)
        return box

    def _disk_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(20)
        title = Gtk.Label()
        title.set_markup('<span size="large" weight="bold">Choose a disk</span>')
        title.set_halign(Gtk.Align.START)
        box.pack_start(title, False, False, 0)
        warn = Gtk.Label()
        warn.set_markup('<span color="#f59e0b">This will erase the selected disk. Back up your files first!</span>')
        warn.set_halign(Gtk.Align.START)
        box.pack_start(warn, False, False, 0)
        self.disk_list = Gtk.ListBox()
        scrolled = Gtk.ScrolledWindow()
        scrolled.add(self.disk_list)
        scrolled.set_min_content_height(180)
        box.pack_start(scrolled, True, True, 0)
        self.disk_refresh = Gtk.Button(label="Refresh disks")
        self.disk_refresh.connect("clicked", lambda b: self._fill_disks())
        box.pack_start(self.disk_refresh, False, False, 0)
        self.erase_check = Gtk.CheckButton(label="I understand this will erase the selected disk")
        box.pack_start(self.erase_check, False, False, 0)
        adv = Gtk.Button(label="Advanced partitioning (Calamares)")
        adv.connect("clicked", self._launch_calamares)
        box.pack_start(adv, False, False, 0)
        self._fill_disks()
        return box

    def _fill_disks(self):
        for child in list(self.disk_list.get_children()):
            self.disk_list.remove(child)
        try:
            disks = list_disks()
        except Exception:
            disks = []
        if not disks:
            row = Gtk.Label(label="No disks found.")
            self.disk_list.add(row)
        for name, rest in disks:
            row = Gtk.ListBoxRow()
            label = Gtk.Label()
            live_tag = " (live USB — cannot install here)" if is_live_disk(name) else ""
            label.set_markup("<b>/dev/%s</b>  %s%s" % (name, rest, live_tag))
            label.set_halign(Gtk.Align.START)
            label.set_xalign(0)
            row.add(label)
            row.set_data("disk", name)
            self.disk_list.add(row)
        self.disk_list.show_all()

    def _user_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(20)
        title = Gtk.Label()
        title.set_markup('<span size="large" weight="bold">Create your account</span>')
        title.set_halign(Gtk.Align.START)
        box.pack_start(title, False, False, 0)
        self.user_entry = Gtk.Entry()
        self.user_entry.set_placeholder_text("Username (lowercase, e.g. playerz)")
        box.pack_start(self.user_entry, False, False, 0)
        self.name_entry = Gtk.Entry()
        self.name_entry.set_placeholder_text("Full name")
        box.pack_start(self.name_entry, False, False, 0)
        self.pass_entry = Gtk.Entry()
        self.pass_entry.set_placeholder_text("Password")
        self.pass_entry.set_visibility(False)
        box.pack_start(self.pass_entry, False, False, 0)
        self.pass2_entry = Gtk.Entry()
        self.pass2_entry.set_placeholder_text("Confirm password")
        self.pass2_entry.set_visibility(False)
        box.pack_start(self.pass2_entry, False, False, 0)
        self.host_entry = Gtk.Entry()
        self.host_entry.set_text("linuxium")
        self.host_entry.set_placeholder_text("Computer name")
        box.pack_start(self.host_entry, False, False, 0)
        self.tz_combo = Gtk.ComboBoxText()
        for tz in ["UTC", "America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Berlin", "Asia/Tokyo", "Australia/Sydney"]:
            self.tz_combo.append_text(tz)
        self.tz_combo.set_active(0)
        box.pack_start(self.tz_combo, False, False, 0)
        return box

    def _install_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(20)
        title = Gtk.Label()
        title.set_markup('<span size="large" weight="bold">Installing Linuxium…</span>')
        title.set_halign(Gtk.Align.START)
        box.pack_start(title, False, False, 0)
        self.progress = Gtk.ProgressBar()
        self.progress.set_show_text(True)
        box.pack_start(self.progress, False, False, 0)
        self.status_label = Gtk.Label(label="Ready.")
        self.status_label.set_halign(Gtk.Align.START)
        box.pack_start(self.status_label, False, False, 0)
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        scrolled = Gtk.ScrolledWindow()
        scrolled.add(self.log_view)
        scrolled.set_min_content_height(280)
        box.pack_start(scrolled, True, True, 0)
        return box

    def _finish_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(20)
        try:
            pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, 96, 96, True)
            img = Gtk.Image.new_from_pixbuf(pix)
            img.set_halign(Gtk.Align.CENTER)
            box.pack_start(img, False, False, 0)
        except Exception:
            pass
        title = Gtk.Label()
        title.set_markup('<span size="xx-large" weight="bold">Linuxium is ready! :)</span>')
        title.set_halign(Gtk.Align.CENTER)
        box.pack_start(title, False, False, 0)
        info = Gtk.Label(label="Installation complete. Reboot to start using Linuxium.")
        info.set_halign(Gtk.Align.CENTER)
        box.pack_start(info, False, False, 0)
        reboot = Gtk.Button(label="Reboot now")
        reboot.get_style_context().add_class("suggested-action")
        reboot.connect("clicked", lambda b: subprocess.run(["systemctl", "reboot"]))
        reboot.set_halign(Gtk.Align.CENTER)
        box.pack_start(reboot, False, False, 0)
        return box

    # ---------- navigation ----------
    def _refresh_nav(self):
        self.nav.set_current(self.step)
        names = ["welcome", "disk", "user", "install", "finish"]
        self.stack.set_visible_child_name(names[self.step])
        self.back_btn.set_sensitive(self.step > 0 and self.step != 3)
        if self.step == 4:
            self.next_btn.set_label("Close")
        elif self.step == 3:
            self.next_btn.set_label("Installing…")
            self.next_btn.set_sensitive(False)
        else:
            self.next_btn.set_label("Next")
            self.next_btn.set_sensitive(True)

    def goto_step(self, idx):
        if idx < 0 or idx >= len(STEPS):
            return
        if self.step == 3:
            return
        # Validate forward moves
        if idx > self.step:
            if self.step == 1 and not self._disk_valid():
                self._error("Please select a disk and tick the erase confirmation.")
                return
            if self.step == 2 and not self._user_valid():
                self._error("Please check your username and passwords.")
                return
        self.step = idx
        self._refresh_nav()

    def on_next(self, _btn):
        if self.step == 4:
            self.destroy()
            return
        if self.step == 2:
            # Start install
            self.goto_step(3)
            self._start_install()
            return
        self.goto_step(self.step + 1)

    def _disk_valid(self):
        row = self.disk_list.get_selected_row()
        if row is None:
            return False
        name = row.get_data("disk")
        if not name or is_live_disk(name):
            return False
        if not self.erase_check.get_active():
            return False
        self.selected_disk = name
        return True

    def _user_valid(self):
        user = self.user_entry.get_text().strip()
        pw = self.pass_entry.get_text()
        pw2 = self.pass2_entry.get_text()
        if not re.match(r"^[a-z_][a-z0-9_-]*$", user):
            return False
        if len(pw) < 4 or pw != pw2:
            return False
        return True

    def _error(self, msg):
        dlg = Gtk.MessageDialog(self, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, msg)
        dlg.run()
        dlg.destroy()

    def _launch_calamares(self, _btn):
        try:
            subprocess.Popen(["/usr/bin/install-linuxium", "--calamares"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError:
            pass

    # ---------- install ----------
    def _log(self, msg):
        def _add():
            buf = self.log_view.get_buffer()
            buf.insert(buf.get_end_iter(), msg + "\n")
            return False
        GLib.idle_add(_add)

    def _progress(self, frac, text):
        def _set():
            self.progress.set_fraction(max(0.0, min(1.0, frac)))
            self.progress.set_text(text)
            self.status_label.set_text(text)
            return False
        GLib.idle_add(_set)

    def _start_install(self):
        self.cancelled = False
        self.install_thread = threading.Thread(target=self._do_install, daemon=True)
        self.install_thread.start()

    def _do_install(self):
        try:
            disk = self.selected_disk
            user = self.user_entry.get_text().strip()
            pw = self.pass_entry.get_text()
            host = self.host_entry.get_text().strip() or "linuxium"
            tz = self.tz_combo.get_active_text() or "UTC"
            dev = "/dev/" + disk
            efi = is_efi()
            log = self._log
            prog = self._progress

            prog(0.02, "Preparing disk %s…" % dev)
            log("Linuxium Experience install to %s (EFI=%s)" % (dev, efi))
            # Unmount any mounted partitions on target
            try:
                out = subprocess.run(["lsblk", "-n", "-o", "MOUNTPOINT", dev],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
                for mp in out.split():
                    if mp and mp != TARGET:
                        run(["umount", "-R", mp], log)
            except Exception:
                pass
            run(["umount", "-R", TARGET], log) if os.path.isdir(TARGET) else None

            prog(0.08, "Partitioning…")
            if efi:
                run(["parted", "-s", dev, "mklabel", "gpt"], log)
                run(["parted", "-s", dev, "mkpart", "ESP", "fat32", "1MiB", "513MiB"], log)
                run(["parted", "-s", dev, "set", "1", "esp", "on"], log)
                run(["parted", "-s", dev, "mkpart", "ROOT", "ext4", "513MiB", "100%"], log)
                part_efi = dev + ("p1" if disk.startswith("nvme") or disk.startswith("mmcblk") else "1")
                part_root = dev + ("p2" if disk.startswith("nvme") or disk.startswith("mmcblk") else "2")
            else:
                run(["parted", "-s", dev, "mklabel", "msdos"], log)
                run(["parted", "-s", dev, "mkpart", "primary", "ext4", "1MiB", "100%"], log)
                run(["parted", "-s", dev, "set", "1", "boot", "on"], log)
                part_efi = None
                part_root = dev + ("p1" if disk.startswith("nvme") or disk.startswith("mmcblk") else "1")

            prog(0.15, "Formatting…")
            if efi:
                run(["mkfs.fat", "-F", "32", "-n", "LINUXIUM_EFI", part_efi], log)
            run(["mkfs.ext4", "-L", "LINUXIUM", "-F", part_root], log)

            prog(0.22, "Mounting…")
            os.makedirs(TARGET, exist_ok=True)
            run(["mount", part_root, TARGET], log)
            if efi:
                os.makedirs(os.path.join(TARGET, "boot", "efi"), exist_ok=True)
                run(["mount", part_efi, os.path.join(TARGET, "boot", "efi")], log)

            prog(0.35, "Copying system files…")
            squash = None
            for cand in ["/run/live/medium/live/filesystem.squashfs", "/live/filesystem.squashfs"]:
                if os.path.isfile(cand):
                    squash = cand
                    break
            if squash:
                run(["unsquashfs", "-f", "-d", TARGET, squash], log)
            else:
                run(["rsync", "-aHAX", "--exclude=/proc", "--exclude=/sys", "--exclude=/dev",
                     "--exclude=/run", "--exclude=/mnt", "--exclude=/media", "--exclude=/tmp",
                     "--exclude=/var/tmp", "/", TARGET + "/"], log)
            # Ensure kernel/initrd present (they live in the squashfs, but copy if missing)
            for k in os.listdir("/boot"):
                if k.startswith("vmlinuz-") or k.startswith("initrd.img-"):
                    src = os.path.join("/boot", k)
                    dst = os.path.join(TARGET, "boot", k)
                    if not os.path.exists(dst):
                        run(["cp", "-a", src, dst], log)

            prog(0.60, "Writing fstab…")
            def uuid_of(part):
                out = subprocess.run(["blkid", "-s", "UUID", "-o", "value", part],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.strip()
                return out
            root_uuid = uuid_of(part_root)
            lines = ["UUID=%s / ext4 defaults,errors=remount-ro 0 1" % root_uuid]
            if efi:
                efi_uuid = uuid_of(part_efi)
                lines.append("UUID=%s /boot/efi vfat umask=0077 0 1" % efi_uuid)
            with open(os.path.join(TARGET, "etc", "fstab"), "w") as f:
                f.write("\n".join(lines) + "\n")

            prog(0.70, "Installing bootloader…")
            if efi:
                run(["grub-install", "--target=x86_64-efi",
                     "--efi-directory=" + os.path.join(TARGET, "boot", "efi"),
                     "--bootloader-id=debian", "--recheck"], log)
            else:
                run(["grub-install", "--target=i386-pc",
                     "--boot-directory=" + os.path.join(TARGET, "boot"), dev], log)
            run(["chroot", TARGET, "update-grub"], log)
            run(["chroot", TARGET, "update-initramfs", "-u", "-k", "all"], log)

            prog(0.82, "Creating user…")
            run(["chroot", TARGET, "useradd", "-m", "-s", "/bin/bash", user], log)
            proc = subprocess.run(["chroot", TARGET, "chpasswd"],
                                  input="%s:%s\n" % (user, pw),
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if proc.returncode != 0:
                raise RuntimeError("chpasswd failed: " + proc.stdout)
            with open(os.path.join(TARGET, "etc", "hostname"), "w") as f:
                f.write(host + "\n")
            with open(os.path.join(TARGET, "etc", "hosts"), "w") as f:
                f.write("127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n" % host)
            try:
                os.symlink("/usr/share/zoneinfo/" + tz, os.path.join(TARGET, "etc", "localtime"))
            except FileExistsError:
                pass
            with open(os.path.join(TARGET, "etc", "timezone"), "w") as f:
                f.write(tz + "\n")

            prog(0.92, "Cleaning live-only files…")
            for p in [
                "etc/skel/Desktop/install-linuxium.desktop",
                "etc/skel/Desktop/linuxium-experience.desktop",
                "usr/share/applications/install-linuxium.desktop",
                "usr/share/applications/linuxium-experience.desktop",
                "usr/bin/install-linuxium",
                "usr/bin/linuxium-experience",
                "etc/xdg/autostart/linuxium-welcome.desktop",
            ]:
                try:
                    os.remove(os.path.join(TARGET, p))
                except OSError:
                    pass
            import shutil
            shutil.rmtree(os.path.join(TARGET, "usr", "lib", "linuxium"), ignore_errors=True)
            try:
                for home in os.listdir(os.path.join(TARGET, "home")):
                    for desk in ["install-linuxium.desktop", "linuxium-experience.desktop"]:
                        try:
                            os.remove(os.path.join(TARGET, "home", home, "Desktop", desk))
                        except OSError:
                            pass
            except OSError:
                pass

            prog(0.98, "Syncing…")
            run(["sync"], log)
            run(["umount", "-R", TARGET], log)

            prog(1.0, "Done!")
            log("Install complete.")
            GLib.idle_add(lambda: self.goto_step(4))
        except Exception as exc:
            self._log("ERROR: %s" % exc)
            GLib.idle_add(lambda: self._error("Install failed:\n%s" % exc))


def main():
    app = Experience()
    app.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$LIB_LINUXIUM/linuxium-experience"

cat > "$BIN_INC/linuxium-experience" <<'EOF'
#!/bin/sh
# Linuxium Experience launcher: run the custom installer as root so it can
# partition/mount/copy without per-command sudo prompts. Mirrors the old
# Calamares wrapper: X11 root access + stale live /etc/fstab handling.
export QT_AUTO_SCREEN_SCALE_FACTOR=1

if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  if command -v xhost >/dev/null 2>&1; then
    xhost +si:localuser:root >/dev/null 2>&1 || true
  fi
  _FSTAB_MOVED=0
  if [ -e /etc/fstab ] && [ ! -e /etc/fstab.orig.linuxium ]; then
    if sudo -n mv /etc/fstab /etc/fstab.orig.linuxium 2>/dev/null; then
      _FSTAB_MOVED=1
    fi
  fi
  restore_live_env() {
    if [ "$_FSTAB_MOVED" = "1" ] && [ -e /etc/fstab.orig.linuxium ] && [ ! -e /etc/fstab ]; then
      sudo -n mv /etc/fstab.orig.linuxium /etc/fstab 2>/dev/null || true
    fi
    if command -v xhost >/dev/null 2>&1; then
      xhost -si:localuser:root >/dev/null 2>&1 || true
    fi
  }
  trap restore_live_env EXIT INT TERM
  _RC=0
  sudo -n env \
    DISPLAY="${DISPLAY:-:0}" \
    XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
    LANG="${LANG:-en_US.UTF-8}" \
    QT_AUTO_SCREEN_SCALE_FACTOR=1 \
    /usr/lib/linuxium/linuxium-experience "$@" || _RC=$?
  trap - EXIT INT TERM
  restore_live_env
  exit "$_RC"
fi
exec pkexec /usr/lib/linuxium/linuxium-experience "$@"
EOF
chmod +x "$BIN_INC/linuxium-experience"

cat > "$BIN_INC/install-linuxium" <<'EOF'
#!/bin/sh
# Compatibility launcher: "Install Linuxium" now opens Linuxium Experience.
# Pass --calamares to open the Calamares fallback instead.
if [ "${1:-}" = "--calamares" ]; then
  shift
  export QT_AUTO_SCREEN_SCALE_FACTOR=1
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if command -v xhost >/dev/null 2>&1; then
      xhost +si:localuser:root >/dev/null 2>&1 || true
    fi
    _FSTAB_MOVED=0
    if [ -e /etc/fstab ] && [ ! -e /etc/fstab.orig.calamares ]; then
      if sudo -n mv /etc/fstab /etc/fstab.orig.calamares 2>/dev/null; then
        _FSTAB_MOVED=1
      fi
    fi
    restore_live_env() {
      if [ "$_FSTAB_MOVED" = "1" ] && [ -e /etc/fstab.orig.calamares ] && [ ! -e /etc/fstab ]; then
        sudo -n mv /etc/fstab.orig.calamares /etc/fstab 2>/dev/null || true
      fi
      if command -v xhost >/dev/null 2>&1; then
        xhost -si:localuser:root >/dev/null 2>&1 || true
      fi
    }
    trap restore_live_env EXIT INT TERM
    _CAL_RC=0
    sudo -n env \
      DISPLAY="${DISPLAY:-:0}" \
      XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
      LANG="${LANG:-en_US.UTF-8}" \
      QT_AUTO_SCREEN_SCALE_FACTOR=1 \
      calamares "$@" || _CAL_RC=$?
    trap - EXIT INT TERM
    restore_live_env
    exit "$_CAL_RC"
  fi
  for _WRAPPER in /usr/bin/install-debian /usr/bin/calamares-install-debian; do
    if [ -x "$_WRAPPER" ]; then
      exec "$_WRAPPER" "$@"
    fi
  done
  exec pkexec calamares "$@"
fi
exec /usr/bin/linuxium-experience "$@"
EOF
chmod +x "$BIN_INC/install-linuxium"

cat > "$APP_INC/linuxium-experience.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Linuxium Experience
GenericName=Linuxium Installer
Comment=Install Linuxium to your computer with the Linuxium Experience installer
Keywords=linuxium;install;installer;experience;system;
Exec=/usr/bin/linuxium-experience
Icon=linuxium
Terminal=false
Categories=System;
StartupWMClass=linuxium-experience
StartupNotify=true
EOF
chmod 0755 "$APP_INC/linuxium-experience.desktop"

cat > "$APP_INC/install-linuxium.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Linuxium Experience
GenericName=Linuxium Installer
Comment=Install Linuxium to your computer with the Linuxium Experience installer
Keywords=linuxium;install;installer;experience;system;calamares;
Exec=/usr/bin/linuxium-experience
Icon=linuxium
Terminal=false
Categories=System;
StartupWMClass=linuxium-experience
StartupNotify=true
EOF
chmod 0755 "$APP_INC/install-linuxium.desktop"

cat > "$AUTO_INC/linuxium-welcome.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Linuxium Welcome Popup
Comment=Show the one-time Linuxium welcome popup in the live session
Exec=/usr/lib/linuxium/welcome-autostart
Terminal=false
NoDisplay=true
OnlyShowIn=Cinnamon;X-Cinnamon;
X-GNOME-Autostart-enabled=true
EOF

cat > "$DOC_LINUXIUM/README.md" <<EOF
# Linuxium ${LINUXIUM_VERSION}

Welcome to Linuxium :) luv from playerz

* Live user: **linuxium** (automatic login and passwordless sudo; if a
  text-console or manual screen-lock prompt asks for its password, it is
  **live**)
* Installer: **Linuxium Experience** (dark custom installer with circular
  step buttons) right on the desktop or in the menu. Calamares remains
  available as an advanced fallback (Install Linuxium --calamares), and
  the classic Debian installer remains in the ISO boot menu.
* Windows apps: **Wine 8.0 + Winetricks** preinstalled. Double-click .exe
  files to run them with Wine. For 32-bit Windows apps, enable i386:
  \`sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install wine32 libwine:i386\`
  then run \`winetricks vcrun2019\` / \`winetricks corefonts\` as needed.
* VMware: **Open VM Tools + vmwgfx 3D** preinstalled. Use SVGA graphics
  with 3D acceleration ON in VMware for the full accelerated Cinnamon
  session (Linuxium auto-detects VMware and keeps hardware 3D). Clipboard,
  drag-and-drop and display resize work via open-vm-tools-desktop.
* Boot splash: Tetris blocks build Lynx the penguin (dark theme).
* Wallpapers: Settings > Backgrounds (credits in
  /usr/share/doc/linuxium-wallpapers/CREDITS.txt)

VirtualBox note: the kernel message
"[drm:vmw_host_log [vmwgfx]] *ERROR* Failed to send host log message"
is a harmless quirk of the vmwgfx driver running on VirtualBox's VMSVGA
graphics - the machine keeps booting normally.

For a desktop in VirtualBox use: 2+ CPUs, 4+ GB RAM, graphics controller
VMSVGA, 128 MB video memory, and 3D acceleration OFF. Linuxium
automatically uses Cinnamon's software-rendering session in VirtualBox,
both in the live session and after installation (boot with
linuxium-session=cinnamon to force the 3D session anyway). If a VM ever
stops at a black screen, pick the failsafe entry
in the boot menu - it uses software rendering with Xorg's firmware-
framebuffer fallback drivers. The boot menu's classic *Graphical
installer* is Debian Installer, not Calamares; on VirtualBox in EFI
mode its GTK frontend hits Debian bug #1036310, so set System ->
Acceleration -> Paravirtualization Interface to None (or Legacy) while
using that entry, or simply boot Live and use Linuxium Experience.
EOF

# 5j. OS theme: CBlack (by cloweling, LGPL-3.0; based on Linux Mint's
#     dark theme) - a Cinnamon shell theme AND a GTK2/GTK3 + Metacity
#     window theme. It is the theme pack the project adopted, vendored
#     into this repository at themes/CBlack (from the canonical
#     cinnamon-spices-themes repo, commit 5a98cccb) so builds do not
#     depend on a build-time download. Both halves are required:
#     cinnamon/cinnamon.css is what Cinnamon's shell loads, and
#     gtk-3.0/gtk.css (+ gtk-2.0, metacity-1) themes application
#     windows. Selected by default in section 6.
THEME_NAME="CBlack"
THEME_SRC="$SCRIPT_DIR/themes/$THEME_NAME"
for theme_file in "cinnamon/cinnamon.css" "gtk-3.0/gtk.css" "index.theme"; do
  if [ ! -s "$THEME_SRC/$theme_file" ]; then
    echo "ERROR: bundled $THEME_NAME theme is incomplete: $THEME_SRC/$theme_file missing or empty" >&2
    exit 1
  fi
done
mkdir -p config/includes.chroot/usr/share/themes
rm -rf "config/includes.chroot/usr/share/themes/$THEME_NAME"
cp -a "$THEME_SRC" "config/includes.chroot/usr/share/themes/$THEME_NAME"
THEME_DOC="config/includes.chroot/usr/share/doc/linuxium-theme-cblack"
mkdir -p "$THEME_DOC"
cat > "$THEME_DOC/CREDITS.txt" <<'EOF'
Linuxium default theme: CBlack

Author:  cloweling
Source:  https://cinnamon-spices.linuxmint.com/themes/view/CBlack
         (canonical repo: linuxmint/cinnamon-spices-themes, folder
          CBlack/files/CBlack, vendored in this repository under
          themes/CBlack so ISO builds need no theme download)
License: LGPL-3.0

CBlack is based on Linux Mint's dark theme and provides the Cinnamon
shell theme (cinnamon/), GTK 2/3 window themes (gtk-2.0/, gtk-3.0/),
a Metacity theme (metacity-1/) and an Xfwm4 theme (xfwm4/).

Known upstream issue (present in the pack as shipped, left as-is):
cinnamon.css references common-assets/checkbox/*.svg and gtk.css
references assets/thumbnail-frame.png, neither of which exists in
the pack. Those few elements simply render without that background
image; everything else is unaffected.
EOF
echo "Theme installed: $THEME_NAME (Cinnamon shell + GTK, from themes/$THEME_NAME)"

# 5k. Taskbar Search Bar applet (search-bar@linuxium): sits on the bottom
#     panel immediately next to the Lynx menu icon and opens a modal,
#     keyboard-focused search popup for applications, folders, settings
#     and quick math calculations (click or press Super+S).
SEARCH_APPLET_DIR="config/includes.chroot/usr/share/cinnamon/applets/search-bar@linuxium"
mkdir -p "$SEARCH_APPLET_DIR"

cat > "$SEARCH_APPLET_DIR/metadata.json" <<'EOF'
{
  "uuid": "search-bar@linuxium",
  "name": "Linuxium Search Bar",
  "description": "Search applications, folders, settings and quick math from the taskbar",
  "icon": "edit-find",
  "max-instances": -1
}
EOF

cat > "$SEARCH_APPLET_DIR/stylesheet.css" <<'EOF'
.linuxium-panel-search-box {
  background-color: #2b2b2b;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 14px;
  padding: 0px 11px;
  margin: 4px 3px;
  min-width: 175px;
  spacing: 7px;
}

.linuxium-panel-search-box:hover {
  background-color: #353535;
  border: 1px solid rgba(255, 255, 255, 0.26);
}

.linuxium-panel-search-active,
.linuxium-panel-search-active:hover {
  background-color: #303030;
  border: 1px solid #1565c0;
}

.linuxium-panel-search-compact {
  min-width: 0px;
  padding: 4px 6px;
}

.linuxium-panel-search-icon {
  color: rgba(255, 255, 255, 0.82);
}

.linuxium-panel-search-label {
  color: rgba(255, 255, 255, 0.72);
  font-size: 9.5pt;
}

.linuxium-search-popup {
  padding: 10px 12px;
  min-width: 390px;
  spacing: 8px;
}

.linuxium-search-entry {
  background-color: #1c1c1c;
  color: #ffffff;
  caret-color: #ffffff;
  selection-background-color: #1565c0;
  selected-color: #ffffff;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 8px;
  padding: 7px 10px;
  font-size: 10.5pt;
  width: 360px;
}

.linuxium-search-entry:focus,
.linuxium-search-entry:hover {
  background-color: #161616;
  color: #ffffff;
  border: 1px solid #1565c0;
}

.linuxium-search-entry-icon {
  color: rgba(255, 255, 255, 0.72);
  icon-size: 15px;
}

.linuxium-search-section-title {
  color: rgba(255, 255, 255, 0.56);
  font-size: 8.5pt;
  font-weight: bold;
  padding: 2px 4px 0px 4px;
}

.linuxium-search-results {
  spacing: 2px;
}

.linuxium-search-result {
  padding: 6px 8px;
  border-radius: 7px;
  spacing: 10px;
}

.linuxium-search-result:hover,
.linuxium-search-result-selected {
  background-color: #1565c0;
}

.linuxium-search-result-title {
  color: #ffffff;
  font-weight: bold;
  font-size: 9.8pt;
}

.linuxium-search-result-desc {
  color: rgba(255, 255, 255, 0.72);
  font-size: 8.5pt;
}

.linuxium-search-empty {
  color: rgba(255, 255, 255, 0.56);
  font-size: 9.5pt;
  padding: 12px 6px;
}
EOF

cat > "$SEARCH_APPLET_DIR/applet.js" <<'EOF'
const Applet = imports.ui.applet;
const Clutter = imports.gi.Clutter;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const Main = imports.ui.main;
const Mainloop = imports.mainloop;
const PopupMenu = imports.ui.popupMenu;
const St = imports.gi.St;
const Util = imports.misc.util;

const MAX_RESULTS = 8;
const QUICK_LAUNCH_IDS = [
    "install-linuxium.desktop",
    "nemo.desktop",
    "firefox-esr.desktop",
    "gimp.desktop",
    "org.gnome.Terminal.desktop",
    "org.gnome.Calculator.desktop",
    "cinnamon-settings.desktop",
    "vlc.desktop"
];

function evaluateMath(raw) {
    let expr = raw.replace(/\s+/g, "");
    if (!expr || !/[+\-*/%]/.test(expr) || !/^[0-9+\-*/().%]+$/.test(expr)) {
        return null;
    }
    let pos = 0;

    function parseExpression() {
        let val = parseTerm();
        while (pos < expr.length && (expr[pos] === "+" || expr[pos] === "-")) {
            let op = expr[pos++];
            let rhs = parseTerm();
            val = op === "+" ? val + rhs : val - rhs;
        }
        return val;
    }

    function parseTerm() {
        let val = parseFactor();
        while (pos < expr.length && (expr[pos] === "*" || expr[pos] === "/" || expr[pos] === "%")) {
            let op = expr[pos++];
            let rhs = parseFactor();
            if ((op === "/" || op === "%") && rhs === 0) {
                return NaN;
            }
            if (op === "*") val *= rhs;
            else if (op === "/") val /= rhs;
            else val %= rhs;
        }
        return val;
    }

    function parseFactor() {
        if (expr[pos] === "+") {
            pos++;
            return parseFactor();
        }
        if (expr[pos] === "-") {
            pos++;
            return -parseFactor();
        }
        if (expr[pos] === "(") {
            pos++;
            let val = parseExpression();
            if (expr[pos] !== ")") return NaN;
            pos++;
            return val;
        }
        let start = pos;
        let dots = 0;
        while (pos < expr.length && ((expr[pos] >= "0" && expr[pos] <= "9") || expr[pos] === ".")) {
            if (expr[pos] === "." && ++dots > 1) return NaN;
            pos++;
        }
        if (pos === start) return NaN;
        return parseFloat(expr.slice(start, pos));
    }

    let result = parseExpression();
    if (pos !== expr.length || !Number.isFinite(result)) {
        return null;
    }
    if (String(result) === expr) {
        return null;
    }
    return Number(result.toPrecision(12)).toString();
}

class LinuxiumSearchBarApplet extends Applet.Applet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);
        this.setAllowedLayout(Applet.AllowedLayout.BOTH);
        this.set_applet_tooltip(_("Search applications, folders and settings (Super+S)"));

        this._orientation = orientation;
        this._hotkeyName = "linuxium-search-bar-" + this.instance_id;
        this._results = [];
        this._selectedIndex = 0;

        this.pillBox = new St.BoxLayout({
            style_class: "linuxium-panel-search-box",
            y_align: Clutter.ActorAlign.CENTER
        });
        this.panelIcon = new St.Icon({
            icon_name: "edit-find-symbolic",
            icon_type: St.IconType.SYMBOLIC,
            icon_size: 14,
            style_class: "linuxium-panel-search-icon",
            y_align: Clutter.ActorAlign.CENTER
        });
        this.panelLabel = new St.Label({
            text: _("Search..."),
            style_class: "linuxium-panel-search-label",
            y_align: Clutter.ActorAlign.CENTER
        });
        this.pillBox.add_child(this.panelIcon);
        this.pillBox.add_child(this.panelLabel);
        this.actor.add_child(this.pillBox);
        this._syncOrientationLayout();

        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);

        this.popupBox = new St.BoxLayout({
            vertical: true,
            style_class: "linuxium-search-popup"
        });
        this.menu.addActor(this.popupBox);

        this.searchEntry = new St.Entry({
            style_class: "linuxium-search-entry",
            hint_text: _("Type here to search apps, folders or math..."),
            track_hover: true,
            can_focus: true
        });
        this._entryIcon = new St.Icon({
            icon_name: "edit-find-symbolic",
            icon_type: St.IconType.SYMBOLIC,
            style_class: "linuxium-search-entry-icon"
        });
        this.searchEntry.set_secondary_icon(this._entryIcon);
        this.searchEntry.connect("secondary-icon-clicked", () => {
            if (this.searchEntry.get_text().length > 0) {
                this.searchEntry.set_text("");
            }
        });
        this.popupBox.add_child(this.searchEntry);

        this.sectionLabel = new St.Label({
            style_class: "linuxium-search-section-title",
            text: _("Quick Launch")
        });
        this.popupBox.add_child(this.sectionLabel);

        this.resultsBox = new St.BoxLayout({
            vertical: true,
            style_class: "linuxium-search-results"
        });
        this.popupBox.add_child(this.resultsBox);

        this.entryText = this.searchEntry.clutter_text;
        this.entryText.connect("text-changed", () => {
            let text = this.searchEntry.get_text();
            this._entryIcon.set_icon_name(text.length > 0 ? "edit-clear-symbolic" : "edit-find-symbolic");
            this._updateResults(text);
        });
        this.entryText.connect("key-press-event", (_actor, event) => this._onKeyPress(event));

        this.menu.connect("open-state-changed", (_menu, isOpen) => {
            if (isOpen) {
                this.pillBox.add_style_class_name("linuxium-panel-search-active");
                this.searchEntry.set_text("");
                this._entryIcon.set_icon_name("edit-find-symbolic");
                this._updateResults("");
                global.stage.set_key_focus(this.searchEntry);
                Mainloop.idle_add(() => {
                    if (this.menu && this.menu.isOpen) {
                        global.stage.set_key_focus(this.searchEntry);
                    }
                    return GLib.SOURCE_REMOVE;
                });
            } else {
                this.pillBox.remove_style_class_name("linuxium-panel-search-active");
            }
        });

        try {
            Main.keybindingManager.addHotKey(this._hotkeyName, "<Super>s", () => {
                if (!Main.overview.visible && !Main.expo.visible) {
                    this.menu.toggle();
                }
            });
        } catch (e) {
            global.logWarning("search-bar@linuxium: could not bind Super+S hotkey: " + e);
        }
    }

    _syncOrientationLayout() {
        let vertical = (this._orientation === St.Side.LEFT || this._orientation === St.Side.RIGHT);
        if (vertical) {
            this.panelLabel.hide();
            this.pillBox.add_style_class_name("linuxium-panel-search-compact");
        } else {
            this.panelLabel.show();
            this.pillBox.remove_style_class_name("linuxium-panel-search-compact");
        }
    }

    on_orientation_changed(orientation) {
        this._orientation = orientation;
        this._syncOrientationLayout();
    }

    on_applet_clicked() {
        this.menu.toggle();
    }

    on_applet_removed_from_panel() {
        try {
            Main.keybindingManager.removeHotKey(this._hotkeyName);
        } catch (e) {
            // Ignore if never bound
        }
    }

    _isLiveBoot() {
        if (GLib.file_test("/run/live/medium", GLib.FileTest.IS_DIR)) {
            return true;
        }
        try {
            let [ok, contents] = GLib.file_get_contents("/proc/cmdline");
            if (ok && contents) {
                let cmdline = imports.byteArray.toString(contents);
                return cmdline.indexOf("boot=live") !== -1;
            }
        } catch (e) {
            // Fall through
        }
        return false;
    }

    _collectApps() {
        let liveBoot = this._isLiveBoot();
        let all = Gio.AppInfo.get_all();
        let items = [];
        for (let i = 0; i < all.length; i++) {
            let app = all[i];
            if (!app.should_show()) continue;
            let id = app.get_id() || "";
            if (!liveBoot && id === "install-linuxium.desktop") continue;
            let name = app.get_display_name() || app.get_name() || "";
            if (!name) continue;
            let desc = app.get_description() || "";
            let exe = app.get_executable() || "";
            let kw = "";
            if (typeof app.get_keywords === "function") {
                let klist = app.get_keywords();
                if (klist && klist.length) kw = klist.join(" ");
            }
            items.push({
                id: id,
                title: name,
                description: desc,
                searchBlob: (name + " " + desc + " " + exe + " " + kw).toLowerCase(),
                nameLower: name.toLowerCase(),
                gicon: app.get_icon(),
                iconName: "application-x-executable",
                activate: () => {
                    try {
                        app.launch([], null);
                    } catch (e) {
                        global.logError("search-bar@linuxium: failed to launch " + id + ": " + e);
                    }
                }
            });
        }
        return items;
    }

    _collectPlaces() {
        let home = GLib.get_home_dir();
        let defs = [
            [_("Home"), home, "user-home"],
            [_("Desktop"), GLib.build_filenamev([home, "Desktop"]), "user-desktop"],
            [_("Downloads"), GLib.build_filenamev([home, "Downloads"]), "folder-download"],
            [_("Documents"), GLib.build_filenamev([home, "Documents"]), "folder-documents"],
            [_("Pictures"), GLib.build_filenamev([home, "Pictures"]), "folder-pictures"],
            [_("Music"), GLib.build_filenamev([home, "Music"]), "folder-music"],
            [_("Videos"), GLib.build_filenamev([home, "Videos"]), "folder-videos"]
        ];
        let out = [];
        for (let i = 0; i < defs.length; i++) {
            let [label, path, iconName] = defs[i];
            if (!GLib.file_test(path, GLib.FileTest.IS_DIR)) continue;
            out.push({
                id: "place:" + path,
                title: label,
                description: path,
                nameLower: label.toLowerCase(),
                searchBlob: (label + " folder directory " + path).toLowerCase(),
                gicon: null,
                iconName: iconName,
                activate: () => {
                    Util.spawn(["nemo", path]);
                }
            });
        }
        return out;
    }

    _updateResults(rawQuery) {
        this.resultsBox.destroy_all_children();
        this._results = [];
        this._selectedIndex = 0;

        let query = (rawQuery || "").trim().toLowerCase();
        let apps = this._collectApps();

        if (!query) {
            this.sectionLabel.set_text(_("Quick Launch"));
            let byId = {};
            for (let i = 0; i < apps.length; i++) {
                if (apps[i].id) byId[apps[i].id] = apps[i];
            }
            let chosen = [];
            let used = {};
            for (let i = 0; i < QUICK_LAUNCH_IDS.length && chosen.length < MAX_RESULTS; i++) {
                let id = QUICK_LAUNCH_IDS[i];
                if (byId[id] && !used[id]) {
                    chosen.push(byId[id]);
                    used[id] = true;
                }
            }
            for (let i = 0; i < apps.length && chosen.length < MAX_RESULTS; i++) {
                let id = apps[i].id || apps[i].title;
                if (!used[id]) {
                    chosen.push(apps[i]);
                    used[id] = true;
                }
            }
            this._renderItems(chosen);
            return;
        }

        this.sectionLabel.set_text(_("Best Matches"));
        let scored = [];

        let mathAnswer = evaluateMath(rawQuery);
        if (mathAnswer !== null) {
            scored.push({
                score: 1000,
                item: {
                    id: "calc",
                    title: rawQuery.trim() + " = " + mathAnswer,
                    description: _("Press Enter to copy result to clipboard"),
                    gicon: null,
                    iconName: "accessories-calculator",
                    activate: () => {
                        St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, mathAnswer);
                    }
                }
            });
        }

        let candidates = apps.concat(this._collectPlaces());
        let tokens = query.split(/\s+/).filter(Boolean);

        for (let i = 0; i < candidates.length; i++) {
            let item = candidates[i];
            let allMatch = true;
            for (let t = 0; t < tokens.length; t++) {
                if (item.searchBlob.indexOf(tokens[t]) === -1) {
                    allMatch = false;
                    break;
                }
            }
            if (!allMatch) continue;

            let score = 10;
            if (item.nameLower === query) score = 500;
            else if (item.nameLower.indexOf(query) === 0) score = 350;
            else if (item.nameLower.indexOf(" " + query) !== -1) score = 250;
            else if (item.nameLower.indexOf(query) !== -1) score = 180;
            scored.push({ score: score, item: item });
        }

        scored.sort((a, b) => {
            if (b.score !== a.score) return b.score - a.score;
            return a.item.title.localeCompare(b.item.title);
        });

        let topItems = scored.slice(0, MAX_RESULTS).map(entry => entry.item);
        if (topItems.length === 0) {
            let emptyLabel = new St.Label({
                style_class: "linuxium-search-empty",
                text: _('No matches found for "%s"').format(rawQuery.trim())
            });
            this.resultsBox.add_child(emptyLabel);
            return;
        }

        this._renderItems(topItems);
    }

    _renderItems(items) {
        for (let i = 0; i < items.length; i++) {
            let item = items[i];
            let row = new St.BoxLayout({
                style_class: "linuxium-search-result",
                reactive: true,
                track_hover: true,
                x_expand: true
            });

            let iconActor;
            if (item.gicon) {
                iconActor = St.TextureCache.get_default().load_gicon(null, item.gicon, 28);
            } else {
                iconActor = new St.Icon({
                    icon_name: item.iconName || "application-x-executable",
                    icon_type: St.IconType.FULLCOLOR,
                    icon_size: 28
                });
            }
            iconActor.set_y_align(Clutter.ActorAlign.CENTER);
            row.add_child(iconActor);

            let textCol = new St.BoxLayout({
                vertical: true,
                y_align: Clutter.ActorAlign.CENTER,
                x_expand: true
            });
            let titleLabel = new St.Label({
                style_class: "linuxium-search-result-title",
                text: item.title
            });
            textCol.add_child(titleLabel);

            if (item.description) {
                let shortDesc = item.description.length > 56
                    ? item.description.slice(0, 55) + "\u2026"
                    : item.description;
                let descLabel = new St.Label({
                    style_class: "linuxium-search-result-desc",
                    text: shortDesc
                });
                textCol.add_child(descLabel);
            }
            row.add_child(textCol);

            let idx = i;
            row.connect("enter-event", () => {
                this._setSelectedIndex(idx);
            });
            row.connect("button-release-event", (_actor, event) => {
                if (event.get_button() === 1) {
                    this._activateIndex(idx);
                    return Clutter.EVENT_STOP;
                }
                return Clutter.EVENT_PROPAGATE;
            });

            this.resultsBox.add_child(row);
            this._results.push({ row: row, item: item });
        }
        this._setSelectedIndex(0);
    }

    _setSelectedIndex(index) {
        if (this._results.length === 0) return;
        let clamped = Math.max(0, Math.min(index, this._results.length - 1));
        this._selectedIndex = clamped;
        for (let i = 0; i < this._results.length; i++) {
            if (i === clamped) {
                this._results[i].row.add_style_class_name("linuxium-search-result-selected");
            } else {
                this._results[i].row.remove_style_class_name("linuxium-search-result-selected");
            }
        }
    }

    _activateIndex(index) {
        if (index < 0 || index >= this._results.length) return;
        let target = this._results[index].item;
        this.menu.close(true);
        target.activate();
    }

    _onKeyPress(event) {
        let symbol = event.get_key_symbol();
        if (symbol === Clutter.KEY_Escape) {
            this.menu.close(true);
            return Clutter.EVENT_STOP;
        }
        if (symbol === Clutter.KEY_Down || symbol === Clutter.KEY_Tab) {
            if (this._results.length > 0) {
                this._setSelectedIndex((this._selectedIndex + 1) % this._results.length);
            }
            return Clutter.EVENT_STOP;
        }
        if (symbol === Clutter.KEY_Up || symbol === Clutter.KEY_ISO_Left_Tab) {
            if (this._results.length > 0) {
                this._setSelectedIndex((this._selectedIndex - 1 + this._results.length) % this._results.length);
            }
            return Clutter.EVENT_STOP;
        }
        if (symbol === Clutter.KEY_Return || symbol === Clutter.KEY_KP_Enter) {
            if (this._results.length > 0) {
                this._activateIndex(this._selectedIndex);
            }
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new LinuxiumSearchBarApplet(metadata, orientation, panelHeight, instanceId);
}
EOF

# 5l. Desktop Clock & System Stats widgets (Cinnamon desklets: clock@linuxium
#     and stats@linuxium), styled to match CBlack and enabled by default in
#     dconf (section 6). Both auto-align cleanly to the top-right edge of the
#     primary monitor on any screen resolution until dragged by the user.
CLOCK_DESKLET_DIR="config/includes.chroot/usr/share/cinnamon/desklets/clock@linuxium"
mkdir -p "$CLOCK_DESKLET_DIR"

cat > "$CLOCK_DESKLET_DIR/metadata.json" <<'EOF'
{
  "uuid": "clock@linuxium",
  "name": "Linuxium Clock",
  "description": "Clean CBlack desktop clock and date widget",
  "icon": "preferences-system-time",
  "prevent-decorations": true,
  "max-instances": "10"
}
EOF

cat > "$CLOCK_DESKLET_DIR/stylesheet.css" <<'EOF'
.linuxium-clock-card {
    width: 248px;
    padding: 16px 20px;
    background-color: rgba(14, 14, 18, 0.84);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 14px;
}

.linuxium-clock-time-row {
    spacing: 8px;
}

.linuxium-clock-time {
    color: #f5f5f7;
    font-size: 28pt;
    font-weight: 700;
}

.linuxium-clock-sec {
    color: #8b5cf6;
    font-size: 11pt;
    font-weight: 700;
    padding-bottom: 5px;
}

.linuxium-clock-date {
    color: #a1a1aa;
    font-size: 10pt;
    font-weight: 500;
    padding-top: 4px;
}
EOF

cat > "$CLOCK_DESKLET_DIR/desklet.js" <<'EOF'
const Clutter = imports.gi.Clutter;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const St = imports.gi.St;
const Mainloop = imports.mainloop;
const Desklet = imports.ui.desklet;
const Main = imports.ui.main;
const Gettext = imports.gettext;

const UUID = "clock@linuxium";
const DEFAULT_SENTINEL_X = "740";
const DEFAULT_OFFSET_Y = 32;
const RIGHT_MARGIN_X = 284;

function _(str) {
    let translated = Gettext.dgettext(UUID, str);
    if (translated !== str) {
        return translated;
    }
    return Gettext.gettext(str);
}

class LinuxiumClockDesklet extends Desklet.Desklet {
    constructor(metadata, deskletId) {
        super(metadata, deskletId);
        this.setHeader(_("Clock"));

        this._timeoutId = 0;
        this._monitorsChangedId = 0;
        this._clockSettingId = 0;
        this._ifaceSettings = null;

        let card = new St.BoxLayout({
            vertical: true,
            style_class: "linuxium-clock-card"
        });
        let timeRow = new St.BoxLayout({
            vertical: false,
            style_class: "linuxium-clock-time-row",
            y_align: Clutter.ActorAlign.END
        });
        this._timeLabel = new St.Label({
            style_class: "linuxium-clock-time",
            text: "--:--",
            y_align: Clutter.ActorAlign.END
        });
        this._secLabel = new St.Label({
            style_class: "linuxium-clock-sec",
            text: ":00",
            y_align: Clutter.ActorAlign.END
        });
        timeRow.add_child(this._timeLabel);
        timeRow.add_child(this._secLabel);

        this._dateLabel = new St.Label({
            style_class: "linuxium-clock-date",
            text: ""
        });

        card.add_child(timeRow);
        card.add_child(this._dateLabel);
        this.setContent(card);

        try {
            this._ifaceSettings = new Gio.Settings({ schema_id: "org.cinnamon.desktop.interface" });
            this._clockSettingId = this._ifaceSettings.connect("changed::clock-use-24h", () => {
                this._updateClock();
            });
        } catch (e) {
            this._ifaceSettings = null;
        }

        this._menu.addSettingsAction(_("Date and Time Settings"), "calendar");
    }

    _use24h() {
        if (this._ifaceSettings) {
            try {
                return this._ifaceSettings.get_boolean("clock-use-24h");
            } catch (e) {
                return true;
            }
        }
        return true;
    }

    _syncPositionToMonitor() {
        let mon = Main.layoutManager && Main.layoutManager.primaryMonitor;
        if (!mon) return;

        let isDefaultPos = false;
        try {
            let list = global.settings.get_strv("enabled-desklets");
            let prefix = UUID + ":" + this.instance_id + ":";
            for (let i = 0; i < list.length; i++) {
                if (list[i].indexOf(prefix) === 0) {
                    let parts = list[i].split(":");
                    if (parts.length === 4 && parts[2] === DEFAULT_SENTINEL_X) {
                        isDefaultPos = true;
                    }
                    break;
                }
            }
        } catch (e) {
            isDefaultPos = false;
        }

        if (isDefaultPos) {
            let targetX = Math.max(mon.x + 24, mon.x + mon.width - RIGHT_MARGIN_X);
            let targetY = mon.y + DEFAULT_OFFSET_Y;
            this.actor.set_position(targetX, targetY);
        }
    }

    _updateClock() {
        let now = GLib.DateTime.new_now_local();
        if (!now) return true;

        if (this._use24h()) {
            this._timeLabel.set_text(now.format("%H:%M") || "");
            this._secLabel.set_text(now.format(":%S") || "");
        } else {
            this._timeLabel.set_text((now.format("%I:%M") || "").replace(/^0/, ""));
            this._secLabel.set_text(now.format("%p") || "");
        }
        let dateStr = (now.format("%A, %B %e") || "").replace(/\s+/g, " ").trim();
        this._dateLabel.set_text(dateStr);
        return true;
    }

    on_desklet_added_to_desktop() {
        this._updateClock();
        this._syncPositionToMonitor();
        if (this._timeoutId === 0) {
            this._timeoutId = Mainloop.timeout_add_seconds(1, () => this._updateClock());
        }
        if (this._monitorsChangedId === 0 && Main.layoutManager) {
            this._monitorsChangedId = Main.layoutManager.connect("monitors-changed", () => {
                this._syncPositionToMonitor();
            });
        }
    }

    on_desklet_removed() {
        if (this._timeoutId > 0) {
            Mainloop.source_remove(this._timeoutId);
            this._timeoutId = 0;
        }
        if (this._monitorsChangedId > 0 && Main.layoutManager) {
            Main.layoutManager.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }
        if (this._clockSettingId > 0 && this._ifaceSettings) {
            this._ifaceSettings.disconnect(this._clockSettingId);
            this._clockSettingId = 0;
        }
    }
}

function main(metadata, deskletId) {
    return new LinuxiumClockDesklet(metadata, deskletId);
}
EOF

STATS_DESKLET_DIR="config/includes.chroot/usr/share/cinnamon/desklets/stats@linuxium"
mkdir -p "$STATS_DESKLET_DIR"

cat > "$STATS_DESKLET_DIR/metadata.json" <<'EOF'
{
  "uuid": "stats@linuxium",
  "name": "Linuxium System Stats",
  "description": "Live CPU, memory, disk and uptime desktop widget",
  "icon": "utilities-system-monitor",
  "prevent-decorations": true,
  "max-instances": "10"
}
EOF

cat > "$STATS_DESKLET_DIR/stylesheet.css" <<'EOF'
.linuxium-stats-card {
    width: 248px;
    padding: 16px 20px;
    background-color: rgba(14, 14, 18, 0.84);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 14px;
    spacing: 10px;
}

.linuxium-stats-header-row {
    padding-bottom: 2px;
}

.linuxium-stats-title {
    color: #e4e4e7;
    font-size: 8.5pt;
    font-weight: 700;
}

.linuxium-stats-uptime {
    color: #8b5cf6;
    font-size: 8.5pt;
    font-weight: 600;
}

.linuxium-stat-group {
    spacing: 4px;
}

.linuxium-stat-label {
    color: #d4d4d8;
    font-size: 9pt;
    font-weight: 600;
}

.linuxium-stat-value {
    color: #a1a1aa;
    font-size: 8.5pt;
    font-weight: 500;
}

.linuxium-stat-track {
    background-color: rgba(255, 255, 255, 0.09);
    border-radius: 3px;
    height: 6px;
    width: 208px;
}

.linuxium-stat-fill {
    background-color: #8b5cf6;
    border-radius: 3px;
    height: 6px;
}

.linuxium-stat-fill-warn {
    background-color: #f59e0b;
    border-radius: 3px;
    height: 6px;
}

.linuxium-stat-fill-crit {
    background-color: #ef4444;
    border-radius: 3px;
    height: 6px;
}
EOF

cat > "$STATS_DESKLET_DIR/desklet.js" <<'EOF'
const ByteArray = imports.byteArray;
const Clutter = imports.gi.Clutter;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const St = imports.gi.St;
const Mainloop = imports.mainloop;
const Desklet = imports.ui.desklet;
const Main = imports.ui.main;
const Util = imports.misc.util;
const Gettext = imports.gettext;

const UUID = "stats@linuxium";
const DEFAULT_SENTINEL_X = "740";
const DEFAULT_OFFSET_Y = 168;
const RIGHT_MARGIN_X = 284;
const BAR_WIDTH_PX = 208;

function _(str) {
    let translated = Gettext.dgettext(UUID, str);
    if (translated !== str) {
        return translated;
    }
    return Gettext.gettext(str);
}

function readTextFile(path) {
    try {
        let [ok, bytes] = GLib.file_get_contents(path);
        if (!ok || !bytes) return "";
        if (typeof bytes === "string") return bytes;
        return ByteArray.toString(bytes);
    } catch (e) {
        return "";
    }
}

class LinuxiumStatsDesklet extends Desklet.Desklet {
    constructor(metadata, deskletId) {
        super(metadata, deskletId);
        this.setHeader(_("System Stats"));

        this._timeoutId = 0;
        this._warmupId = 0;
        this._monitorsChangedId = 0;
        this._prevCpuTotal = 0;
        this._prevCpuIdle = 0;

        let card = new St.BoxLayout({
            vertical: true,
            style_class: "linuxium-stats-card"
        });

        let headerRow = new St.BoxLayout({
            vertical: false,
            style_class: "linuxium-stats-header-row",
            x_expand: true
        });
        let titleLabel = new St.Label({
            style_class: "linuxium-stats-title",
            text: _("SYSTEM STATS"),
            x_expand: true,
            x_align: Clutter.ActorAlign.START
        });
        this._uptimeLabel = new St.Label({
            style_class: "linuxium-stats-uptime",
            text: "",
            x_align: Clutter.ActorAlign.END
        });
        headerRow.add_child(titleLabel);
        headerRow.add_child(this._uptimeLabel);
        card.add_child(headerRow);

        this._cpuMetric = this._createMetricRow(_("CPU"));
        this._ramMetric = this._createMetricRow(_("RAM"));
        this._diskMetric = this._createMetricRow(_("Disk"));

        card.add_child(this._cpuMetric.box);
        card.add_child(this._ramMetric.box);
        card.add_child(this._diskMetric.box);

        this.setContent(card);

        this._menu.addAction(_("Open System Monitor"), () => {
            Util.spawn(["gnome-system-monitor"]);
        });
    }

    _createMetricRow(labelText) {
        let group = new St.BoxLayout({
            vertical: true,
            style_class: "linuxium-stat-group"
        });
        let topRow = new St.BoxLayout({
            vertical: false,
            x_expand: true
        });
        let label = new St.Label({
            style_class: "linuxium-stat-label",
            text: labelText,
            x_expand: true,
            x_align: Clutter.ActorAlign.START
        });
        let value = new St.Label({
            style_class: "linuxium-stat-value",
            text: "0%",
            x_align: Clutter.ActorAlign.END
        });
        topRow.add_child(label);
        topRow.add_child(value);

        let track = new St.BoxLayout({
            vertical: false,
            style_class: "linuxium-stat-track"
        });
        let fill = new St.Bin({
            style_class: "linuxium-stat-fill",
            style: "width: 4px; height: 6px;"
        });
        track.add_child(fill);

        group.add_child(topRow);
        group.add_child(track);
        return { box: group, value: value, fill: fill };
    }

    _applyBar(metric, pct, text) {
        let clamped = Math.max(0, Math.min(100, Math.round(pct)));
        let px = Math.max(4, Math.round((BAR_WIDTH_PX * clamped) / 100));
        metric.value.set_text(text);
        metric.fill.style_class = clamped >= 90
            ? "linuxium-stat-fill-crit"
            : (clamped >= 75 ? "linuxium-stat-fill-warn" : "linuxium-stat-fill");
        metric.fill.style = "width: " + px + "px; height: 6px;";
    }

    _sampleCpuPercent() {
        let stat = readTextFile("/proc/stat");
        if (!stat) return 0;
        let firstLine = stat.split("\n")[0] || "";
        let parts = firstLine.trim().split(/\s+/);
        if (parts[0] !== "cpu" || parts.length < 5) return 0;

        let total = 0;
        for (let i = 1; i < parts.length; i++) {
            let v = parseInt(parts[i], 10);
            if (Number.isFinite(v)) total += v;
        }
        let idle = (parseInt(parts[4], 10) || 0) + (parseInt(parts[5], 10) || 0);

        let pct = 0;
        if (this._prevCpuTotal > 0 && total > this._prevCpuTotal) {
            let dTotal = total - this._prevCpuTotal;
            let dIdle = idle - this._prevCpuIdle;
            pct = ((dTotal - dIdle) / dTotal) * 100;
        } else if (total > 0) {
            pct = ((total - idle) / total) * 100;
        }
        this._prevCpuTotal = total;
        this._prevCpuIdle = idle;
        return Math.max(0, Math.min(100, pct));
    }

    _sampleRam() {
        let info = readTextFile("/proc/meminfo");
        if (!info) return { pct: 0, text: "0%" };
        let totalKiB = 0;
        let availKiB = 0;
        let freeKiB = 0;
        let buffersKiB = 0;
        let cachedKiB = 0;

        let lines = info.split("\n");
        for (let i = 0; i < lines.length; i++) {
            let m = lines[i].match(/^([A-Za-z_]+):\s+(\d+)/);
            if (!m) continue;
            let k = m[1];
            let v = parseInt(m[2], 10);
            if (k === "MemTotal") totalKiB = v;
            else if (k === "MemAvailable") availKiB = v;
            else if (k === "MemFree") freeKiB = v;
            else if (k === "Buffers") buffersKiB = v;
            else if (k === "Cached") cachedKiB = v;
        }
        if (totalKiB <= 0) return { pct: 0, text: "0%" };
        if (availKiB <= 0) availKiB = freeKiB + buffersKiB + cachedKiB;

        let usedKiB = Math.max(0, totalKiB - availKiB);
        let pct = (usedKiB / totalKiB) * 100;
        let usedGiB = (usedKiB / 1048576).toFixed(1);
        let totalGiB = (totalKiB / 1048576).toFixed(1);
        return {
            pct: pct,
            text: usedGiB + " / " + totalGiB + "G (" + Math.round(pct) + "%)"
        };
    }

    _sampleDisk() {
        try {
            let root = Gio.File.new_for_path("/");
            let fs = root.query_filesystem_info("filesystem::size,filesystem::free", null);
            let total = fs.get_attribute_uint64("filesystem::size");
            let free = fs.get_attribute_uint64("filesystem::free");
            if (total <= 0) return { pct: 0, text: "0%" };
            let used = Math.max(0, total - free);
            let pct = (used / total) * 100;
            let usedGB = (used / 1073741824).toFixed(1);
            let totalGB = (total / 1073741824).toFixed(0);
            return {
                pct: pct,
                text: usedGB + " / " + totalGB + "G (" + Math.round(pct) + "%)"
            };
        } catch (e) {
            return { pct: 0, text: "N/A" };
        }
    }

    _sampleUptime() {
        let up = readTextFile("/proc/uptime");
        if (!up) return "";
        let secs = Math.floor(parseFloat(up.trim().split(/\s+/)[0]) || 0);
        let days = Math.floor(secs / 86400);
        let hours = Math.floor((secs % 86400) / 3600);
        let mins = Math.floor((secs % 3600) / 60);
        if (days > 0) return "up " + days + "d " + hours + "h";
        if (hours > 0) return "up " + hours + "h " + mins + "m";
        return "up " + mins + "m";
    }

    _syncPositionToMonitor() {
        let mon = Main.layoutManager && Main.layoutManager.primaryMonitor;
        if (!mon) return;

        let isDefaultPos = false;
        try {
            let list = global.settings.get_strv("enabled-desklets");
            let prefix = UUID + ":" + this.instance_id + ":";
            for (let i = 0; i < list.length; i++) {
                if (list[i].indexOf(prefix) === 0) {
                    let parts = list[i].split(":");
                    if (parts.length === 4 && parts[2] === DEFAULT_SENTINEL_X) {
                        isDefaultPos = true;
                    }
                    break;
                }
            }
        } catch (e) {
            isDefaultPos = false;
        }

        if (isDefaultPos) {
            let targetX = Math.max(mon.x + 24, mon.x + mon.width - RIGHT_MARGIN_X);
            let targetY = mon.y + DEFAULT_OFFSET_Y;
            this.actor.set_position(targetX, targetY);
        }
    }

    _refreshStats() {
        let cpuPct = this._sampleCpuPercent();
        this._applyBar(this._cpuMetric, cpuPct, Math.round(cpuPct) + "%");

        let ram = this._sampleRam();
        this._applyBar(this._ramMetric, ram.pct, ram.text);

        let disk = this._sampleDisk();
        this._applyBar(this._diskMetric, disk.pct, disk.text);

        this._uptimeLabel.set_text(this._sampleUptime());
        return true;
    }

    on_desklet_added_to_desktop() {
        this._refreshStats();
        this._syncPositionToMonitor();
        if (this._warmupId === 0) {
            this._warmupId = Mainloop.timeout_add(600, () => {
                this._warmupId = 0;
                this._refreshStats();
                return false;
            });
        }
        if (this._timeoutId === 0) {
            this._timeoutId = Mainloop.timeout_add_seconds(2, () => this._refreshStats());
        }
        if (this._monitorsChangedId === 0 && Main.layoutManager) {
            this._monitorsChangedId = Main.layoutManager.connect("monitors-changed", () => {
                this._syncPositionToMonitor();
            });
        }
    }

    on_desklet_removed() {
        if (this._warmupId > 0) {
            Mainloop.source_remove(this._warmupId);
            this._warmupId = 0;
        }
        if (this._timeoutId > 0) {
            Mainloop.source_remove(this._timeoutId);
            this._timeoutId = 0;
        }
        if (this._monitorsChangedId > 0 && Main.layoutManager) {
            Main.layoutManager.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }
    }
}

function main(metadata, deskletId) {
    return new LinuxiumStatsDesklet(metadata, deskletId);
}
EOF

# 6. Default settings: Cinnamon wallpaper, CBlack + Papirus-Dark themes,
#    Lynx taskbar menu icon, Taskbar Search Bar applet, Clock & System Stats
#    desktop widgets, and desktop icons
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

[org/cinnamon/desktop/background/slideshow]
image-source='xml:///usr/share/gnome-background-properties/linuxium.xml'

[org/cinnamon/desktop/interface]
gtk-theme='CBlack'
icon-theme='Papirus-Dark'
cursor-theme='DMZ-Black'

[org/gnome/desktop/interface]
gtk-theme='CBlack'
icon-theme='Papirus-Dark'
cursor-theme='DMZ-Black'
color-scheme='prefer-dark'

[org/nemo/desktop]
show-desktop-icons=true

# Cinnamon SHELL theme. This key is only safe to set because CBlack
# (section 5j) really ships cinnamon/cinnamon.css - pointing it at a
# GTK-only theme such as Adwaita (which has no cinnamon/cinnamon.css)
# would leave the shell unthemed/broken, which is why this used to be
# left unset.
[org/cinnamon/theme]
name='CBlack'

# Window borders (Muffin/Metacity) are a THIRD, separate setting in
# Cinnamon - without this the titlebars stay on the default Adwaita
# borders while the shell and apps use CBlack. CBlack ships a
# metacity-1 theme (its index.theme declares MetacityTheme=CBlack).
[org/cinnamon/desktop/wm/preferences]
theme='CBlack'

# Taskbar layout & desktop widgets: Lynx menu icon on the far left,
# followed immediately by the Linuxium Search Bar applet, separator, and
# grouped window list; Clock + System Stats desklets enabled on the desktop.
[org/cinnamon]
app-menu-icon-name='linuxium'
app-menu-label=''
enabled-applets=['panel1:left:0:menu@cinnamon.org', 'panel1:left:1:search-bar@linuxium', 'panel1:left:2:separator@cinnamon.org', 'panel1:left:3:grouped-window-list@cinnamon.org', 'panel1:right:0:systray@cinnamon.org', 'panel1:right:1:xapp-status@cinnamon.org', 'panel1:right:2:notifications@cinnamon.org', 'panel1:right:3:printers@cinnamon.org', 'panel1:right:4:removable-drives@cinnamon.org', 'panel1:right:5:keyboard@cinnamon.org', 'panel1:right:6:favorites@cinnamon.org', 'panel1:right:7:network@cinnamon.org', 'panel1:right:8:sound@cinnamon.org', 'panel1:right:9:power@cinnamon.org', 'panel1:right:10:calendar@cinnamon.org', 'panel1:right:11:cornerbar@cinnamon.org']
enabled-desklets=['clock@linuxium:0:740:32', 'stats@linuxium:1:740:168']
favorite-apps=['firefox-esr.desktop', 'nemo.desktop', 'gimp.desktop', 'org.gnome.Terminal.desktop', 'cinnamon-settings.desktop', 'libreoffice-writer.desktop', 'vlc.desktop']
EOF

# Keep root/pkexec GTK3 tools (Calamares helpers, GParted, Synaptic, GDebi)
# matched to CBlack + Papirus-Dark as well.
mkdir -p config/includes.chroot/etc/gtk-3.0
cat > config/includes.chroot/etc/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-theme-name=CBlack
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=DMZ-Black
gtk-application-prefer-dark-theme=1
EOF

# 7. Login screen background
mkdir -p config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d/50-linuxium.conf <<'EOF'
[greeter]
background=/usr/share/backgrounds/linuxium/linuxium.png
user-background=false
# Match the session theme (section 5j/6); dconf defaults do not apply
# to the greeter's own user, so set its GTK/icon/cursor themes explicitly.
theme-name=CBlack
icon-theme-name=Papirus-Dark
cursor-theme-name=DMZ-Black
# Put the login window on the monitor that actually has the pointer;
# harmless on one screen, avoids an "empty" looking second screen in VMs.
active-monitor=#cursor
EOF

# 8. Live user gets autologin into Cinnamon. The [LightDM] guards are
# static on purpose: they must survive into an installed system too.
# NOTE: logind-check-graphical=false is safe ONLY because section 8a
# installs /etc/systemd/system/lightdm.service.d/50-linuxium.conf and
# /usr/sbin/linuxium-wait-graphics, which order LightDM after
# systemd-logind + udev coldplug and wait for the simpledrm -> real KMS
# GPU handoff before Xorg probes /dev/dri/card*.
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/50-linuxium.conf <<'EOF'
[LightDM]
logind-check-graphical=false
start-default-seat=true

[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=cinnamon
EOF

# 8a. Permanent boot/graphics safeguards (present in the live image AND
# in an installed system):
#
#  1. Early-boot graphics readiness + clean Plymouth-to-Xorg handoff:
#     Debian compiles Plymouth with --with-boot-tty=/dev/tty7, while
#     Bookworm's lightdm.service declares Conflicts=plymouth-quit.service.
#     When LightDM starts while plymouthd is still running on VT7,
#     LightDM calls "plymouth deactivate" instead of "plymouth quit",
#     leaving plymouthd alive with its 32bpp dumb buffers pinned in VRAM
#     (exhausting 16 MiB VM VRAM bars on bochs-drm/vboxvideo/vmwgfx),
#     leaving VT7 in KD_GRAPHICS mode, and leaving plymouth-quit-wait
#     (TimeoutSec=0) blocked forever if Xorg stalls or fails.
#     /usr/sbin/linuxium-wait-graphics waits (bounded) for udev + KMS
#     handoff, refreshes session selection once /dev/dri/* has settled,
#     and cleanly quits plymouthd right before LightDM spawns Xorg.
#     Drop-ins also bound live-config.service (90s), plymouth-quit-wait
#     (30s) and LightDM retries (5 attempts / 60s, RestartSec=2s) with
#     an OnFailure VT1 getty fallback so no boot can hang on the splash.
#
#  2. Xorg OutputClass rules for non-3D / small-VRAM KMS drivers
#     (vboxvideo, bochs-drm, cirrus, hyperv_drm, simpledrm, mgag200, ast)
#     using modesetting + ShadowFB with AccelMethod=none, PageFlip=false
#     and SWcursor=true so glamor/kms_swrast cannot exhaust small VRAM
#     bars or stall page flips. Crucially, vmwgfx and qxl are NOT matched
#     here so VMware / VirtualBox VMSVGA keep xserver-xorg-video-vmware
#     and SPICE/QXL keeps xserver-xorg-video-qxl.
#
#  3. Automatic software-rendering session safeguard
#     (/usr/sbin/linuxium-virtualbox-graphics) that selects cinnamon2d
#     whenever booting in a VM without hardware 3D / VirGL or on any
#     system without a /dev/dri/renderD* 3D render node, while keeping
#     full hardware-accelerated cinnamon on real Intel/AMD/NVIDIA GPUs.
mkdir -p config/includes.chroot/usr/sbin
cat > config/includes.chroot/usr/sbin/linuxium-wait-graphics <<'EOF'
#!/bin/sh
# Linuxium: wait (with strict upper bounds) for udev GPU coldplug,
# simpledrm -> native KMS handoff, and systemd-logind seat readiness,
# refresh the Cinnamon 3D/2D session choice once /dev/dri/* is settled,
# and cleanly quit Plymouth so VT7 and VRAM are 100% free before LightDM
# spawns Xorg. Every code path exits 0.

cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
nomodeset=0
for param in $cmdline
do
	case "$param" in
		nomodeset|*.modeset=0)
			nomodeset=1
			;;
	esac
done

if command -v udevadm >/dev/null 2>&1
then
	udevadm settle --timeout=8 >/dev/null 2>&1 || true
fi

has_non_simpledrm_card()
{
	for card in /sys/class/drm/card[0-9]*
	do
		[ -e "$card" ] || continue
		case "${card##*/}" in
			*-*) continue ;;
		esac
		devnode="/dev/dri/${card##*/}"
		[ -c "$devnode" ] || continue
		drv="$(readlink "$card/device/driver" 2>/dev/null || true)"
		drv="${drv##*/}"
		if [ -n "$drv" ] && [ "$drv" != "simpledrm" ] && [ "$drv" != "simple-framebuffer" ]
		then
			return 0
		fi
	done
	return 1
}

has_any_drm_card()
{
	for devnode in /dev/dri/card[0-9]*
	do
		[ -c "$devnode" ] && return 0
	done
	return 1
}

has_unbound_pci_display()
{
	for pci_class in /sys/bus/pci/devices/*/class
	do
		[ -r "$pci_class" ] || continue
		cls="$(cat "$pci_class" 2>/dev/null || true)"
		case "$cls" in
			0x03*)
				pci_dir="${pci_class%/class}"
				[ ! -e "$pci_dir/driver" ] && return 0
				;;
		esac
	done
	return 1
}

if [ "$nomodeset" = "0" ]
then
	# Poll up to 5s (25 * 0.2s) if a real KMS card is still replacing
	# simpledrm or creating /dev/dri/card*. Break immediately (0s sleep)
	# once a real KMS card node exists.
	i=0
	while [ "$i" -lt 25 ]
	do
		if has_non_simpledrm_card
		then
			break
		fi
		if has_any_drm_card && ! has_unbound_pci_display && [ "$i" -ge 5 ]
		then
			# simpledrm is present and no unbound PCI GPU is waiting
			# on a driver; 1s grace period is enough.
			break
		fi
		if ! has_any_drm_card && ! has_unbound_pci_display && [ "$i" -ge 10 ]
		then
			break
		fi
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i + 1))
	done

	if [ "$i" -gt 0 ] && command -v udevadm >/dev/null 2>&1
	then
		udevadm settle --timeout=2 >/dev/null 2>&1 || true
	fi
fi

# Give systemd-logind up to 2s to process udev's master-of-seat tag on
# KMS systems so seat0 is fully ready when LightDM connects.
if has_any_drm_card && command -v loginctl >/dev/null 2>&1
then
	i=0
	while [ "$i" -lt 10 ]
	do
		can_gfx="$(loginctl show-seat seat0 -p CanGraphical --value 2>/dev/null || true)"
		[ "$can_gfx" = "yes" ] && break
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i + 1))
	done
fi

# Re-evaluate 3D vs software-rendered Cinnamon now that udev and KMS
# driver binding (/dev/dri/card*, /dev/dri/renderD*) have settled.
if [ -x /usr/sbin/linuxium-virtualbox-graphics ]
then
	/usr/sbin/linuxium-virtualbox-graphics >/dev/null 2>&1 || true
fi

# Cleanly terminate Plymouth right before LightDM starts Xorg so
# plymouthd releases DRM master, frees its 32bpp KMS dumb buffers in
# VRAM, restores /dev/tty7 to KD_TEXT, and unblocks plymouth-quit-wait.
if [ -x /bin/plymouth ] && /bin/plymouth --ping >/dev/null 2>&1
then
	/bin/plymouth quit >/dev/null 2>&1 || true
	i=0
	while [ "$i" -lt 15 ] && /bin/plymouth --ping >/dev/null 2>&1
	do
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	if /bin/plymouth --ping >/dev/null 2>&1
	then
		pkill -TERM -x plymouthd >/dev/null 2>&1 || killall -TERM plymouthd >/dev/null 2>&1 || true
		sleep 0.2 2>/dev/null || sleep 1
		pkill -KILL -x plymouthd >/dev/null 2>&1 || killall -KILL plymouthd >/dev/null 2>&1 || true
	fi
	rm -f /run/plymouth/pid >/dev/null 2>&1 || true
fi

exit 0
EOF
chmod +x config/includes.chroot/usr/sbin/linuxium-wait-graphics

mkdir -p config/includes.chroot/etc/systemd/system/lightdm.service.d
cat > config/includes.chroot/etc/systemd/system/lightdm.service.d/50-linuxium.conf <<'EOF'
[Unit]
Wants=dbus.service systemd-logind.service systemd-udev-trigger.service
After=dbus.service systemd-logind.service systemd-udev-trigger.service systemd-user-sessions.service linuxium-virtualbox-graphics.service
OnFailure=linuxium-boot-fallback-vt.service
StartLimitIntervalSec=60s
StartLimitBurst=5

[Service]
ExecStartPre=-/usr/sbin/linuxium-wait-graphics
RestartSec=2s
EOF

mkdir -p config/includes.chroot/etc/systemd/system/plymouth-quit-wait.service.d
cat > config/includes.chroot/etc/systemd/system/plymouth-quit-wait.service.d/50-linuxium.conf <<'EOF'
[Service]
TimeoutStartSec=30s
ExecStopPost=-/bin/plymouth quit
EOF

mkdir -p config/includes.chroot/etc/systemd/system/live-config.service.d
cat > config/includes.chroot/etc/systemd/system/live-config.service.d/50-linuxium.conf <<'EOF'
[Service]
TimeoutStartSec=90s
EOF

cat > config/includes.chroot/etc/systemd/system/linuxium-boot-fallback-vt.service <<'EOF'
[Unit]
Description=Linuxium console fallback if display manager fails to start
DefaultDependencies=no
After=plymouth-quit.service

[Service]
Type=oneshot
ExecStart=-/bin/plymouth quit
ExecStart=-/usr/bin/pkill -TERM -x plymouthd
ExecStart=-/bin/kbd_mode -a -C /dev/tty1
ExecStart=-/bin/chvt 1
ExecStart=-/bin/systemctl --no-block start getty@tty1.service
EOF

mkdir -p config/includes.chroot/etc/X11/xorg.conf.d
cat > config/includes.chroot/etc/X11/xorg.conf.d/20-linuxium-vm-kms.conf <<'EOF'
# Linuxium: non-3D / small-VRAM KMS drivers have no hardware 3D engine;
# run modesetting with ShadowFB, software cursor, AccelMethod=none and
# PageFlip=false so glamor/kms_swrast cannot exhaust 4-16 MiB VM/BMC
# VRAM bars or stall page flips.
# (vmwgfx and qxl are intentionally NOT matched here so VMware and
# VirtualBox VMSVGA keep xserver-xorg-video-vmware and SPICE/QXL keeps
# xserver-xorg-video-qxl.)
Section "OutputClass"
	Identifier	"Linuxium Non-3D KMS Safe Modesetting"
	MatchDriver	"vboxvideo|bochs-drm|cirrus|hyperv_drm|simpledrm|mgag200|ast"
	Driver		"modesetting"
	Option		"AccelMethod" "none"
	Option		"ShadowFB" "true"
	Option		"PageFlip" "false"
	Option		"SWcursor" "true"
EndSection
EOF
cat > config/includes.chroot/usr/sbin/linuxium-virtualbox-graphics <<'EOF'
#!/bin/sh
# Linuxium: select Cinnamon's software-rendering session (cinnamon2d)
# automatically in virtual machines lacking hardware 3D / VirGL and on
# systems without a usable /dev/dri/renderD* 3D render node, while
# keeping hardware-accelerated cinnamon on real 3D GPUs.
# Every code path exits 0 so this can never block a boot.

CONF="/etc/lightdm/lightdm.conf.d/91-linuxium-virtualbox.conf"
MAIN_CONF="/etc/lightdm/lightdm.conf"
MARKER="# Managed by linuxium-virtualbox-graphics; safe to delete."
BLOCK_BEGIN="# BEGIN Linuxium VM graphics session override"
BLOCK_END="# END Linuxium VM graphics session override"
TMP_MAIN=""

remove_managed_config()
{
	if [ -f "$CONF" ] && grep -q "^$MARKER" "$CONF" 2>/dev/null
	then
		rm -f "$CONF" 2>/dev/null || true
	fi
}

cleanup_tmp_main()
{
	if [ -n "$TMP_MAIN" ]
	then
		rm -f "$TMP_MAIN" 2>/dev/null || true
		TMP_MAIN=""
	fi
}

# LightDM reads /etc/lightdm/lightdm.conf after every .conf.d drop-in.
# Calamares writes user-session=cinnamon there, so a drop-in alone does
# not reliably select the safe session on an installed system. Maintain
# one marked duplicate [Seat:*] block at the end of the main file; the
# original settings stay in place and return when the block is removed.
prepare_main_copy()
{
	cleanup_tmp_main
	TMP_MAIN="$(mktemp "${MAIN_CONF}.linuxium.XXXXXX" 2>/dev/null)" || {
		TMP_MAIN=""
		return 1
	}

	if [ -f "$MAIN_CONF" ]
	then
		if ! awk -v block_begin="$BLOCK_BEGIN" -v block_end="$BLOCK_END" '
			$0 == block_begin { skip = 1; next }
			skip && $0 == block_end { skip = 0; next }
			!skip { lines[++n] = $0 }
			END {
				# Drop trailing blank lines too: write_main_override adds
				# one blank separator before the block, and stripping only
				# the block would leave it behind, growing the file by a
				# blank line on every VM/non-VM transition.
				while (n > 0 && lines[n] == "") n--
				for (i = 1; i <= n; i++) print lines[i]
			}
		' "$MAIN_CONF" > "$TMP_MAIN" 2>/dev/null
		then
			cleanup_tmp_main
			return 1
		fi
		chmod --reference="$MAIN_CONF" "$TMP_MAIN" 2>/dev/null || \
			chmod 644 "$TMP_MAIN" 2>/dev/null || true
		chown --reference="$MAIN_CONF" "$TMP_MAIN" 2>/dev/null || true
	else
		chmod 644 "$TMP_MAIN" 2>/dev/null || true
	fi

	return 0
}

commit_main_copy()
{
	[ -n "$TMP_MAIN" ] || return 1
	if mv "$TMP_MAIN" "$MAIN_CONF" 2>/dev/null
	then
		TMP_MAIN=""
		return 0
	fi
	cleanup_tmp_main
	return 1
}

remove_main_override()
{
	[ -f "$MAIN_CONF" ] || return 0
	grep -Fqx "$BLOCK_BEGIN" "$MAIN_CONF" 2>/dev/null || return 0
	prepare_main_copy || return 1
	commit_main_copy
}

write_main_override()
{
	mkdir -p "$(dirname "$MAIN_CONF")" 2>/dev/null || return 1
	prepare_main_copy || return 1
	if ! {
		printf '\n%s\n' "$BLOCK_BEGIN"
		echo "[Seat:*]"
		echo "user-session=$session"
		echo "autologin-session=$session"
		printf '%s\n' "$BLOCK_END"
	} >> "$TMP_MAIN" 2>/dev/null
	then
		cleanup_tmp_main
		return 1
	fi
	commit_main_copy
}

has_render_node()
{
	for rnode in /dev/dri/renderD[0-9]*
	do
		[ -c "$rnode" ] && return 0
	done
	return 1
}

has_hardware_3d_gpu()
{
	has_render_node || return 1

	for card in /sys/class/drm/card[0-9]*
	do
		[ -e "$card" ] || continue
		case "${card##*/}" in
			*-*) continue ;;
		esac
		drv="$(readlink "$card/device/driver" 2>/dev/null || true)"
		drv="${drv##*/}"
		case "$drv" in
			i915|xe|amdgpu|radeon|nouveau|nvidia|nvidia-drm|vc4|v3d|panfrost|lima|etnaviv|msm|tegra|vmwgfx)
				return 0
				;;
			virtio_gpu|virtio-pci)
				# VirtIO GPU feature bit 0 (VIRTIO_GPU_F_VIRGL) is emitted
				# as the first character of /sys/class/drm/cardN/device/features.
				if [ -r "$card/device/features" ]
				then
					features="$(cat "$card/device/features" 2>/dev/null || true)"
					case "$features" in
						1*) return 0 ;;
					esac
				fi
				;;
		esac
	done

	return 1
}

is_virtual_machine()
{
	virt="$(systemd-detect-virt --vm 2>/dev/null || systemd-detect-virt 2>/dev/null || true)"
	case "$virt" in
		""|none)
			;;
		*)
			return 0
			;;
	esac

	for dmi in product_name sys_vendor board_vendor
	do
		if grep -Eqis "virtualbox|vmware|qemu|kvm|bochs|virtual machine|xen|parallels|bhyve" \
			"/sys/devices/virtual/dmi/id/$dmi" 2>/dev/null
		then
			return 0
		fi
	done

	return 1
}

cmdline="$(cat /proc/cmdline 2>/dev/null || true)"

needs_software_session()
{
	for param in $cmdline
	do
		case "$param" in
			nomodeset|*.modeset=0|live-config.xorg-driver=vesa|xorg-driver=vesa|live-config.xorg-driver=fbdev|xorg-driver=fbdev)
				return 0
				;;
		esac
	done

	if is_virtual_machine
	then
		# Keep hardware 3D in a VM only when a real physical GPU is
		# passed through or VirtIO-GPU has VirGL 3D enabled.
		has_hardware_3d_gpu && return 1
		return 0
	fi

	# Bare metal without a 3D DRM render node (e.g. UEFI simpledrm,
	# efifb/vesafb, or 2D server BMC graphics like ast/mgag200) must
	# also use cinnamon2d so Clutter/Muffin does not stall or blank.
	has_render_node || return 0

	for card in /sys/class/drm/card[0-9]*
	do
		[ -e "$card" ] || continue
		case "${card##*/}" in
			*-*) continue ;;
		esac
		drv="$(readlink "$card/device/driver" 2>/dev/null || true)"
		drv="${drv##*/}"
		case "$drv" in
			""|simpledrm|simple-framebuffer|bochs-drm|vboxvideo|qxl|cirrus|hyperv_drm|mgag200|ast|udl)
				;;
			*)
				return 1
				;;
		esac
	done

	return 0
}

session=""

# An explicit boot choice wins over automatic detection.
for parameter in $cmdline
do
	case "$parameter" in
		linuxium.session=*|linuxium-session=*)
			session="${parameter#*=}"
			;;
		linuxium.software-rendering|linuxium-software-rendering)
			session="cinnamon2d"
			;;
		linuxium.force-3d|linuxium-force-3d)
			session="cinnamon"
			;;
	esac
done

if [ -z "$session" ] && needs_software_session
then
	session="cinnamon2d"
fi

case "$session" in
	cinnamon|cinnamon2d)
		;;
	*)
		remove_main_override || true
		remove_managed_config
		exit 0
		;;
esac

# Prefer the configuration location LightDM reads last. Keep the older
# drop-in below only as a best-effort fallback (it still governs the
# autologin session on a system where the main file cannot be updated).
if write_main_override
then
	remove_managed_config
	exit 0
fi

mkdir -p "$(dirname "$CONF")" 2>/dev/null || exit 0
tmp="$CONF.tmp.$$"
if {
	echo "$MARKER"
	echo "[Seat:*]"
	echo "user-session=$session"
	echo "autologin-session=$session"
} > "$tmp" 2>/dev/null
then
	chmod 644 "$tmp" 2>/dev/null || true
	mv "$tmp" "$CONF" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
	rm -f "$tmp" 2>/dev/null || true
fi

exit 0
EOF
chmod +x config/includes.chroot/usr/sbin/linuxium-virtualbox-graphics

mkdir -p config/includes.chroot/etc/systemd/system/multi-user.target.wants
cat > config/includes.chroot/etc/systemd/system/linuxium-virtualbox-graphics.service <<'EOF'
[Unit]
Description=Linuxium VM and non-3D graphics session safeguard
After=local-fs.target
Before=display-manager.service lightdm.service
ConditionPathExists=/usr/sbin/lightdm

[Service]
Type=oneshot
ExecStart=/usr/sbin/linuxium-virtualbox-graphics
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../linuxium-virtualbox-graphics.service \
  config/includes.chroot/etc/systemd/system/multi-user.target.wants/linuxium-virtualbox-graphics.service

# 8b. Live-only graphics safety net (runs at live boot via live-config;
#     it writes only to the live overlay, never into an installed system).
#
# Virtual machines without hardware 3D / VirGL and non-3D framebuffers
# need Cinnamon's software-rendering session ("cinnamon2d") so Muffin
# runs with CLUTTER_PAINT=disable-culling and LIBGL_ALWAYS_SOFTWARE=1.
# Session selection itself is delegated to /usr/sbin/linuxium-virtualbox-graphics
# (and re-run inside linuxium-wait-graphics once udev/KMS settle), while
# this live-config component:
#   * configures live autologin and LightDM seat defaults in
#     /etc/lightdm/lightdm.conf.d/90-linuxium-live.conf (honouring any
#     explicit linuxium-session= / noautologin / username= boot options);
#   * maintains /etc/X11/xorg.conf.d/20-linuxium-vm-kms.conf across
#     persistent live boots, hiding it only when the user explicitly
#     requested another X driver or nomodeset;
#   * disables idle screen blanking and screensaver locking in the live
#     session so the live desktop never locks with a hidden password
#     mid-install;
#   * keeps logind-check-graphical=false paired with linuxium-wait-graphics.
# Real 3D hardware keeps the accelerated "cinnamon" session. To force 3D
# inside a VM anyway, boot with:  linuxium-session=cinnamon
LIVE_CFG_DIR="config/includes.chroot/lib/live/config"
mkdir -p "$LIVE_CFG_DIR"
cat > "$LIVE_CFG_DIR/0190-linuxium-graphics" <<'LIVEEOF'
#!/bin/sh

. /lib/live/config.sh

#set -e

LINUXIUM_SESSION=""
LINUXIUM_XORG_DRIVER=""
LINUXIUM_NOMODESET=""
LINUXIUM_NOAUTOLOGIN=""
LINUXIUM_LIVE_USER="${LIVE_USERNAME:-linuxium}"

Cmdline ()
{
	for _PARAMETER in ${LIVE_CONFIG_CMDLINE}
	do
		case "${_PARAMETER}" in
			linuxium.session=*|linuxium-session=*)
				LINUXIUM_SESSION="${_PARAMETER#*=}"
				;;

			linuxium.software-rendering|linuxium-software-rendering)
				LINUXIUM_SESSION="cinnamon2d"
				;;

			linuxium.force-3d|linuxium-force-3d)
				LINUXIUM_SESSION="cinnamon"
				;;

			live-config.xorg-driver=*|xorg-driver=*)
				LINUXIUM_XORG_DRIVER="${_PARAMETER#*=}"
				;;

			nomodeset|*.modeset=0)
				LINUXIUM_NOMODESET="true"
				;;

			live-config.noautologin|noautologin|live-config.nox11autologin|nox11autologin)
				LINUXIUM_NOAUTOLOGIN="true"
				;;

			live-config.username=*|username=*)
				LINUXIUM_LIVE_USER="${_PARAMETER#*username=}"
				;;
		esac
	done
}

Init ()
{
	# Intentionally do not stop at component_was_executed: on a
	# persistent live medium, the state file and generated files survive
	# into later boots, while nomodeset / linuxium-session choices can
	# change. Re-applying this small idempotent configuration each live
	# boot makes the current boot line authoritative.
	if ! pkg_is_installed "lightdm"
	then
		exit 0
	fi

	printf '%s' " linuxium-graphics"
}

Config ()
{
	case "${LINUXIUM_SESSION}" in
		cinnamon|cinnamon2d|"")
			;;

		*)
			LINUXIUM_SESSION=""
			;;
	esac

	mkdir -p /etc/lightdm/lightdm.conf.d
	{
		echo "[LightDM]"
		# Do not gate the greeter on logind's CanGraphical flag: on some
		# non-KMS / nomodeset graphics stacks it never flips true and
		# LightDM simply waits forever. KMS coldplug + simpledrm handoff
		# synchronization is handled by linuxium-wait-graphics before
		# lightdm.service starts.
		echo "logind-check-graphical=false"
		echo "start-default-seat=true"
		echo ""
		echo "[Seat:*]"
		echo "greeter-session=lightdm-gtk-greeter"
		if [ -z "${LINUXIUM_NOAUTOLOGIN}" ] && [ -n "${LINUXIUM_LIVE_USER}" ]
		then
			echo "autologin-user=${LINUXIUM_LIVE_USER}"
			echo "autologin-user-timeout=0"
		fi
		if [ -n "${LINUXIUM_SESSION}" ]
		then
			echo "user-session=${LINUXIUM_SESSION}"
			echo "autologin-session=${LINUXIUM_SESSION}"
		fi
	} > /etc/lightdm/lightdm.conf.d/90-linuxium-live.conf

	if [ -x /usr/sbin/linuxium-virtualbox-graphics ]
	then
		/usr/sbin/linuxium-virtualbox-graphics >/dev/null 2>&1 || true
	fi

	# X-driver choice itself is handled by the permanent, race-free
	# OutputClass file installed in /etc/X11/xorg.conf.d. Hide it for
	# this live boot only if the user explicitly chose another X driver
	# (handled by stock component 1140) or booted with nomodeset, where
	# Xorg's firmware-framebuffer fallback should be left alone.
	# Otherwise write it back: on a persistent live medium, a previous
	# failsafe boot's deletion is a whiteout that would otherwise make
	# the VM workaround disappear from every later normal boot too.
	_XORG_VM_CONF="/etc/X11/xorg.conf.d/20-linuxium-vm-kms.conf"
	if [ -n "${LINUXIUM_XORG_DRIVER}" ] || [ -n "${LINUXIUM_NOMODESET}" ]
	then
		rm -f "${_XORG_VM_CONF}"
	else
		mkdir -p "$(dirname "${_XORG_VM_CONF}")"
		cat > "${_XORG_VM_CONF}" <<'XORGEOF'
# Linuxium: non-3D / small-VRAM KMS drivers have no hardware 3D engine;
# run modesetting with ShadowFB, software cursor, AccelMethod=none and
# PageFlip=false so glamor/kms_swrast cannot exhaust 4-16 MiB VM/BMC
# VRAM bars or stall page flips.
# (vmwgfx and qxl are intentionally NOT matched here so VMware and
# VirtualBox VMSVGA keep xserver-xorg-video-vmware and SPICE/QXL keeps
# xserver-xorg-video-qxl.)
Section "OutputClass"
	Identifier	"Linuxium Non-3D KMS Safe Modesetting"
	MatchDriver	"vboxvideo|bochs-drm|cirrus|hyperv_drm|simpledrm|mgag200|ast"
	Driver		"modesetting"
	Option		"AccelMethod" "none"
	Option		"ShadowFB" "true"
	Option		"PageFlip" "false"
	Option		"SWcursor" "true"
EndSection
XORGEOF
	fi

	# Stock component 1140 writes zz-live-config_xserver-xorg.conf only
	# for an explicit driver choice on this image, then is state-gated.
	# If this boot made no such choice, remove a copy left by an earlier
	# persistent-live boot; a stale forced driver must not override the
	# current normal auto-detection or failsafe framebuffer fallback.
	if [ -z "${LINUXIUM_XORG_DRIVER}" ]
	then
		rm -f /etc/X11/xorg.conf.d/zz-live-config_xserver-xorg.conf
	fi

	# Cinnamon activates a locked screensaver after 15 idle minutes by
	# default. In a live session that can cover the installer, look like
	# a hung/black desktop, and ask for the preset live password the user
	# was never told. Mirror Debian Calamares' GNOME live override: make
	# the live session never idle and disable idle screensaver activation
	# and locking in the live overlay. An installed system keeps
	# Cinnamon's secure defaults.
	mkdir -p /etc/dconf/db/local.d
	cat > /etc/dconf/db/local.d/90-linuxium-live <<'DCONFEOF'
[org/cinnamon/desktop/session]
idle-delay=uint32 0

[org/cinnamon/desktop/screensaver]
idle-activation-enabled=false
lock-enabled=false
DCONFEOF
	if command -v dconf >/dev/null 2>&1
	then
		dconf update 2>/dev/null || true
	fi

	# Unlock administrative actions (Calamares installer via pkexec,
	# GParted, Synaptic, GDebi, Disks, drive mounting) in the LIVE session
	# only. Bookworm's live-config + polkitd 122 otherwise prompts for the
	# hidden live password ("live") when starting Calamares (Debian bug
	# #1037295). Installed systems never run live-config and keep standard
	# Polkit authentication.
	for _PK_DIR in /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d
	do
		[ -d "${_PK_DIR}" ] || mkdir -p "${_PK_DIR}"
		cat > "${_PK_DIR}/49-linuxium-live.rules" <<POLKITEOF
// Live session only: allow the live user / sudo group to run administrative
// tools (Calamares installer, partition tools, package managers) without a
// Polkit password lock.
polkit.addRule(function(action, subject) {
	if (subject.local && subject.active &&
	    (subject.user === "${LINUXIUM_LIVE_USER}" || subject.isInGroup("sudo"))) {
		return polkit.Result.YES;
	}
});
POLKITEOF
		chmod 0644 "${_PK_DIR}/49-linuxium-live.rules" 2>/dev/null || true
	done

	# Populate the live user's Desktop with unlocked, trusted launchers for
	# Install Linuxium, the File Browser (Nemo) and Firefox. Nemo shows a
	# padlock emblem (emblem-readonly) if a ~/Desktop file is not writable
	# by the logged-in user and requires the executable bit (0755) to treat
	# launchers as trusted. Resolve numeric UID:GID explicitly so ownership
	# always matches the live user cleanly.
	if [ -n "${LINUXIUM_LIVE_USER}" ]
	then
		_LIVE_HOME="$(getent passwd "${LINUXIUM_LIVE_USER}" 2>/dev/null | cut -d: -f6 || true)"
		if [ -z "${_LIVE_HOME}" ] && [ -d "/home/${LINUXIUM_LIVE_USER}" ]
		then
			_LIVE_HOME="/home/${LINUXIUM_LIVE_USER}"
		fi
		if [ -n "${_LIVE_HOME}" ] && [ -d "${_LIVE_HOME}" ]
		then
			mkdir -p "${_LIVE_HOME}/Desktop"
			chmod 0755 "${_LIVE_HOME}/Desktop" 2>/dev/null || true
			for _DESK_APP in linuxium-experience.desktop install-linuxium.desktop nemo.desktop firefox-esr.desktop
			do
				if [ -f "/usr/share/applications/${_DESK_APP}" ]
				then
					cp -f "/usr/share/applications/${_DESK_APP}" "${_LIVE_HOME}/Desktop/${_DESK_APP}"
					chmod 0755 "${_LIVE_HOME}/Desktop/${_DESK_APP}"
				fi
			done
			_LIVE_UID="$(id -u "${LINUXIUM_LIVE_USER}" 2>/dev/null || true)"
			_LIVE_GID="$(id -g "${LINUXIUM_LIVE_USER}" 2>/dev/null || true)"
			if [ -n "${_LIVE_UID}" ] && [ -n "${_LIVE_GID}" ]
			then
				chown -R "${_LIVE_UID}:${_LIVE_GID}" "${_LIVE_HOME}/Desktop" 2>/dev/null || true
			else
				chown -R "${LINUXIUM_LIVE_USER}:${LINUXIUM_LIVE_USER}" "${_LIVE_HOME}/Desktop" 2>/dev/null || true
			fi
		fi
	fi

	# Creating state file
	touch /var/lib/live/config/linuxium-graphics
}

Cmdline
Init
Config
LIVEEOF
chmod +x "$LIVE_CFG_DIR/0190-linuxium-graphics"

# 9. Branding + Calamares tweaks hook (runs inside the chroot at build time,
#    after packages and includes have been installed)
mkdir -p config/hooks/normal
cat > config/hooks/normal/0100-linuxium.hook.chroot <<'EOF'
#!/bin/sh
set -e

# Compile the dconf defaults
dconf update

# Pre-generate the default en_US.UTF-8 locale at build time so
# live-config's 0050-locales ("locale-gen --keep-existing") returns
# immediately on boot instead of compiling UTF-8 locale tables while
# Plymouth waits on the splash screen, and so installed systems have a
# valid UTF-8 locale ready out of the box.
if [ -f /etc/locale.gen ]; then
  sed -i -E 's/^#[[:space:]]*(en_US\.UTF-8[[:space:]]+UTF-8)/\1/' /etc/locale.gen
  if ! grep -Eq '^en_US\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
    printf 'en_US.UTF-8 UTF-8\n' >> /etc/locale.gen
  fi
  locale-gen
fi
if command -v update-locale >/dev/null 2>&1; then
  update-locale LANG=en_US.UTF-8
else
  printf 'LANG=en_US.UTF-8\n' > /etc/default/locale
fi

# Branding (ID stays "debian" so tools - including Debian's signed GRUB
# and the Calamares helpers, which look for the "bookworm" release -
# keep working)
cat > /etc/os-release <<'OSR'
PRETTY_NAME="Linuxium __LINUXIUM_VERSION__"
NAME="Linuxium"
VERSION_ID="__LINUXIUM_VERSION__"
VERSION="__LINUXIUM_VERSION__ (Playerz)"
VERSION_CODENAME=bookworm
ID=debian
ID_LIKE=debian
BUG_REPORT_URL="https://bugs.debian.org/"
OSR

printf 'Linuxium __LINUXIUM_VERSION__ \\n \\l\n\n' > /etc/issue
echo "Linuxium __LINUXIUM_VERSION__" > /etc/issue.net

# Make sure LightDM is the display manager AND that systemd really boots
# to the graphical target. Do not rely only on the lightdm package's
# postinst/debconf dance having run in just the right order inside the
# live-build chroot; create the two decisive links explicitly.
mkdir -p /etc/X11 /etc/systemd/system
echo /usr/sbin/lightdm > /etc/X11/default-display-manager
ln -sfn /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
ln -sfn /lib/systemd/system/graphical.target /etc/systemd/system/default.target

# A portable ISO must not contain CPU microcode only for the CPU vendor
# of the machine that happened to build it. Debian's AMD hook in "auto"
# mode adds nothing on an Intel builder (and vice versa), so force both
# vendors into the early initramfs. The kernel ignores the other
# vendor's blob at boot. These are shell fragments sourced by the
# hooks, so appending an assignment overrides the packaged default.
if [ -f /etc/default/amd64-microcode ]; then
  printf '\n# Linuxium: include on non-AMD builders too (portable image)\nAMD64UCODE_INITRAMFS=early\n' >> /etc/default/amd64-microcode
fi
if [ -f /etc/default/intel-microcode ]; then
  printf '\n# Linuxium: include on non-Intel builders too (portable image)\nIUCODE_TOOL_INITRAMFS=early\nIUCODE_TOOL_SCANCPUS=no\n' >> /etc/default/intel-microcode
fi

# Boot splash: select the theme and rebuild the initramfs so it is included
plymouth-set-default-theme linuxium
update-initramfs -u -k all

# Neofetch: show the Linuxium logo with a transparent background for
# every new user. Bookworm's Neofetch needs ImageMagick present even for
# the chafa backend, and a graphical terminal whose pixel size it can
# detect (xdotool/x11-utils are in the package list for exactly this).
# crop_mode="none" passes our pre-sized PNG32 RGBA logo straight to chafa
# untouched so its alpha transparency is preserved 100%.
mkdir -p /etc/skel/.config/neofetch
if neofetch --print_config > /tmp/nf.conf 2>/dev/null && [ -s /tmp/nf.conf ]; then
  sed -i \
    -e 's|^image_backend=.*|image_backend="chafa"|' \
    -e 's|^image_source=.*|image_source="/usr/share/linuxium/logo.png"|' \
    -e 's|^crop_mode=.*|crop_mode="none"|' \
    /tmp/nf.conf
  mv /tmp/nf.conf /etc/skel/.config/neofetch/config.conf
else
  printf 'image_backend="chafa"\nimage_source="/usr/share/linuxium/logo.png"\ncrop_mode="none"\n' > /etc/skel/.config/neofetch/config.conf
fi
# The config is sourced top-to-bottom; append the decisive values so a
# future Neofetch default-config format change cannot silently undo them.
cat >> /etc/skel/.config/neofetch/config.conf <<'NF'

# Linuxium overrides (valid CLI test: neofetch --chafa /usr/share/linuxium/logo.png)
image_backend="chafa"
image_source="/usr/share/linuxium/logo.png"
crop_mode="none"
NF

# ---- Calamares: keep Debian's tested module sequence/helpers, rebrand ----
# NOTE: /etc/calamares (lowercase) is the correct path on Debian 12.
if [ -f /etc/calamares/settings.conf ]; then
  sed -i 's|^branding[[:space:]]*:.*|branding: linuxium|' /etc/calamares/settings.conf
fi

# Debian's signed GRUB binary has the bootloader ID "debian" hard-coded
# (it looks for /EFI/debian/grub.cfg). Installing it under any other ID
# drops the machine at a "grub>" prompt, so the EFI directory stays
# /EFI/debian while the visible menu name is still Linuxium. This is
# also what keeps Secure Boot working on the installed system.
if [ -f /etc/calamares/modules/bootloader.conf ]; then
  if grep -q '^efiBootloaderId:' /etc/calamares/modules/bootloader.conf; then
    sed -i 's|^efiBootloaderId:.*|efiBootloaderId: "debian"|' /etc/calamares/modules/bootloader.conf
  elif grep -q '^# *efiBootloaderId:' /etc/calamares/modules/bootloader.conf; then
    sed -i 's|^# *efiBootloaderId:.*|efiBootloaderId: "debian"|' /etc/calamares/modules/bootloader.conf
  else
    printf '\nefiBootloaderId: "debian"\n' >> /etc/calamares/modules/bootloader.conf
  fi
fi

# Linuxium needs a bit more disk than a minimal Debian live image.
# NOTE: match a decimal value whole ("5.5"), not just its integer part -
# replacing only "[0-9]+" would turn 5.5 into 16.5.
if [ -f /etc/calamares/modules/welcome.conf ]; then
  sed -i -E 's|(requiredStorage:[[:space:]]*)[0-9]+([.][0-9]+)?|\116|' /etc/calamares/modules/welcome.conf
fi

# Remove the installer itself from the installed system too (Debian's
# default list only removes calamares-settings-debian).
if [ -f /etc/calamares/modules/packages.conf ]; then
  if ! grep -q "'calamares'" /etc/calamares/modules/packages.conf; then
    sed -i "/calamares-settings-debian/a\\      - 'calamares'" /etc/calamares/modules/packages.conf
  fi
fi

# Keep the same archive areas on the installed system as on the live ISO,
# so the firmware/contrib packages keep receiving updates, and strip
# live-only installer/welcome-popup files from the installed target disk
# right before Calamares unmounts it.
if [ -f /usr/sbin/sources-final ]; then
  sed -i 's| main non-free-firmware| main contrib non-free non-free-firmware|g' /usr/sbin/sources-final
  # shellcheck disable=SC2016 # $CHROOT expands at install time inside sources-final
  sed -i '/^exit 0/i \
if [ -n "${CHROOT:-}" ] \&\& [ "$CHROOT" != "/" ] \&\& [ -d "$CHROOT" ]; then\
  rm -f "$CHROOT/etc/skel/Desktop/install-linuxium.desktop" \
        "$CHROOT/etc/skel/Desktop/linuxium-experience.desktop" \\\
        "$CHROOT/usr/share/applications/install-linuxium.desktop" \
        "$CHROOT/usr/share/applications/linuxium-experience.desktop" \\\
        "$CHROOT/usr/bin/install-linuxium" \
        "$CHROOT/usr/bin/linuxium-experience" \\\
        "$CHROOT/etc/xdg/autostart/linuxium-welcome.desktop"\
  rm -rf "$CHROOT/usr/lib/linuxium"\
  for _u_desk in "$CHROOT"/home/*/Desktop/install-linuxium.desktop "$CHROOT"/home/*/Desktop/linuxium-experience.desktop; do\
    [ -e "$_u_desk" ] \&\& rm -f "$_u_desk"\
  done\
fi' /usr/sbin/sources-final
fi

# VMware guest services: enable Open VM Tools (ConditionVirtualization=vmware
# keeps them inert on bare metal / VirtualBox / QEMU).
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable open-vm-tools.service open-vm-tools-desktop.service 2>/dev/null || true
fi

# We ship our own "Linuxium Experience" launcher + one-time welcome popup, so
# hide Debian's unbranded "Install Debian" menu entry and desktop-icon autostart.
for deb_inst_desktop in \
  /usr/share/applications/install-debian.desktop \
  /usr/share/applications/calamares-install-debian.desktop; do
  if [ -f "$deb_inst_desktop" ]; then
    printf '\nNoDisplay=true\n' >> "$deb_inst_desktop"
  fi
done
if [ -f /etc/xdg/autostart/calamares-desktop-icon.desktop ]; then
  printf '\nHidden=true\n' >> /etc/xdg/autostart/calamares-desktop-icon.desktop
fi

# Desktop launchers baked directly into /etc/skel/Desktop (0755, trusted by
# Nemo out of the box): Linuxium Experience, File Browser (Nemo) and Firefox.
# Calamares's sources-final step above strips install-linuxium.desktop from
# the installed target disk so only live boots show the installer shortcut.
mkdir -p /etc/skel/Desktop
for skel_app in linuxium-experience.desktop install-linuxium.desktop nemo.desktop firefox-esr.desktop; do
  if [ -f "/usr/share/applications/$skel_app" ]; then
    cp -f "/usr/share/applications/$skel_app" "/etc/skel/Desktop/$skel_app"
    chmod 0755 "/etc/skel/Desktop/$skel_app"
  fi
done

# Consolidate all wallpaper XML manifests into ONE "Linuxium" category in
# Cinnamon Settings -> Backgrounds (gnome-backgrounds 43 otherwise ships
# 20+ separate 1-wallpaper XML files that each create their own sidebar
# category), and set Cinnamon's taskbar menu icon (Lynx) and pinned apps.
python3 - <<'PYHOOK'
import json
import mimetypes
import os
import pathlib
import xml.etree.ElementTree as ET

prop_dirs = [
    pathlib.Path("/usr/share/gnome-background-properties"),
    pathlib.Path("/usr/share/cinnamon-background-properties"),
]

xml_sources = []
for d in prop_dirs:
    primary = d / "linuxium.xml"
    if primary.exists():
        xml_sources.append(primary)
for d in prop_dirs:
    if d.is_dir():
        for p in sorted(d.glob("*.xml")):
            if p.name != "linuxium.xml":
                xml_sources.append(p)

merged_items = []
seen_files = set()

for src in xml_sources:
    try:
        tree = ET.parse(src)
    except Exception:
        continue
    root = tree.getroot()
    if root.tag != "wallpapers":
        continue
    for wp in root.findall("wallpaper"):
        if wp.get("deleted") == "true":
            continue
        fn_el = wp.find("filename")
        if fn_el is None or not fn_el.text:
            continue
        fname = fn_el.text.strip()
        if not fname.startswith("/") or fname.lower().endswith(".xml"):
            continue
        if not os.path.isfile(fname):
            continue
        mime = mimetypes.guess_type(fname)[0]
        if not mime or not mime.startswith("image/"):
            real = os.path.realpath(fname)
            real_mime = mimetypes.guess_type(real)[0]
            if not real_mime or not real_mime.startswith("image/"):
                continue
            fname = real
        if fname in seen_files:
            continue
        seen_files.add(fname)

        name_el = wp.find("name")
        name = (name_el.text or "").strip() if name_el is not None else ""
        if not name:
            name = pathlib.Path(fname).stem.replace("-", " ").replace("_", " ").title()
        opts = (wp.findtext("options") or "zoom").strip()
        pcolor = (wp.findtext("pcolor") or "#525252").strip()
        scolor = (wp.findtext("scolor") or "#525252").strip()
        shade = (wp.findtext("shade_type") or "solid").strip()
        merged_items.append((name, fname, opts, pcolor, scolor, shade))

def xml_esc(text):
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )

if merged_items:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">',
        "<wallpapers>",
    ]
    for name, fname, opts, pcolor, scolor, shade in merged_items:
        lines.extend([
            '  <wallpaper deleted="false">',
            f"    <name>{xml_esc(name)}</name>",
            f"    <filename>{xml_esc(fname)}</filename>",
            f"    <options>{xml_esc(opts)}</options>",
            f"    <pcolor>{xml_esc(pcolor)}</pcolor>",
            f"    <scolor>{xml_esc(scolor)}</scolor>",
            f"    <shade_type>{xml_esc(shade)}</shade_type>",
            "  </wallpaper>",
        ])
    lines.append("</wallpapers>")
    payload = "\n".join(lines) + "\n"

    for d in prop_dirs:
        d.mkdir(parents=True, exist_ok=True)
        for old_xml in list(d.glob("*.xml")):
            if old_xml.name != "linuxium.xml":
                old_xml.unlink(missing_ok=True)
        (d / "linuxium.xml").write_text(payload, encoding="utf-8")

menu_schema = pathlib.Path("/usr/share/cinnamon/applets/menu@cinnamon.org/settings-schema.json")
if menu_schema.is_file():
    data = json.loads(menu_schema.read_text(encoding="utf-8"))
    if "menu-custom" in data and isinstance(data["menu-custom"], dict):
        data["menu-custom"]["default"] = True
    if "menu-icon" in data and isinstance(data["menu-icon"], dict):
        data["menu-icon"]["default"] = "/usr/share/linuxium/panel-icon.png"
        if "default_icon" in data["menu-icon"]:
            data["menu-icon"]["default_icon"] = "/usr/share/linuxium/panel-icon.png"
    if "menu-icon-size" in data and isinstance(data["menu-icon-size"], dict):
        data["menu-icon-size"]["default"] = 28
    if "menu-label" in data and isinstance(data["menu-label"], dict):
        data["menu-label"]["default"] = ""
    menu_schema.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

gwl_schema = pathlib.Path("/usr/share/cinnamon/applets/grouped-window-list@cinnamon.org/settings-schema.json")
if gwl_schema.is_file():
    gwl = json.loads(gwl_schema.read_text(encoding="utf-8"))
    desired_pins = [
        app_id for app_id in (
            "nemo.desktop",
            "firefox-esr.desktop",
            "gimp.desktop",
            "org.gnome.Terminal.desktop",
        )
        if pathlib.Path("/usr/share/applications", app_id).is_file()
    ]
    if desired_pins and "pinned-apps" in gwl and isinstance(gwl["pinned-apps"], dict):
        gwl["pinned-apps"]["default"] = desired_pins
        gwl_schema.write_text(json.dumps(gwl, indent=2) + "\n", encoding="utf-8")
PYHOOK

# Drop unused Papirus variants before building icon caches (keep both Papirus
# and Papirus-Dark: Papirus-Dark icons symlink into ../Papirus).
rm -rf /usr/share/icons/Papirus-Light \
       /usr/share/icons/ePapirus \
       /usr/share/icons/ePapirus-Dark

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  for icon_root in /usr/share/icons/hicolor /usr/share/icons/Papirus /usr/share/icons/Papirus-Dark; do
    if [ -d "$icon_root" ]; then
      gtk-update-icon-cache -q -f -t "$icon_root" || true
    fi
  done
fi
dconf update

# Installed-system GRUB defaults: name, quiet splash boot, and the
# Linuxium wallpaper as the GRUB background (update-grub copies it in).
if [ -f /etc/default/grub ]; then
  cat >> /etc/default/grub <<'GRUBCFG'

# Linuxium defaults
GRUB_DISTRIBUTOR="Linuxium"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"
GRUB_BACKGROUND="/usr/share/backgrounds/linuxium/linuxium.png"
GRUBCFG
fi

# Reclaim build-time caches, .deb archives, backup state, logs, and temp files
# before binary_rootfs packs filesystem.squashfs. Keep /var/lib/apt/lists and
# /usr/share/doc on disk in chroot/ so later live-build binary stages
# (binary_rootfs, binary_grub-efi, binary_package-lists) still work; APT list
# indexes are omitted from filesystem.squashfs via config/rootfs/excludes.
apt-get autoremove --purge -y >/dev/null 2>&1 || true
apt-get clean || true
rm -rf /tmp/* /var/tmp/* /root/.cache \
       /var/cache/apt/archives/*.deb \
       /var/cache/debconf/*-old \
       /var/lib/dpkg/*-old \
       /var/log/*.log /var/log/apt/* \
       /boot/*.old
EOF
chmod +x config/hooks/normal/0100-linuxium.hook.chroot
# The hook above is a quoted heredoc (it must not be expanded by this
# script), so substitute the version placeholder now. LINUXIUM_VERSION
# stays the single place a release version bump has to happen.
sed -i "s/__LINUXIUM_VERSION__/${LINUXIUM_VERSION}/g" \
  config/hooks/normal/0100-linuxium.hook.chroot
if grep -q '__LINUXIUM_VERSION__' config/hooks/normal/0100-linuxium.hook.chroot; then
  echo "ERROR: version substitution failed in the chroot hook" >&2
  exit 1
fi

# 10. Build the ISO
#     Pass high-ratio SquashFS XZ options explicitly via `env` after sudo so
#     sudo's env_reset cannot strip MKSQUASHFS_OPTIONS:
#       -b 1048576       1 MiB SquashFS blocks (8x default 128 KiB window)
#       -Xbcj x86        LZMA2 x86 CALL/JMP filter for ELF binaries/libs
#       -Xdict-size 100% full 1 MiB LZMA2 dictionary per block
#       -no-recovery     skip build-time recovery file generation
MKSQUASHFS_OPTS="-b 1048576 -Xbcj x86 -Xdict-size 100% -no-recovery"
"${SUDO[@]}" env MKSQUASHFS_OPTIONS="$MKSQUASHFS_OPTS" lb build

# 11. Sanity checks: kernel/initrd/rootfs, both boot-menu backgrounds, the
#     offline bootloader pool, and (most importantly) signed EFI binaries.
shopt -s nullglob
ISOS=(./*.iso)
shopt -u nullglob
if [ "${#ISOS[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly one .iso in $(pwd), found: ${ISOS[*]:-none}" >&2
  exit 1
fi
ISO="${ISOS[0]}"
LISTING="$(xorriso -indev "$ISO" -find / -type f 2>/dev/null || true)"
for part in \
  "/live/vmlinuz" "/live/initrd.img" "/live/filesystem.squashfs" \
  "/install/gtk/vmlinuz" "/install/gtk/initrd.gz" \
  "/boot/grub/splash.png" "/isolinux/splash.png" "/boot/grub/efi.img" \
  "grub-pc_" "grub-efi-amd64_" "grub-efi-amd64-signed_" "shim-signed_"; do
  if ! grep -Fq "$part" <<<"$LISTING"; then
    echo "ERROR: '$part' is missing from $ISO" >&2
    echo "       (boot backgrounds live in /boot/grub and /isolinux," >&2
    echo "        the *_ entries are the offline bootloader pool)" >&2
    exit 1
  fi
done

# A syntactically successful ISO is not necessarily a bootable system.
# Inspect the live squashfs itself for the pieces that decide whether a
# desktop can appear at all: init, display manager, both Cinnamon
# sessions, live-config safeguard, installer, Plymouth and kernel/initrd.
if [ -f binary/live/filesystem.squashfs ]; then
  ROOTFS_LISTING="$("${SUDO[@]}" unsquashfs -ll binary/live/filesystem.squashfs 2>/dev/null || true)"
  for root_part in \
    "/sbin/init" "/usr/sbin/lightdm" "/usr/bin/calamares" "/usr/bin/gimp" \
    "/usr/bin/wine" "/usr/bin/wine64" "/usr/bin/winetricks" \
    "/usr/bin/linuxium-experience" "/usr/bin/install-linuxium" \
    "/usr/lib/linuxium/linuxium-experience" \
    "/usr/share/xsessions/cinnamon.desktop" \
    "/usr/share/xsessions/cinnamon2d.desktop" \
    "/live/config/0190-linuxium-graphics" \
    "/usr/sbin/linuxium-wait-graphics" \
    "/usr/sbin/linuxium-virtualbox-graphics" \
    "/etc/systemd/system/lightdm.service.d/50-linuxium.conf" \
    "/etc/systemd/system/plymouth-quit-wait.service.d/50-linuxium.conf" \
    "/etc/systemd/system/live-config.service.d/50-linuxium.conf" \
    "/etc/systemd/system/linuxium-boot-fallback-vt.service" \
    "/etc/systemd/system/linuxium-virtualbox-graphics.service" \
    "/etc/systemd/system/multi-user.target.wants/linuxium-virtualbox-graphics.service" \
    "/etc/lightdm/lightdm.conf.d/50-linuxium.conf" \
    "/etc/X11/xorg.conf.d/20-linuxium-vm-kms.conf" \
    "/etc/default/locale" \
    "/etc/initramfs-tools/conf.d/linuxium-compress" \
    "/usr/share/initramfs-tools/hooks/cryptroot" \
    "/usr/share/plymouth/themes/linuxium/linuxium.plymouth" \
    "/usr/share/plymouth/themes/linuxium/linuxium.script" \
    "/usr/share/plymouth/themes/linuxium/logo.png" \
    "/usr/share/plymouth/themes/linuxium/well.png" \
    "/usr/share/plymouth/themes/linuxium/block-0.png" \
    "/usr/share/plymouth/themes/linuxium/block-6.png" \
    "/usr/share/plymouth/themes/linuxium/progress-track.png" \
    "/usr/share/plymouth/themes/linuxium/progress-bar.png" \
    "/etc/initramfs-tools/modules" \
    "/usr/share/linuxium/panel-icon.png" \
    "/usr/share/icons/Papirus-Dark/index.theme" \
    "/usr/share/cinnamon/applets/search-bar@linuxium/applet.js" \
    "/usr/share/cinnamon/applets/search-bar@linuxium/metadata.json" \
    "/usr/share/cinnamon/applets/search-bar@linuxium/stylesheet.css" \
    "/usr/share/cinnamon/desklets/clock@linuxium/desklet.js" \
    "/usr/share/cinnamon/desklets/clock@linuxium/metadata.json" \
    "/usr/share/cinnamon/desklets/clock@linuxium/stylesheet.css" \
    "/usr/share/cinnamon/desklets/stats@linuxium/desklet.js" \
    "/usr/share/cinnamon/desklets/stats@linuxium/metadata.json" \
    "/usr/share/cinnamon/desklets/stats@linuxium/stylesheet.css" \
    "/usr/share/gnome-background-properties/linuxium.xml" \
    "/usr/share/cinnamon-background-properties/linuxium.xml" \
    "/lib/linuxium/welcome-popup" \
    "/lib/linuxium/welcome-autostart" \
    "/usr/share/applications/linuxium-experience.desktop" \
    "/etc/skel/Desktop/linuxium-experience.desktop" \
    "/etc/skel/Desktop/install-linuxium.desktop" \
    "/etc/skel/Desktop/nemo.desktop" \
    "/etc/skel/Desktop/firefox-esr.desktop" \
    "/usr/share/themes/CBlack/index.theme" \
    "/usr/share/themes/CBlack/cinnamon/cinnamon.css" \
    "/usr/share/themes/CBlack/gtk-3.0/gtk.css" \
    "/boot/vmlinuz-" "/boot/initrd.img-"; do
    if ! grep -Fq "$root_part" <<<"$ROOTFS_LISTING"; then
      echo "ERROR: '$root_part' is missing from the live root filesystem" >&2
      exit 1
    fi
  done
  if grep -Fq "/usr/share/applications/linuxium-welcome.desktop" <<<"$ROOTFS_LISTING"; then
    echo "ERROR: linuxium-welcome.desktop must not be installed as an openable app" >&2
    exit 1
  fi
  SQUASHFS_BYTES="$(stat -c %s binary/live/filesystem.squashfs)"
  echo "Live root filesystem boot-component check: OK"
else
  echo "ERROR: binary/live/filesystem.squashfs not found after build; cannot verify the live root filesystem" >&2
  exit 1
fi

# Firmware does not boot files merely because they exist in the ISO: the
# El Torito catalogue must point BIOS at ISOLINUX and UEFI at efi.img,
# and the system area must be an isohybrid MBR for raw-written USBs.
BOOT_REPORT="$(xorriso -indev "$ISO" -report_el_torito plain \
  -report_system_area plain 2>/dev/null || true)"
for boot_pattern in \
  'El Torito boot img[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]+BIOS[[:space:]]+y' \
  'El Torito boot img[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]+UEFI[[:space:]]+y' \
  '/isolinux/isolinux.bin' \
  '/boot/grub/efi.img' \
  'System area summary:.*MBR isohybrid'; do
  if ! grep -Eq "$boot_pattern" <<<"$BOOT_REPORT"; then
    echo "ERROR: ISO boot metadata check failed for pattern: $boot_pattern" >&2
    printf '%s\n' "$BOOT_REPORT" >&2
    exit 1
  fi
done
echo "ISO firmware boot-catalogue check: OK (BIOS + UEFI, isohybrid MBR)"

VERIFY_DIR="$(mktemp -d)"
if ! xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg \
     "$VERIFY_DIR/grub.cfg" >/dev/null 2>&1 \
   || [ ! -s "$VERIFY_DIR/grub.cfg" ]; then
  echo "ERROR: could not extract /boot/grub/grub.cfg from $ISO" >&2
  exit 1
fi
FAILSAFE_KERNEL_LINES="$(grep 'linuxium-session=cinnamon2d' "$VERIFY_DIR/grub.cfg" || true)"
# shellcheck disable=SC2016 # ${iso_path} is a GRUB variable, not a shell one
if [ -z "$FAILSAFE_KERNEL_LINES" ] || grep -vF 'findiso=${iso_path}' <<<"$FAILSAFE_KERNEL_LINES" | grep -q .; then
  echo "ERROR: a GRUB fail-safe entry is missing findiso=\${iso_path}" >&2
  printf '%s\n' "$FAILSAFE_KERNEL_LINES" >&2
  exit 1
fi
echo "GRUB fail-safe loopback check: OK"

# Secure Boot: the firmware loads BOOTX64.EFI first - that must be the
# Microsoft-signed shim, GRUBX64.EFI must carry Debian's signature, and
# the kernel GRUB loads must be signed by Debian too.
if xorriso -osirrox on -indev "$ISO" -extract /boot/grub/efi.img "$VERIFY_DIR/efi.img" >/dev/null 2>&1 \
   && [ -s "$VERIFY_DIR/efi.img" ]; then
  if ! mcopy -n -i "$VERIFY_DIR/efi.img" "::/EFI/BOOT/BOOTX64.EFI" "$VERIFY_DIR/BOOTX64.EFI" 2>/dev/null \
     || ! mcopy -n -i "$VERIFY_DIR/efi.img" "::/EFI/BOOT/GRUBX64.EFI" "$VERIFY_DIR/GRUBX64.EFI" 2>/dev/null; then
    echo "ERROR: could not extract BOOTX64.EFI/GRUBX64.EFI from efi.img. Contents:" >&2
    mdir -i "$VERIFY_DIR/efi.img" -/ :: >&2 || true
    exit 1
  fi
  KERNEL_PATH="$(tr -d "'" <<<"$LISTING" | grep -oE '/live/vmlinuz-[^"[:space:]]+' | head -n 1 || true)"
  if [ -z "$KERNEL_PATH" ] \
     || ! xorriso -osirrox on -indev "$ISO" -extract "$KERNEL_PATH" \
          "$VERIFY_DIR/vmlinuz" >/dev/null 2>&1 \
     || [ ! -s "$VERIFY_DIR/vmlinuz" ]; then
    echo "ERROR: could not extract the versioned live kernel from $ISO" >&2
    exit 1
  fi
  if ! command -v sbverify >/dev/null 2>&1; then
    echo "ERROR: sbverify (sbsigntool) not found - cannot verify the promised Secure Boot chain" >&2
    exit 1
  fi
  BOOT_SIG="$(sbverify --list "$VERIFY_DIR/BOOTX64.EFI" 2>/dev/null || true)"
  GRUB_SIG="$(sbverify --list "$VERIFY_DIR/GRUBX64.EFI" 2>/dev/null || true)"
  KERNEL_SIG="$(sbverify --list "$VERIFY_DIR/vmlinuz" 2>/dev/null || true)"
  echo "Secure Boot signatures:"
  printf '%s\n' "$BOOT_SIG" | sed 's/^/  BOOTX64.EFI: /'
  printf '%s\n' "$GRUB_SIG" | sed 's/^/  GRUBX64.EFI: /'
  printf '%s\n' "$KERNEL_SIG" | sed 's/^/  vmlinuz: /'
  if ! grep -qi "Microsoft" <<<"$BOOT_SIG"; then
    echo "ERROR: BOOTX64.EFI is not the Microsoft-signed shim - Secure Boot will reject this ISO." >&2
    exit 1
  fi
  if ! grep -qi "Debian" <<<"$GRUB_SIG"; then
    echo "ERROR: GRUBX64.EFI is not Debian-signed - Secure Boot will reject this ISO." >&2
    exit 1
  fi
  if ! grep -qi "Debian" <<<"$KERNEL_SIG"; then
    echo "ERROR: the live kernel is not Debian-signed - Secure Boot will reject this ISO." >&2
    exit 1
  fi
  echo "Secure Boot check: OK (Microsoft-signed shim + Debian-signed GRUB and kernel)"
else
  echo "ERROR: could not extract /boot/grub/efi.img from $ISO" >&2
  exit 1
fi

sha256sum "$ISO" > "${ISO}.sha256"

# 12. Reclaim intermediate build trees and compress the verified ISO into a
#     smaller .iso.xz archive (balenaEtcher and Rufus both flash .iso.xz
#     directly without manual extraction, while raw .iso stays available for
#     QEMU/VirtualBox/dd).
"${SUDO[@]}" rm -rf chroot cache binary

COMPRESSED_ISO="${ISO}.xz"
echo "Compressing ${ISO#./} -> ${COMPRESSED_ISO#./} (xz -T0 -${LINUXIUM_XZ_LEVEL})..."
xz -k -f -T0 "-${LINUXIUM_XZ_LEVEL}" "$ISO"
if [ ! -s "$COMPRESSED_ISO" ]; then
  echo "ERROR: compressed image $COMPRESSED_ISO was not created" >&2
  exit 1
fi
sha256sum "$COMPRESSED_ISO" > "${COMPRESSED_ISO}.sha256"

ISO_BYTES="$(stat -c %s "$ISO")"
XZ_BYTES="$(stat -c %s "$COMPRESSED_ISO")"
SQUASHFS_MIB="$(awk -v b="${SQUASHFS_BYTES:-0}" 'BEGIN { printf "%.1f MiB", b / 1048576 }')"
ISO_MIB="$(awk -v b="$ISO_BYTES" 'BEGIN { printf "%.1f MiB", b / 1048576 }')"
XZ_MIB="$(awk -v b="$XZ_BYTES" 'BEGIN { printf "%.1f MiB", b / 1048576 }')"
SAVED_PCT="$(awk -v raw="$ISO_BYTES" -v cmp="$XZ_BYTES" 'BEGIN { if (raw > 0) printf "%.1f%%", (1 - cmp / raw) * 100; else print "0.0%" }')"

echo
echo "Done."
echo "  Live SquashFS:      ${SQUASHFS_MIB}"
echo "  Bootable ISO:       $(pwd)/${ISO#./} (${ISO_MIB})"
echo "  ISO SHA-256:        $(pwd)/${ISO#./}.sha256"
echo "  Compressed ISO:     $(pwd)/${COMPRESSED_ISO#./} (${XZ_MIB}, ${SAVED_PCT} smaller)"
echo "  Compressed SHA-256: $(pwd)/${COMPRESSED_ISO#./}.sha256"
echo "Test it with:"
echo "  BIOS/MBR:  qemu-system-x86_64 -m 4096 -enable-kvm -cdrom ${ISO#./}"
echo "  UEFI+SB:   qemu-system-x86_64 -m 4096 -enable-kvm -machine q35 \\"
echo "               -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \\"
echo "               -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd -cdrom ${ISO#./}"
echo "             (copy /usr/share/OVMF/OVMF_VARS_4M.fd to /tmp/OVMF_VARS.fd first)"
