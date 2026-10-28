# Linuxium

**Linuxium** is a hobby Linux distribution built on top of **Debian 12 "Bookworm"** and featuring the **Cinnamon desktop environment**. It aims to give you a clean, familiar, easy-to-use desktop with a simple dark look, the Linux penguin (Tux) as its wallpaper, and everything you need for everyday computing right after you install it.

Linuxium is a student-made project. It is not affiliated with Debian, the Cinnamon project, Linux Mint, or any other distribution. It is an independent remix that exists to learn how Linux distributions are put together, and to share the result.

---

## Table of Contents

1. [What is Linuxium?](#what-is-linuxium)
2. [Features](#features)
3. [How Linuxium is made](#how-linuxium-is-made)
4. [What's inside](#whats-inside)
5. [System requirements](#system-requirements)
6. [Getting Linuxium](#getting-linuxium)
7. [Building Linuxium yourself](#building-linuxium-yourself)
8. [Trying it safely](#trying-it-safely)
9. [Customizing Linuxium](#customizing-linuxium)
10. [Project structure](#project-structure)
11. [Known limitations](#known-limitations)
12. [Roadmap](#roadmap)
13. [Credits and acknowledgements](#credits-and-acknowledgements)
14. [Licensing and trademarks](#licensing-and-trademarks)

---

## What is Linuxium?

A Linux "distribution" (or "distro") is a complete operating system made by combining many separate pieces of software: the kernel, system tools, a desktop environment, and applications. Almost no distro is written from scratch. Instead, distro makers choose, configure, and package existing open-source software into something that works well together.

Linuxium follows that tradition. It takes a very stable foundation (Debian), adds a traditional and friendly desktop (Cinnamon), applies a custom look and some branding, and packages everything into a bootable ISO image that you can try from a USB stick or install on a computer.

The goals of the project are:

- **Simple:** a desktop that feels familiar if you have used Windows or any traditional desktop before, with a panel, a menu, and a system tray.
- **Stable:** built on Debian, which is known for reliability and a careful release process.
- **Clean:** a tidy default look with a dark gray desktop and the Linux penguin in the center.
- **Educational:** the entire build is done with one readable script, so anyone can see exactly how the distro is made and change it.

---

## Features

- **Cinnamon desktop** with a classic panel layout, a start-style menu, a system tray, and desktop icons.
- **Debian 12 base** with access to the huge Debian software archive.
- **Live session:** boot from USB or DVD and try Linuxium without changing anything on your computer.
- **Installer included:** install Linuxium to your hard drive from the live session.
- **Custom wallpaper and login screen:** the Tux penguin on a dark gray background, used on both the desktop and the login screen.
- **Nemo file manager** with tabs, bookmarks, and a clean interface.
- **Firefox ESR** for browsing the web.
- **LibreOffice** (Writer and Calc) for documents and spreadsheets.
- **VLC** for audio and video playback.
- **Modern audio** through PipeWire.
- **Network management** through NetworkManager, with Wi-Fi and Ethernet support and a tray applet.
- **Extra firmware packages** for common Wi-Fi, graphics, and hardware devices.
- **Linuxium branding** in the system information files so that tools report the distro as Linuxium.

---

## How Linuxium is made

Linuxium is built from several layers. Each layer is a separate open-source project, and Linuxium simply brings them together.

### 1. The Linux kernel

At the very bottom is the **Linux kernel**, created by Linus Torvalds in 1991 and developed since then by thousands of contributors around the world. The kernel talks directly to your hardware: the processor, memory, storage, graphics card, network adapters, and so on. It lets programs run safely and share those resources. Linuxium uses the kernel provided by Debian, which is well tested and receives security updates.

### 2. GNU tools and system software

On top of the kernel sit the core system tools, many of which come from the **GNU project**: the shell (Bash), core utilities such as `ls`, `cp`, and `mv`, the C library, compilers, and more. Together with the kernel, these make up what many people call "GNU/Linux". Linuxium also uses **systemd** as its init system, which starts up and manages system services.

### 3. Debian

**Debian** is one of the oldest and most respected Linux distributions, and it is the base of many others, including Ubuntu and Linux Mint's Debian edition. Linuxium uses Debian 12 "Bookworm" and its package archive. This means that:

- Software is installed and updated with the `apt` package manager.
- Security updates come from the Debian security team.
- Tens of thousands of packages are available to install.

Linuxium enables the `main`, `contrib`, `non-free`, and `non-free-firmware` areas of the Debian archive so that hardware firmware (such as for Wi-Fi cards) is available on more machines.

### 4. The X Window System and the login manager

Graphical programs need a display server. Linuxium uses the **X.org** display server with the **LightDM** login manager. LightDM shows the login screen and then starts the Cinnamon session. In Linuxium the login screen uses the same penguin background as the desktop.

### 5. The Cinnamon desktop environment

**Cinnamon** is the desktop that you actually see and use. It was created by the Linux Mint team as a modern continuation of the traditional desktop design, and it is now used by many distributions. It provides the panel, the menu, the window manager (Muffin), the settings app, and the desktop effects. Linuxium installs the full `cinnamon-desktop-environment` package set, which includes:

- **Muffin**, the window manager.
- **Nemo**, the file manager.
- **Cinnamon Settings**, the control panel.
- **Applets and desklets**, small tools for the panel and desktop.

### 6. Applications

Finally, Linuxium installs a small set of everyday applications: Firefox ESR, LibreOffice, VLC, a text editor, an image viewer, an archive manager, a terminal, and a system monitor. You can install anything else from the Debian archive with `apt`.

### 7. The build system: live-build

The ISO image itself is created with **live-build**, the official Debian tool for making live system images. You describe what you want in configuration files, and live-build does the following:

1. Uses **debootstrap** to create a minimal Debian system in a temporary folder (a "chroot").
2. Installs all of the packages listed in the Linuxium package list.
3. Copies Linuxium's custom files (wallpaper, settings, branding) into the system.
4. Runs hook scripts that finish the configuration, for example compiling the default desktop settings.
5. Compresses the system into a **SquashFS** file, which is a compact, read-only filesystem.
6. Creates a bootable **hybrid ISO** with a bootloader that works on both older BIOS computers and newer UEFI computers.

All of this is driven by one script, `build-linuxium.sh`.

### 8. Customization layer

On top of plain Debian and Cinnamon, Linuxium adds:

- The Tux wallpaper, stored in `/usr/share/backgrounds/linuxium/`.
- System-wide **dconf** defaults, which set the desktop background and a dark theme for every new user.
- A LightDM greeter configuration that sets the login screen background.
- A build hook that writes the Linuxium name and version into `/etc/os-release` and the login banner files.

### 9. Cloud builds

Because building an ISO needs a full Linux environment and a lot of disk space, Linuxium includes a **GitHub Actions** workflow. It frees up disk space on the cloud runner, runs the build script inside a privileged Debian 12 container, and gives you the finished ISO as a download. This means the distro can be built from any computer with a web browser.

---

## What's inside

| Layer | Component | Role |
| --- | --- | --- |
| Kernel | Linux (from Debian) | Hardware access and process management |
| System | GNU tools, systemd | Core commands and service management |
| Base | Debian 12 "Bookworm" | Package archive, updates, stability |
| Display | X.org | Draws graphics on screen |
| Login | LightDM + GTK greeter | Login screen |
| Desktop | Cinnamon (Muffin, Nemo) | The user interface |
| Audio | PipeWire + WirePlumber | Sound |
| Network | NetworkManager | Wi-Fi and Ethernet |
| Browser | Firefox ESR | Web browsing |
| Office | LibreOffice Writer and Calc | Documents and spreadsheets |
| Media | VLC | Audio and video |
| Build | live-build, debootstrap, SquashFS | Creates the ISO |

---

## System requirements

**Minimum**

- 64-bit (x86-64) processor
- 2 GB of RAM
- 20 GB of disk space for installation
- A USB drive (4 GB or larger) or a DVD to boot from

**Recommended**

- Dual-core processor or better
- 4 GB of RAM or more
- 30 GB of disk space or more
- A graphics card supported by the open-source drivers in the Linux kernel

Linuxium is built for **amd64** only at this time.

---

## Getting Linuxium

Linuxium is distributed as an ISO file named `linuxium-amd64.hybrid.iso`. Download it from the releases page of this repository, or build it yourself (see below).

To make a bootable USB drive:

1. Download and install **balenaEtcher** (Windows, macOS, Linux) or **Rufus** (Windows, use DD mode).
2. Select the Linuxium ISO.
3. Select your USB drive. **Everything on the drive will be erased.**
4. Click Flash, then restart your computer and boot from the USB drive. You may need to press a key such as F12, F10, Esc, or Del at startup to open the boot menu.

---

## Building Linuxium yourself

### Option A: Build in the cloud with GitHub Actions

1. Fork or upload this repository to your own GitHub account.
2. Make sure `build-linuxium.sh`, `wallpaper.png`, `lynx.png`, `grub-bg.png`, and `.github/workflows/build-iso.yml` are in the repository.
3. Open the **Actions** tab, choose **Build Linuxium ISO**, and click **Run workflow**.
4. When the run finishes, download the ISO from the **Artifacts** section of the run.

### Option B: Build on your own Debian or Ubuntu machine

You need a Debian 12 or Ubuntu system (a virtual machine is fine), root access with `sudo`, at least 4 GB of RAM, and about 20 GB of free disk space.

```bash
git clone https://github.com/YOUR-USERNAME/linuxium.git
cd linuxium
./build-linuxium.sh
```

(All three images have defaults in the repository — `wallpaper.png`,
`lynx.png`, and `grub-bg.png` — so no arguments are needed. Pass image
paths as arguments to use your own.)

When the build finishes, the ISO is located at:

```
linuxium-build/linuxium-amd64.hybrid.iso
```

A first build typically takes between 20 and 60 minutes depending on your internet speed and your computer.

---

## Trying it safely

Before installing Linuxium on a real computer, test it in a virtual machine such as **VirtualBox**, **VMware**, **GNOME Boxes**, or **QEMU**:

```bash
qemu-system-x86_64 -m 4096 -enable-kvm -cdrom linuxium-amd64.hybrid.iso
```

Or just boot the live session from a USB drive. The live session does not touch your hard drive unless you choose to install.

Things worth checking on a first test:

- The system boots to the Cinnamon desktop with the penguin wallpaper.
- The login screen has the correct background.
- Wi-Fi or Ethernet connects to the internet.
- Sound plays.
- Firefox, LibreOffice, and VLC open.
- The installer completes and the installed system boots.

---

## Customizing Linuxium

Everything about Linuxium is controlled by `build-linuxium.sh`, so customizing it means editing that script and rebuilding.

- **Change the wallpaper:** replace `wallpaper.png` with your own image, or edit the `picture-uri` line in the dconf section.
- **Add or remove software:** edit the package list section. Any package in the Debian archive can be added by name.
- **Change the theme:** edit the `gtk-theme` and `name` values in the dconf section.
- **Change the name and version:** edit the `os-release` section in the build hook.
- **Change the default username:** edit the `username=` value in the `--bootappend-live` option.

---

## Project structure

```
linuxium/
├── build-linuxium.sh              # Main build script (creates the live-build config and builds the ISO)
├── wallpaper.png                  # Wallpaper used on the desktop and login screen
├── lynx.png                       # Linuxium logo (boot splash, Neofetch, installer)
├── grub-bg.png                    # Boot-menu background
├── README.md                      # This file
├── index.html / forums.html       # Project website (with style.css)
└── .github/
    └── workflows/
        ├── build-iso.yml          # Cloud build workflow for GitHub Actions
        ├── checksum.yml           # Publishes SHA256SUMS after a successful build
        ├── lint.yml               # ShellCheck/YAML lint for the script and workflows
        └── boot-test.yml          # Manually boot an ISO in QEMU and screenshot it
```

When the script runs, it generates a working folder, `linuxium-build/`, that contains the live-build configuration (package lists, included files, and hooks) and the finished ISO.

---

## Known limitations

- Linuxium is an early, hobby-level project and has not been widely tested on real hardware.
- Only 64-bit x86 computers are supported.
- There is no custom icon set or theme yet, only the default Cinnamon look with a dark variant.

---

## Roadmap

- [x] Custom Linuxium logo and icon
- [x] Custom boot menu and splash screen
- [x] Calamares graphical installer
- [ ] Custom theme and icon pack
- [x] Welcome app for first-run setup
- [x] Secure Boot support
- [x] Automated tests that boot the ISO in a virtual machine (manual **Boot-test ISO in QEMU** workflow: boots the ISO and fails on a black screen)
- [x] Official releases and checksums

---

## Credits and acknowledgements

Linuxium would not exist without the work of many open-source communities. Thank you to:

- **Linus Torvalds** and the thousands of contributors to the **Linux kernel**.
- The **GNU Project** and the **Free Software Foundation**.
- The **Debian Project**, whose operating system is the foundation of Linuxium.
- The **Linux Mint team** and the **Cinnamon** contributors for the desktop environment.
- The **live-build** and **debootstrap** maintainers for the tools used to build the ISO.
- The **LightDM**, **PipeWire**, **NetworkManager**, **Firefox**, **LibreOffice**, and **VLC** projects.
- **Tux**, the Linux mascot, originally drawn by Larry Ewing.

---

## Licensing and trademarks

Linuxium is made of many separate software packages, and each one keeps its own license, most of them free and open source (such as the GPL, LGPL, MPL, and MIT licenses). The build scripts and configuration files in this repository are provided as open source; add your preferred license file (for example, MIT or GPL-3.0) to make that explicit.

Linux is a registered trademark of Linus Torvalds. Debian is a registered trademark of Software in the Public Interest, Inc. Firefox is a trademark of the Mozilla Foundation. All other names and trademarks belong to their respective owners. Linuxium is an independent project and is not endorsed by or affiliated with any of them.

Use of this software is at your own risk. Always back up your data before installing a new operating system.
