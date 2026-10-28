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
  live-build debootstrap cpio squashfs-tools xorriso apt-utils \
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

# 4. Package list
mkdir -p config/package-lists
cat > config/package-lists/linuxium.list.chroot <<'EOF'
# Init system: without these the live image can boot to
# "No init found" because /sbin/init is missing from the squashfs.
# Name the decisive pieces explicitly instead of trusting another
# package's Depends/Recommends to keep bringing them along forever.
init
systemd
systemd-sysv
udev
dbus
kmod
initramfs-tools

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
fonts-noto
fonts-dejavu
live-boot
live-config
live-config-systemd
# Critical live-config helpers. live-config only *Recommends* several of
# these, but 0030-user-setup silently skips creating the live user if
# user-setup is absent, locales are needed by 0050-locales, and
# console-setup provides setupcon/ckbcomp for console + installer use.
user-setup
locales
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
"${IM[@]}" "$LOGO" -auto-orient -resize 512x512 -strip \
  "PNG32:config/includes.chroot/usr/share/pixmaps/linuxium.png"

# 5e. Boot splash (Plymouth theme using the logo)
PLY_DIR="config/includes.chroot/usr/share/plymouth/themes/linuxium"
mkdir -p "$PLY_DIR"
"${IM[@]}" "$LOGO" -auto-orient -background white -alpha remove -alpha off \
  -resize 256x256 -strip "PNG24:$PLY_DIR/logo.png"

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
# The callbacks below are not decoration: a Plymouth script theme without
# password/message handlers gives an encrypted installed system no visible
# unlock prompt, which looks exactly like a boot hang on the logo.
cat > "$PLY_DIR/linuxium.script" <<'EOF'
Window.SetBackgroundTopColor(1, 1, 1);
Window.SetBackgroundBottomColor(1, 1, 1);

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetX() + (Window.GetWidth() - logo.image.GetWidth()) / 2);
logo.sprite.SetY(Window.GetY() + (Window.GetHeight() - logo.image.GetHeight()) / 2);

prompt_sprite = Sprite();
prompt_sprite.SetPosition(0, 0, 10000);
prompt_sprite.SetOpacity(0);

entry_sprite = Sprite();
entry_sprite.SetPosition(0, 0, 10001);
entry_sprite.SetOpacity(0);

message_sprite = Sprite();
message_sprite.SetPosition(0, 0, 10002);
message_sprite.SetOpacity(0);

fun hide_dialog()
{
	prompt_sprite.SetOpacity(0);
	entry_sprite.SetOpacity(0);
}

fun display_normal_callback()
{
	hide_dialog();
}

fun display_password_callback(prompt_text, bullets)
{
	prompt_image = Image.Text(prompt_text, 0, 0, 0);
	prompt_x = Math.Max(Window.GetX(),
		Window.GetX() + (Window.GetWidth() - prompt_image.GetWidth()) / 2);
	prompt_y = Window.GetY() +
		(Window.GetHeight() + logo.image.GetHeight()) / 2 + 24;
	prompt_sprite.SetImage(prompt_image);
	prompt_sprite.SetPosition(prompt_x, prompt_y, 10000);
	prompt_sprite.SetOpacity(1);

	bullet_text = "";
	for (bullet_index = 0; bullet_index < bullets; bullet_index++)
		bullet_text += "*";

	if (bullets > 0)
	{
		entry_image = Image.Text(bullet_text, 0, 0, 0);
		entry_x = Math.Max(Window.GetX(),
			Window.GetX() + (Window.GetWidth() - entry_image.GetWidth()) / 2);
		entry_y = prompt_y + prompt_image.GetHeight() + 8;
		entry_sprite.SetImage(entry_image);
		entry_sprite.SetPosition(entry_x, entry_y, 10001);
		entry_sprite.SetOpacity(1);
	}
	else
	{
		entry_sprite.SetOpacity(0);
	}
}

fun display_question_callback(prompt_text, entry_text)
{
	question_image = Image.Text(prompt_text + " " + entry_text, 0, 0, 0);
	question_x = Math.Max(Window.GetX(),
		Window.GetX() + (Window.GetWidth() - question_image.GetWidth()) / 2);
	question_y = Window.GetY() +
		(Window.GetHeight() + logo.image.GetHeight()) / 2 + 24;
	prompt_sprite.SetImage(question_image);
	prompt_sprite.SetPosition(question_x, question_y, 10000);
	prompt_sprite.SetOpacity(1);
	entry_sprite.SetOpacity(0);
}

fun display_message_callback(message_text)
{
	message_image = Image.Text(message_text, 0, 0, 0);
	message_x = Math.Max(Window.GetX(),
		Window.GetX() + (Window.GetWidth() - message_image.GetWidth()) / 2);
	message_y = Window.GetY() + Window.GetHeight() * 0.85;
	message_sprite.SetImage(message_image);
	message_sprite.SetPosition(message_x, message_y, 10002);
	message_sprite.SetOpacity(1);
}

fun hide_message_callback(message_text)
{
	message_sprite.SetOpacity(0);
}

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
# Do NOT exec here: exec replaces this shell, so the EXIT trap above would
# never run and the lock directory would leak, blocking the welcome window
# for the rest of the session. Run it as a child and exit with its status
# so the trap removes the lock when it closes.
/usr/bin/linuxium-welcome
exit $?
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
TryExec=linuxium-welcome
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
TryExec=calamares
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

* Live user: **linuxium** (automatic login and passwordless sudo; if a
  text-console or manual screen-lock prompt asks for its password, it is
  **live**)
* Installer: **Install Linuxium** (Calamares) in the menu / welcome window,
  or the classic Debian installer from the ISO boot menu.
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
using that entry, or simply boot Live and use Install Linuxium.
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
gtk-theme='CBlack'

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
EOF

# 7. Login screen background
mkdir -p config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d/50-linuxium.conf <<'EOF'
[greeter]
background=/usr/share/backgrounds/linuxium/linuxium.png
user-background=false
# Match the session theme (section 5j/6); dconf defaults do not apply
# to the greeter's own user, so set its GTK theme here explicitly.
theme-name=CBlack
# Put the login window on the monitor that actually has the pointer;
# harmless on one screen, avoids an "empty" looking second screen in VMs.
active-monitor=#cursor
EOF

# 8. Live user gets autologin into Cinnamon. The [LightDM] guards are
# static on purpose: they must survive into an installed system too.
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/50-linuxium.conf <<'EOF'
[LightDM]
logind-check-graphical=false
start-default-seat=true

[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=cinnamon
EOF

# 8a. Permanent VM graphics safeguards (present in the live image AND in
# an installed system). Earlier builds put the VirtualBox workarounds only
# in the live overlay, so a system that looked fine live could black-screen
# again on its first installed boot. Two small, narrow pieces fix that:
#
#  1. A static Xorg OutputClass that binds X to the generic modesetting
#     driver ONLY when the kernel DRM driver is vmwgfx or vboxvideo.
#     Because Xorg does the matching when it starts, this has none of the
#     "has udev created the DRM card yet?" timing race of detecting the
#     GPU from an early-boot script. It also overrides the legacy
#     xf86-video-vmware autoload decision without touching real hardware.
#
#  2. A tiny oneshot service that runs before LightDM every boot and
#     selects Cinnamon's software-rendering session when (and only when)
#     systemd/DMI say this is VirtualBox. It maintains a clearly-marked
#     final block in /etc/lightdm/lightdm.conf because LightDM reads that
#     file *after* lightdm.conf.d/*.conf, and Calamares writes the normal
#     3D session there during installation. It removes only its own block
#     on non-VirtualBox boots, and always exits 0.
mkdir -p config/includes.chroot/etc/X11/xorg.conf.d
cat > config/includes.chroot/etc/X11/xorg.conf.d/20-linuxium-vm-kms.conf <<'EOF'
# Linuxium: use the generic KMS/modesetting X driver for the virtual GPUs
# that VirtualBox exposes. No match means no effect on any other hardware.
Section "OutputClass"
	Identifier	"Linuxium VMware/VirtualBox SVGA KMS"
	MatchDriver	"vmwgfx"
	Driver		"modesetting"
EndSection

Section "OutputClass"
	Identifier	"Linuxium VirtualBox Graphics KMS"
	MatchDriver	"vboxvideo"
	Driver		"modesetting"
EndSection
EOF

mkdir -p config/includes.chroot/usr/sbin
cat > config/includes.chroot/usr/sbin/linuxium-virtualbox-graphics <<'EOF'
#!/bin/sh
# Linuxium: keep VirtualBox on Cinnamon's software-rendering session.
# This must never be able to break a boot: every path exits 0.

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

is_virtualbox()
{
	virt="$(systemd-detect-virt 2>/dev/null || true)"
	[ "$virt" = "oracle" ] && return 0

	for dmi in product_name sys_vendor
	do
		if grep -qis "virtualbox" "/sys/devices/virtual/dmi/id/$dmi" 2>/dev/null
		then
			return 0
		fi
	done

	return 1
}

session=""

# An explicit boot choice wins over automatic detection.
cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
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

if [ -z "$session" ] && is_virtualbox
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
Description=Linuxium VirtualBox graphics session safeguard
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
# VirtualBox + Cinnamon's 3D compositor is a well-known black-screen combo:
# X starts, the pointer moves, but the desktop never paints. This component
#   * uses Cinnamon's software-rendering session ("cinnamon2d") when it
#     detects VirtualBox, or when the boot line says linuxium-session=cinnamon2d
#     (our failsafe boot entry does, together with nomodeset);
#   * leaves X-driver selection to the permanent OutputClass file from
#     section 8a, except when the user explicitly chose an X driver or
#     nomodeset, in which case it hides that file for this live boot only;
#   * keeps Cinnamon from going idle or activating its locked
#     screensaver in this live session: its stock 15-minute idle lock
#     would otherwise demand Debian live's preset password in the
#     middle of testing or installing;
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
# Linuxium: use the generic KMS/modesetting X driver for the virtual GPUs
# that VirtualBox exposes. No match means no effect on any other hardware.
Section "OutputClass"
	Identifier	"Linuxium VMware/VirtualBox SVGA KMS"
	MatchDriver	"vmwgfx"
	Driver		"modesetting"
EndSection

Section "OutputClass"
	Identifier	"Linuxium VirtualBox Graphics KMS"
	MatchDriver	"vboxvideo"
	Driver		"modesetting"
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

# A syntactically successful ISO is not necessarily a bootable system.
# Inspect the live squashfs itself for the pieces that decide whether a
# desktop can appear at all: init, display manager, both Cinnamon
# sessions, live-config safeguard, installer, Plymouth and kernel/initrd.
if [ -f binary/live/filesystem.squashfs ]; then
  ROOTFS_LISTING="$("${SUDO[@]}" unsquashfs -ll binary/live/filesystem.squashfs 2>/dev/null || true)"
  for root_part in \
    "/sbin/init" "/usr/sbin/lightdm" "/usr/bin/calamares" \
    "/usr/share/xsessions/cinnamon.desktop" \
    "/usr/share/xsessions/cinnamon2d.desktop" \
    "/live/config/0190-linuxium-graphics" \
    "/usr/sbin/linuxium-virtualbox-graphics" \
    "/etc/systemd/system/linuxium-virtualbox-graphics.service" \
    "/etc/systemd/system/multi-user.target.wants/linuxium-virtualbox-graphics.service" \
    "/etc/lightdm/lightdm.conf.d/50-linuxium.conf" \
    "/etc/X11/xorg.conf.d/20-linuxium-vm-kms.conf" \
    "/usr/share/initramfs-tools/hooks/cryptroot" \
    "/usr/share/plymouth/themes/linuxium/linuxium.plymouth" \
    "/usr/share/plymouth/themes/linuxium/linuxium.script" \
    "/usr/share/themes/CBlack/index.theme" \
    "/usr/share/themes/CBlack/cinnamon/cinnamon.css" \
    "/usr/share/themes/CBlack/gtk-3.0/gtk.css" \
    "/boot/vmlinuz-" "/boot/initrd.img-"; do
    if ! grep -Fq "$root_part" <<<"$ROOTFS_LISTING"; then
      echo "ERROR: '$root_part' is missing from the live root filesystem" >&2
      exit 1
    fi
  done
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

echo
echo "Done. ISO: $(pwd)/${ISO#./}"
echo "Checksum:  $(pwd)/${ISO#./}.sha256"
echo "Test it with:"
echo "  BIOS/MBR:  qemu-system-x86_64 -m 4096 -enable-kvm -cdrom ${ISO#./}"
echo "  UEFI+SB:   qemu-system-x86_64 -m 4096 -enable-kvm -machine q35 \\"
echo "               -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \\"
echo "               -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd -cdrom ${ISO#./}"
echo "             (copy /usr/share/OVMF/OVMF_VARS_4M.fd to /tmp/OVMF_VARS.fd first)"
