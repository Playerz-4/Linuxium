#!/usr/bin/env bash
# Linuxium ISO builder: Debian 12 (bookworm) + Cinnamon, using live-build.
# Run on Debian/Ubuntu (or inside a Debian VM/container with root access).
#
# Usage:  ./build-linuxium.sh [wallpaper.png] [logo.png] [grub-background.png] [extra-wallpapers-dir]
#   wallpaper.png        desktop + login wallpaper          (default ./wallpaper.png)
#   logo.png             boot splash (Plymouth) + neofetch  (default ./lynx.png)
#   grub-background.png  boot-menu background               (default ./Untitled118_20261019185732.png)
#   extra-wallpapers-dir optional folder of your own .jpg/.png wallpapers
#                                                              (default ./wallpapers)
#
# What changed in this fixed version (see README-CHANGES.md for the full story):
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
#   * Calamares graphical installer (Debian's tested configuration, with
#     Linuxium branding) + a "Welcome to Linuxium" app that pops up in the
#     live session.
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
WALLPAPER="${1:-./wallpaper.png}"
LOGO="${2:-./lynx.png}"
GRUB_BG="${3:-./Untitled118_20261019185732.png}"
EXTRA_WALLPAPERS_DIR="${4:-./wallpapers}"
WORK="linuxium-build"

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo); fi

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
    echo "Usage: $0 [wallpaper.png] [logo.png] [grub-background.png] [extra-wallpapers-dir]"
    exit 1
  fi
done
WALLPAPER="$(realpath "$WALLPAPER")"
LOGO="$(realpath "$LOGO")"
GRUB_BG="$(realpath "$GRUB_BG")"
EXTRA_WALLPAPERS_DIR="$(realpath -m "$EXTRA_WALLPAPERS_DIR")"
# Downloaded wallpaper sources are cached OUTSIDE the build tree so that
# local rebuilds do not re-download them every time.
DOWNLOAD_CACHE="$(realpath -m "./wallpapers-extra-downloads")"
mkdir -p "$DOWNLOAD_CACHE"

# 1. Build tools
# IMPORTANT: do not use --no-install-recommends here. In Debian 12,
# live-build only *Recommends* several tools it genuinely needs. cpio is
# one of them: installer_debian-installer calls cpio directly, and without
# it the build dies late with exit code 127 ("cpio: not found"). Install
# Recommends explicitly (even if the host's apt config disables them) and
# also name cpio so the requirement is obvious and guaranteed.
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y --install-recommends \
  live-build debootstrap cpio squashfs-tools xorriso apt-utils \
  isolinux syslinux-common grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
  imagemagick curl ca-certificates librsvg2-bin sbsigntool

# ImageMagick 7 calls it "magick", ImageMagick 6 (Debian 12) uses "convert".
if command -v magick >/dev/null 2>&1; then IM=(magick); else IM=(convert); fi

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
lb config \
  --distribution bookworm \
  --architectures amd64 \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --bootloaders "syslinux,grub-efi" \
  --uefi-secure-boot enable \
  --debian-installer live \
  --iso-application "Linuxium ${LINUXIUM_VERSION}" \
  --iso-publisher "Linuxium" \
  --iso-volume "LINUXIUM" \
  --image-name "linuxium" \
  --bootappend-live "boot=live components quiet splash loglevel=3 username=linuxium hostname=linuxium locales=en_US.UTF-8 keyboard-layouts=us" \
  --bootappend-live-failsafe "boot=live components memtest noapic noapm nodma nomce nolapic nosmp nosplash nomodeset vga=788 linuxium-session=cinnamon2d" \
  --memtest none

# 4. Package list
mkdir -p config/package-lists
cat > config/package-lists/linuxium.list.chroot <<'EOF'
# Init system: without these the live image can boot to
# "No init found" because /sbin/init is missing from the squashfs
init
systemd-sysv

# Graphics: X server plus video/input drivers. Without these LightDM can
# fail to start and the screen stays black (common in VMs)
xorg
xserver-xorg-video-all
xserver-xorg-input-all
libgl1-mesa-dri

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

# Graphical installer: Calamares + Debian's tested live configuration
# (offline pool handling, EFI bootloader helpers, "install-debian" launcher).
# Linuxium branding for it is added in section 5f / the hook in section 9.
calamares
calamares-settings-debian

# Tools Calamares and disk work need in the live session
squashfs-tools
rsync
efibootmgr
dosfstools
btrfs-progs
xfsprogs
lvm2
cryptsetup
gparted
os-prober

# Secure Boot chain inside the installed system: Microsoft-signed shim ->
# Debian-signed GRUB -> Debian-signed kernel. The *-bin packages let
# grub-install work for both BIOS and UEFI; grub-pc / grub-efi-amd64
# themselves are installed onto the target disk by Calamares from the
# ISO's /pool (they conflict with each other, so they cannot both live
# in the live system).
grub-common
grub2-common
grub-pc-bin
grub-efi-amd64-bin
grub-efi-amd64-signed
shim-signed
mokutil

# Linuxium Welcome app (Python + GTK 3)
python3-gi
gir1.2-gtk-3.0
xdg-utils

# Guest integration for testing in QEMU/KVM and SPICE viewers
qemu-guest-agent
spice-vdagent

# Branding
plymouth
plymouth-themes
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
fonts-noto
fonts-dejavu
live-boot
live-config
live-config-systemd
EOF

# 5. Wallpapers
WP_DIR="config/includes.chroot/usr/share/backgrounds/linuxium"
mkdir -p "$WP_DIR"
cp "$WALLPAPER" "$WP_DIR/linuxium.png"

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
  if "${IM[@]}" "$wp_cache" -auto-orient -resize '1920x1080^' -gravity center \
       -extent 1920x1080 -strip -quality 88 "$WP_DIR/$wp_out"; then
    WP_NAMES+=("$wp_name")
    WP_FILES+=("$wp_out")
    printf '%s\n' "$wp_credit" >> "$DOC_DIR/CREDITS.txt"
  else
    echo "WARNING: could not convert $wp_cache - skipping this wallpaper" >&2
  fi
done

# 5b. Your own extra wallpapers: anything in ./wallpapers/ (or $4).
if [ -d "$EXTRA_WALLPAPERS_DIR" ]; then
  shopt -s nullglob
  EXTRA_SRC=("$EXTRA_WALLPAPERS_DIR"/*.jpg "$EXTRA_WALLPAPERS_DIR"/*.jpeg
             "$EXTRA_WALLPAPERS_DIR"/*.png "$EXTRA_WALLPAPERS_DIR"/*.webp
             "$EXTRA_WALLPAPERS_DIR"/*.JPG "$EXTRA_WALLPAPERS_DIR"/*.JPEG
             "$EXTRA_WALLPAPERS_DIR"/*.PNG)
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
#     gnome-background-properties directories; install both).
for props in cinnamon-background-properties gnome-background-properties; do
  mkdir -p "config/includes.chroot/usr/share/$props"
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
  } > "config/includes.chroot/usr/share/$props/linuxium-wallpapers.xml"
done
echo "Wallpapers in this build: ${WP_FILES[*]}"

# 5d. Logo for neofetch / pixmaps
# Normalize the Neofetch copy to a real, reasonably small PNG flattened on
# white instead of assuming the source file really is a PNG just because
# its name ends in .png. Neofetch's image pipeline (ImageMagick + chafa)
# is much happier with this, and the lynx stays visible on dark terminals.
mkdir -p config/includes.chroot/usr/share/linuxium config/includes.chroot/usr/share/pixmaps
"${IM[@]}" "$LOGO" -auto-orient -background white -alpha remove -alpha off \
  -resize 512x512 -strip "PNG24:config/includes.chroot/usr/share/linuxium/logo.png"
cp "$LOGO" config/includes.chroot/usr/share/pixmaps/linuxium.png

# 5e. Boot splash (Plymouth theme using the logo)
PLY_DIR="config/includes.chroot/usr/share/plymouth/themes/linuxium"
mkdir -p "$PLY_DIR"
"${IM[@]}" "$LOGO" -resize 256x256 "$PLY_DIR/logo.png"

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
"${IM[@]}" identify config/bootloaders/grub-pc/splash.png config/bootloaders/syslinux_common/splash.png 2>/dev/null \
  || identify config/bootloaders/grub-pc/splash.png config/bootloaders/syslinux_common/splash.png || true

# Give the boot menus a Linuxium title (based on the installed templates,
# so this keeps working even if the templates change a little).
GRUB_THEME_SRC="/usr/share/live/build/bootloaders/grub-pc/live-theme/theme.txt"
if [ -f "$GRUB_THEME_SRC" ]; then
  mkdir -p config/bootloaders/grub-pc/live-theme
  cp "$GRUB_THEME_SRC" config/bootloaders/grub-pc/live-theme/theme.txt
  sed -i 's/^title-text:.*/title-text: "Linuxium"/' config/bootloaders/grub-pc/live-theme/theme.txt
fi
SYS_MENU_SRC="/usr/share/live/build/bootloaders/syslinux_common/menu.cfg"
if [ -f "$SYS_MENU_SRC" ]; then
  cp "$SYS_MENU_SRC" config/bootloaders/syslinux_common/menu.cfg
  sed -i 's/^menu title.*/menu title Linuxium/' config/bootloaders/syslinux_common/menu.cfg
fi

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
    productUrl: https://example.com/linuxium
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
            text: qsTr("Firefox, LibreOffice and VLC are ready to go.<br/>" +
                  "Almost there...")
            wrapMode: Text.WordWrap
            width: 600
            horizontalAlignment: Text.Center
        }
    }
}
QMLEOF

# 5h. "Welcome to Linuxium" app (shown once per live session) + launchers
BIN_INC="config/includes.chroot/usr/bin"
APP_INC="config/includes.chroot/usr/share/applications"
AUTO_INC="config/includes.chroot/etc/xdg/autostart"
DOC_LINUXIUM="config/includes.chroot/usr/share/doc/linuxium"
mkdir -p "$BIN_INC" "$APP_INC" "$AUTO_INC" "$DOC_LINUXIUM"

cat > "$BIN_INC/linuxium-welcome" <<'PYEOF'
#!/usr/bin/env python3
"""Linuxium Welcome - first-run window for the live session (GTK 3)."""
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, Gtk  # noqa: E402

LOGO = "/usr/share/pixmaps/linuxium.png"
DISABLE_FILE = Path.home() / ".config" / "linuxium" / "no-welcome"


def launch(parent, argv, what):
    try:
        subprocess.Popen(
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (FileNotFoundError, OSError) as exc:
        dialog = Gtk.MessageDialog(
            transient_for=parent,
            modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK,
            text="Could not start %s" % what,
        )
        dialog.format_secondary_text(str(exc))
        dialog.run()
        dialog.destroy()


class Welcome(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="Welcome to Linuxium")
        self.set_default_size(780, 580)
        self.set_border_width(18)
        self.connect("destroy", Gtk.main_quit)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(outer)

        # Header: logo + titles
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, 96, 96, True)
            header.pack_start(Gtk.Image.new_from_pixbuf(pixbuf), False, False, 0)
        except Exception:
            pass
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title = Gtk.Label()
        title.set_markup(
            '<span size="xx-large" weight="bold">Welcome to Linuxium :)</span>'
        )
        title.set_halign(Gtk.Align.START)
        subtitle = Gtk.Label()
        subtitle.set_markup('<span size="large">luv from playerz</span>')
        subtitle.set_halign(Gtk.Align.START)
        titles.pack_start(title, False, False, 0)
        titles.pack_start(subtitle, False, False, 0)
        header.pack_start(titles, False, False, 0)
        outer.pack_start(header, False, False, 0)

        # What you can do
        info = Gtk.Label()
        info.set_markup(
            "<b>Try it first:</b> you are running Linuxium live from the ISO. "
            "Everything works, but nothing is saved when you reboot "
            "(unless you set up persistence).\n"
            "<b>Install it:</b> press <i>Install Linuxium</i> and the "
            "Calamares installer will walk you through language, keyboard, "
            "disk and user setup, step by step.\n"
            "<b>Explore:</b> Firefox, LibreOffice, VLC and the file manager "
            "are ready in the menu at the bottom left.\n"
            "<b>Get online:</b> click the network icon in the panel to join "
            "Wi-Fi.\n"
            "<b>Make it yours:</b> Settings &gt; Backgrounds has new "
            "wallpapers, from New York City to a Nebula."
        )
        info.set_line_wrap(True)
        info.set_xalign(0)
        outer.pack_start(info, False, False, 0)

        # Buttons
        grid = Gtk.Grid(column_spacing=10, row_spacing=10)
        grid.set_column_homogeneous(True)
        outer.pack_start(grid, False, False, 6)

        install = Gtk.Button(label="Install Linuxium")
        install.get_style_context().add_class("suggested-action")
        install.connect("clicked", self.on_install)
        grid.attach(install, 0, 0, 1, 1)

        try_it = Gtk.Button(label="Try Linuxium first")
        try_it.connect("clicked", lambda _b: self.destroy())
        grid.attach(try_it, 1, 0, 1, 1)

        actions = [
            ("Open Files", ["nemo", str(Path.home())], 0, 1),
            ("Browse the web", ["firefox-esr"], 1, 1),
            ("Change wallpaper", ["cinnamon-settings", "backgrounds"], 0, 2),
            ("Open Terminal", ["gnome-terminal"], 1, 2),
            ("System Settings", ["cinnamon-settings"], 0, 3),
        ]
        for label, argv, col, row in actions:
            button = Gtk.Button(label=label)
            button.connect(
                "clicked",
                lambda _b, a=argv, lbl=label: launch(self, a, lbl),
            )
            grid.attach(button, col, row, 1, 1)

        about = Gtk.Button(label="About Linuxium")
        about.connect("clicked", self.on_about)
        grid.attach(about, 1, 3, 1, 1)

        # Don't-show-again (only persists on a persistent live USB / after
        # install the welcome app simply never autostarts)
        toggle = Gtk.CheckButton(label="Don't show this again")
        toggle.connect("toggled", self.on_toggle)
        outer.pack_start(toggle, False, False, 0)

        footer = Gtk.Label(
            label="Tip: if the screen ever stays black in a virtual machine, "
            "reboot and pick the failsafe entry in the boot menu."
        )
        footer.set_line_wrap(True)
        footer.set_xalign(0)
        outer.pack_start(footer, False, False, 0)

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
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Install Linuxium to a disk?",
        )
        dialog.format_secondary_text(
            "The Calamares installer will guide you through every step and "
            "show a summary before anything is written. If you choose "
            "'Erase disk' in the installer, everything on that disk will "
            "be deleted - make sure you pick the right disk."
        )
        answer = dialog.run()
        dialog.destroy()
        if answer == Gtk.ResponseType.OK:
            launch(self, ["install-linuxium"], "the installer")
            self.destroy()

    def on_about(self, _button):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text="Linuxium - welcome :)",
        )
        dialog.format_secondary_text(
            "Linuxium is a friendly Debian 12 + Cinnamon live system.\n\n"
            "Wallpaper photo credits: "
            "/usr/share/doc/linuxium-wallpapers/CREDITS.txt\n"
            "Installer: Calamares (Debian settings, Linuxium branding)\n\n"
            "luv from playerz"
        )
        dialog.run()
        dialog.destroy()


def main():
    if DISABLE_FILE.exists() and "--force" not in sys.argv:
        return 0
    window = Welcome()
    window.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$BIN_INC/linuxium-welcome"

cat > "$BIN_INC/linuxium-welcome-autostart" <<'EOF'
#!/bin/sh
# Show the Welcome window once per LIVE session only.
# An installed system has neither "boot=live" on its kernel command line
# nor /run/live/medium, so this quietly does nothing after installation.
case " $(cat /proc/cmdline 2>/dev/null) " in
  *" boot=live "*) : ;;
  *) [ -d /run/live/medium ] || exit 0 ;;
esac
[ -e "$HOME/.config/linuxium/no-welcome" ] && exit 0
lock="${XDG_RUNTIME_DIR:-/tmp}/linuxium-welcome.lock"
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM
# Give the desktop a moment to come up first.
sleep 3
exec /usr/bin/linuxium-welcome
EOF
chmod +x "$BIN_INC/linuxium-welcome-autostart"

cat > "$BIN_INC/install-linuxium" <<'EOF'
#!/bin/sh
# Preferred entry point is Debian's wrapper (handles the stale live
# /etc/fstab, X access for root and HiDPI scaling, then runs
# "pkexec calamares"). Fall back to plain pkexec if it is missing.
if [ -x /usr/bin/install-debian ]; then
  exec /usr/bin/install-debian
fi
export QT_AUTO_SCREEN_SCALE_FACTOR=1
exec pkexec calamares
EOF
chmod +x "$BIN_INC/install-linuxium"

cat > "$APP_INC/linuxium-welcome.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Linuxium Welcome
Comment=Welcome to Linuxium :) - try, install and explore
Exec=linuxium-welcome
Icon=linuxium
Terminal=false
Categories=System;Utility;
StartupNotify=true
EOF

cat > "$APP_INC/install-linuxium.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Install Linuxium
GenericName=Calamares Installer
Comment=Install Linuxium to your computer with the Calamares installer
Exec=install-linuxium
Icon=linuxium
Terminal=false
Categories=Qt;System;
StartupWMClass=calamares
StartupNotify=true
EOF

cat > "$AUTO_INC/linuxium-welcome.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Linuxium Welcome
Comment=Show the Linuxium welcome window in the live session
Exec=linuxium-welcome-autostart
Icon=linuxium
Terminal=false
NoDisplay=true
OnlyShowIn=Cinnamon;X-Cinnamon;
X-GNOME-Autostart-enabled=true
EOF

cat > "$DOC_LINUXIUM/README.md" <<EOF
# Linuxium ${LINUXIUM_VERSION}

Welcome to Linuxium :) luv from playerz

* Live user: **linuxium** (automatic login, passwordless sudo in the live session)
* Installer: **Install Linuxium** (Calamares) in the menu / welcome window,
  or the classic Debian installer from the ISO boot menu.
* Wallpapers: Settings > Backgrounds (credits in
  /usr/share/doc/linuxium-wallpapers/CREDITS.txt)

VirtualBox note: the kernel message
"[drm:vmw_host_log [vmwgfx]] *ERROR* Failed to send host log message"
is a harmless quirk of the vmwgfx driver running on VirtualBox's VMSVGA
graphics - the machine keeps booting normally.

For a desktop in VirtualBox use: 2+ CPUs, 4+ GB RAM, graphics controller
VMSVGA, 128 MB video memory, and 3D acceleration OFF. Linuxium's live
session automatically uses Cinnamon's software-rendering session in
VirtualBox (boot with linuxium-session=cinnamon to force the 3D session
anyway). If a VM ever stops at a black screen, pick the failsafe entry
in the boot menu - it uses software rendering with Xorg's firmware-
framebuffer fallback drivers. The boot menu's classic *Graphical
installer* is Debian Installer, not Calamares; on VirtualBox in EFI
mode its GTK frontend hits Debian bug #1036310, so set System ->
Acceleration -> Paravirtualization Interface to None (or Legacy) while
using that entry, or simply boot Live and use Install Linuxium.
EOF

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

# Deliberately do NOT set [org/cinnamon/theme] name='Adwaita' here.
# Adwaita is a GTK/window theme; it does not ship a Cinnamon shell theme
# (no cinnamon/cinnamon.css). Leaving the key unset uses Cinnamon's
# built-in shell theme, which always exists.
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
greeter-session=lightdm-gtk-greeter
user-session=cinnamon
EOF

# 8b. Live-only graphics safety net (runs at live boot via live-config;
#     it writes only to the live overlay, never into an installed system).
#
# VirtualBox + Cinnamon's 3D compositor is a well-known black-screen combo:
# X starts, the pointer moves, but the desktop never paints. This component
#   * uses Cinnamon's software-rendering session ("cinnamon2d") when it
#     detects VirtualBox, or when the boot line says linuxium-session=cinnamon2d
#     (our failsafe boot entry does, together with nomodeset);
#   * forces the generic "modesetting" X driver in VirtualBox instead of
#     the legacy xf86-video-vmware driver that video-all pulls in, but only
#     when a DRM/KMS card actually exists, so Xorg can still auto-fallback
#     to fbdev/vesa on firmware-framebuffer boots;
#   * explicitly tells LightDM NOT to wait for logind's "graphical seat"
#     flag. That check sounds safer, but on some VM graphics stacks the
#     flag never becomes true even though X would work, leaving a booted
#     system on a text console with LightDM idle. Plymouth has already
#     brought the DRM driver up by this point on the live image.
# Real hardware keeps the normal accelerated "cinnamon" session. To force
# the 3D session in VirtualBox anyway, boot with:  linuxium-session=cinnamon
LIVE_CFG_DIR="config/includes.chroot/lib/live/config"
mkdir -p "$LIVE_CFG_DIR"
cat > "$LIVE_CFG_DIR/0190-linuxium-graphics" <<'LIVEEOF'
#!/bin/sh

. /lib/live/config.sh

#set -e

LINUXIUM_SESSION=""
LINUXIUM_XORG_DRIVER=""
LINUXIUM_NOMODESET=""

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

			nomodeset)
				LINUXIUM_NOMODESET="true"
				;;
		esac
	done
}

Init ()
{
	if ! pkg_is_installed "lightdm" || \
	   component_was_executed "linuxium-graphics"
	then
		exit 0
	fi

	printf '%s' " linuxium-graphics"
}

IsVirtualBox ()
{
	_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
	if [ "${_VIRT}" = "oracle" ]
	then
		return 0
	fi

	for _DMI in product_name sys_vendor
	do
		if grep -qis "virtualbox" "/sys/devices/virtual/dmi/id/${_DMI}" 2>/dev/null
		then
			return 0
		fi
	done

	return 1
}

Config ()
{
	_IS_VBOX=0
	if IsVirtualBox
	then
		_IS_VBOX=1
	fi

	# VirtualBox gets the stable software-rendering session by default.
	if [ -z "${LINUXIUM_SESSION}" ] && [ "${_IS_VBOX}" = "1" ]
	then
		LINUXIUM_SESSION="cinnamon2d"
	fi

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
		# VirtualBox graphics stacks it never flips true and LightDM
		# simply waits forever, which looks like "only the terminal
		# works" even though the system finished booting.
		echo "logind-check-graphical=false"
		echo "start-default-seat=true"
		echo ""
		echo "[Seat:*]"
		echo "greeter-session=lightdm-gtk-greeter"
		if [ -n "${LINUXIUM_SESSION}" ]
		then
			echo "user-session=${LINUXIUM_SESSION}"
			echo "autologin-session=${LINUXIUM_SESSION}"
		fi
	} > /etc/lightdm/lightdm.conf.d/90-linuxium-live.conf

	# In VirtualBox prefer the kernel's KMS drivers (vmwgfx/vboxvideo)
	# through the generic modesetting X driver. Skipped when the user
	# already picked an X driver or uses nomodeset, and skipped when no
	# DRM card exists so Xorg's fbdev/vesa auto-fallback remains available.
	_HAS_KMS=""
	for _CARD in /sys/class/drm/card[0-9]*
	do
		if [ -e "${_CARD}" ]
		then
			_HAS_KMS="true"
			break
		fi
	done

	if [ "${_IS_VBOX}" = "1" ] && [ -n "${_HAS_KMS}" ] && [ -z "${LINUXIUM_XORG_DRIVER}" ] && [ -z "${LINUXIUM_NOMODESET}" ]
	then
		mkdir -p /etc/X11/xorg.conf.d
		cat > /etc/X11/xorg.conf.d/20-linuxium-virtualbox.conf <<'XORGEOF'
Section "Device"
	Identifier	"Linuxium VirtualBox graphics"
	Driver		"modesetting"
EndSection
XORGEOF
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

# Branding (ID stays "debian" so tools - including Debian's signed GRUB
# and the Calamares helpers, which look for the "bookworm" release -
# keep working)
cat > /etc/os-release <<'OSR'
PRETTY_NAME="Linuxium 1.1"
NAME="Linuxium"
VERSION_ID="1.1"
VERSION="1.1 (Playerz)"
VERSION_CODENAME=bookworm
ID=debian
ID_LIKE=debian
HOME_URL="https://example.com/linuxium"
BUG_REPORT_URL="https://bugs.debian.org/"
OSR

printf 'Linuxium 1.1 \\n \\l\n\n' > /etc/issue
echo "Linuxium 1.1" > /etc/issue.net

# Make sure LightDM is the display manager AND that systemd really boots
# to the graphical target. Do not rely only on the lightdm package's
# postinst/debconf dance having run in just the right order inside the
# live-build chroot; create the two decisive links explicitly.
mkdir -p /etc/X11 /etc/systemd/system
echo /usr/sbin/lightdm > /etc/X11/default-display-manager
ln -sfn /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
ln -sfn /lib/systemd/system/graphical.target /etc/systemd/system/default.target

# Boot splash: select the theme and rebuild the initramfs so it is included
plymouth-set-default-theme linuxium
update-initramfs -u -k all

# Neofetch: show the Linuxium logo for every new user. Bookworm's
# Neofetch needs ImageMagick present even for the chafa backend, and a
# graphical terminal whose pixel size it can detect (xdotool/x11-utils
# are in the package list for exactly this); on a bare Linux VT it has
# no pixel dimensions and falls back to ASCII art by design.
mkdir -p /etc/skel/.config/neofetch
if neofetch --print_config > /tmp/nf.conf 2>/dev/null && [ -s /tmp/nf.conf ]; then
  sed -i 's|^image_backend=.*|image_backend="chafa"|; s|^image_source=.*|image_source="/usr/share/linuxium/logo.png"|' /tmp/nf.conf
  mv /tmp/nf.conf /etc/skel/.config/neofetch/config.conf
else
  printf 'image_backend="chafa"\nimage_source="/usr/share/linuxium/logo.png"\n' > /etc/skel/.config/neofetch/config.conf
fi
# The config is sourced top-to-bottom; append the decisive values so a
# future Neofetch default-config format change cannot silently undo them.
cat >> /etc/skel/.config/neofetch/config.conf <<'NF'

# Linuxium overrides (valid CLI test: neofetch --chafa /usr/share/linuxium/logo.png)
image_backend="chafa"
image_source="/usr/share/linuxium/logo.png"
NF

# ---- Calamares: keep Debian's tested module sequence/helpers, rebrand ----
# NOTE: /etc/calamares (lowercase) is the correct path on Debian 12.
if [ -f /etc/calamares/settings.conf ]; then
  sed -i 's|^branding:.*|branding: linuxium|' /etc/calamares/settings.conf
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
if [ -f /etc/calamares/modules/welcome.conf ]; then
  sed -i -E 's|(requiredStorage:[[:space:]]*)[0-9]+|\116|' /etc/calamares/modules/welcome.conf
fi

# Remove the installer itself from the installed system too (Debian's
# default list only removes calamares-settings-debian).
if [ -f /etc/calamares/modules/packages.conf ]; then
  if ! grep -q "'calamares'" /etc/calamares/modules/packages.conf; then
    sed -i "/calamares-settings-debian/a\\      - 'calamares'" /etc/calamares/modules/packages.conf
  fi
fi

# Keep the same archive areas on the installed system as on the live ISO,
# so the firmware/contrib packages keep receiving updates.
if [ -f /usr/sbin/sources-final ]; then
  sed -i 's| main non-free-firmware| main contrib non-free non-free-firmware|g' /usr/sbin/sources-final
fi

# We ship our own "Install Linuxium" launcher + Welcome window, so hide
# Debian's "Install Debian" menu entry and its desktop-icon autostart.
if [ -f /usr/share/applications/install-debian.desktop ]; then
  printf '\nNoDisplay=true\n' >> /usr/share/applications/install-debian.desktop
fi
if [ -f /etc/xdg/autostart/calamares-desktop-icon.desktop ]; then
  printf '\nHidden=true\n' >> /etc/xdg/autostart/calamares-desktop-icon.desktop
fi

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
EOF
chmod +x config/hooks/normal/0100-linuxium.hook.chroot

# 10. Build the ISO
"${SUDO[@]}" lb build

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

# Secure Boot: the firmware loads BOOTX64.EFI first - that must be the
# Microsoft-signed shim, and GRUBX64.EFI must carry Debian's signature.
VERIFY_DIR="$(mktemp -d)"
if xorriso -osirrox on -indev "$ISO" -extract /boot/grub/efi.img "$VERIFY_DIR/efi.img" >/dev/null 2>&1 \
   && [ -s "$VERIFY_DIR/efi.img" ]; then
  if ! mcopy -n -i "$VERIFY_DIR/efi.img" "::/EFI/BOOT/BOOTX64.EFI" "$VERIFY_DIR/BOOTX64.EFI" 2>/dev/null \
     || ! mcopy -n -i "$VERIFY_DIR/efi.img" "::/EFI/BOOT/GRUBX64.EFI" "$VERIFY_DIR/GRUBX64.EFI" 2>/dev/null; then
    echo "ERROR: could not extract BOOTX64.EFI/GRUBX64.EFI from efi.img. Contents:" >&2
    mdir -i "$VERIFY_DIR/efi.img" -/ :: >&2 || true
    exit 1
  fi
  if command -v sbverify >/dev/null 2>&1; then
    BOOT_SIG="$(sbverify --list "$VERIFY_DIR/BOOTX64.EFI" 2>/dev/null || true)"
    GRUB_SIG="$(sbverify --list "$VERIFY_DIR/GRUBX64.EFI" 2>/dev/null || true)"
    echo "EFI signatures:"
    printf '%s\n' "$BOOT_SIG" | sed 's/^/  BOOTX64.EFI: /'
    printf '%s\n' "$GRUB_SIG" | sed 's/^/  GRUBX64.EFI: /'
    if ! grep -qi "Microsoft" <<<"$BOOT_SIG"; then
      echo "ERROR: BOOTX64.EFI is not the Microsoft-signed shim - Secure Boot will reject this ISO." >&2
      exit 1
    fi
    if ! grep -qi "Debian" <<<"$GRUB_SIG"; then
      echo "ERROR: GRUBX64.EFI is not Debian-signed - Secure Boot will reject this ISO." >&2
      exit 1
    fi
    echo "Secure Boot check: OK (Microsoft-signed shim + Debian-signed GRUB)"
  else
    echo "WARNING: sbverify (sbsigntool) not found - skipping EFI signature check" >&2
  fi
else
  echo "ERROR: could not extract /boot/grub/efi.img from $ISO" >&2
  exit 1
fi

sha256sum "$ISO" > "${ISO}.sha256"

echo
echo "Done. ISO: $(pwd)/${ISO#./}"
echo "Checksum:  $(pwd)/${ISO#./}.sha256"
echo "Test it with:"
echo "  BIOS/MBR:  qemu-system-x86_64 -m 4096 -enable-kvm -cdrom ${ISO#./}"
echo "  UEFI+SB:   qemu-system-x86_64 -m 4096 -enable-kvm -machine q35 \\"
echo "               -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \\"
echo "               -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd -cdrom ${ISO#./}"
echo "             (copy /usr/share/OVMF/OVMF_VARS_4M.fd to /tmp/OVMF_VARS.fd first)"
