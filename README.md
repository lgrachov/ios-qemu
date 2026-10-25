# ios-qemu

**iOS 16 running in QEMU on an Apple Silicon Mac.**

ios-qemu boots the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X** in a QEMU virtual machine with hardware virtualization (hvf): launchd, the system daemons, backboardd, SpringBoard, Settings and Safari. Underneath is a kernel built from Apple's open-source XNU release (xnu-8796, the iOS 16 generation) plus a patch series that makes it behave enough like an iOS kernel, with small built-in drivers for QEMU's generic devices.

As of **2026-10-22** it boots to the lock and home screens in about a minute. You can unlock it with the mouse, open apps, type on a hardware keyboard and browse the web in Safari. The clock follows the host.

> Experimental, not a usable iOS device. There is no GPU (everything is drawn in software), no Secure Enclave, and Apple's security model is mostly switched off. Don't put anything personal on it.

This is not Corellium. Corellium boots Apple's own iOS kernel on virtual hardware that imitates an iPhone. ios-qemu rebuilds the kernel from Apple's open-source XNU and makes QEMU's generic devices look like an iPhone to the userland.

## What works

| Area | State |
| --- | --- |
| Boot | QEMU `virt` board, hvf (`-accel hvf -cpu host`); a small stub sets up the display and storage, then jumps into XNU with a generated Apple Device Tree |
| Storage | iOS root on a journaled HFS+ volume behind QEMU's emulated UFS controller, read/write |
| iOS userland | Real iPhone X 16.7.16 root filesystem and shared cache |
| Display | 1125×2436 in a live QEMU window (ramfb). Kernel IOSurface and IOMobileFramebuffer (`AppleCLCD`) services; CoreAnimation renders on the CPU |
| GUI | Lock screen with wallpaper, home screen with widgets, the stock apps (Mail, Notes, Calendar, Clock, Maps, …), Settings, Safari |
| Touch | Mouse clicks and drags in the window (virtio-tablet → HID digitizer) |
| Keyboard | Attached hardware keyboard (virtio-keyboard → HID). Ctrl+Option+P power, Ctrl+Option+H or Esc home, Ctrl+Option+Up/Down volume |
| Sound | Plays on the Mac (virtio-sound → CoreAudio): system sounds, ringtones, app audio. Needs `tools/audio-plugin.py setup DISK`; `--no-audio` turns it off. Volume buttons and output routes have no effect |
| Network | virtio-net as `en0` on QEMU user networking: DHCP, DNS, TCP, QUIC, HTTP and HTTPS in Safari |
| Clock | Host time through QEMU's PL031 RTC |
| Device identity | iPhone X (`iPhone10,3` / `D22AP`): no Home button, gesture UI |
| Scripting | Touch, typing, buttons and screenshots from the command line (`tools/qemu-touch.py`); live kernel log (`tools/qemu-klog.py`) |

## What does not work (yet)

- **Default wallpaper:** a plain blue fallback instead of iOS 16's default, because sandbox extensions are not issued yet. Some daemons (bluetoothd, assetsd) keep restarting.
- No GPU, microphone, camera, Bluetooth, cellular, location or Face ID.
- **Security is off:** permissive code signing (AMFI) and Sandbox policies, a stub AppleKeyStore, no data protection.

## Requirements

- A Mac with Apple Silicon (hvf). Tested on macOS 26 with an M5.
- Homebrew: `qemu` (tested with 11.0.2), `rsync` (GNU), `llvm` (optional, decodes the kernel's text console), `gh`, [`ipsw`](https://github.com/blacktop/ipsw).
- Xcode command-line tools (clang assembles the boot stub).
- A GitHub account to build the kernel on GitHub Actions (free for public forks).
- About 40 GB free disk space.

## Setup

### 1. Build the kernel

The kernel builds on GitHub's macOS runners with [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build). The workflow fetches xnu-8796 and applies `xnu/patches/` in order. Fork the repo and run:

```sh
gh workflow run xnu.yml -R YOU/ios-qemu
gh run download RUN_ID -R YOU/ios-qemu -n xnu-kernel -D xnu/out-local
```

`harness.sh` boots `xnu/out-local/kernel.development.sweet`.

### 2. Get iOS (bring your own IPSW)

No Apple software is distributed here. Download the iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW from Apple yourself. `ipsw info IPSW` names the OS, SystemOS and AppOS disk images; unzip those three from the IPSW. Then extract the iPhone X device tree, which MobileGestalt needs:

```sh
unzip IPSW Firmware/all_flash/DeviceTree.d22ap.im4p -d research/ipsw-x
ipsw img4 im4p extract research/ipsw-x/Firmware/all_flash/DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
```

### 3. Build the iOS disk

```sh
sudo tools/mkiosroot-mac.sh OS.dmg SystemOS.dmg AppOS.dmg research/iosroot
```

This copies the OS volume and both cryptexes into one case-sensitive journaled HFS+ volume, applies the bring-up changes from `tools/sweet-root-tweaks.py` (Setup skipped, activation state seeded, crash-looping daemons removed, …; the script's header explains each one) and wraps it as a UFS disk, `research/iosroot/disk.img`. `sudo tools/iosroot-tweak.sh research/iosroot/disk.img` re-applies the tweaks to an existing disk.

### 4. Boot

```sh
./harness.sh --ios research/iosroot/disk.img --secs 3600
```

A QEMU window opens. The first boot takes several minutes; later boots reach the lock screen in about a minute. Drag up from the bottom edge to unlock. Each run writes its logs and screenshots to `research/qemu-local/run-<timestamp>/`.

From another terminal:

```sh
tools/qemu-touch.py RUN_DIR unlock
tools/qemu-touch.py RUN_DIR tap 561 2259           # Safari in the dock
tools/qemu-touch.py RUN_DIR type 'http://example.com/
'
tools/qemu-touch.py RUN_DIR screenshot shot.png
tools/qemu-klog.py RUN_DIR kernel.txt              # kernel message buffer
```

Extra boot-args go through `--bootargs "..."`, e.g. `sweetsample=SpringBoard` (periodic user stack samples of named processes).

## Repository layout

| Path | What |
| --- | --- |
| `xnu/patches/` | The XNU patch series, applied in order by CI |
| `.github/workflows/xnu.yml` | Kernel CI build |
| `harness.sh` | One-command boot: builds the device tree and payload, runs QEMU |
| `tools/qemu-sweet.py`, `qemu-ramfb-stub.S` | QEMU launcher and boot stub (display, UFS setup) |
| `tools/mkadt.py`, `mkpayload.py` | Apple Device Tree generator; kernel + ADT + boot-args payload |
| `tools/mkiosroot-mac.sh`, `mkufsdisk.py`, `sweet-root-tweaks.py`, `iosroot-tweak.sh` | iOS disk builder and root tweaks |
| `tools/qemu-touch.py`, `qemu-klog.py`, `ufsdisk-log.py` | Input, screenshots and logs |
| `tools/dsc-a2s.py` | Symbolicate addresses in the shared cache |
| `NOTES.md` | Engineering log: every boot, crash and decision |

Not in git: Apple firmware, IPSWs, root images, shared caches and generated build trees.

## Legal

iOS, iPhone and Apple are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple. It contains no Apple binaries: you supply the IPSW, and Apple's software licence terms for it apply to you. The project's own code (tools, scripts, documentation) is under the MIT License, see [`LICENSE`](LICENSE). The kernel patches modify Apple's open-source XNU and are also subject to the [Apple Public Source License 2.0](https://opensource.apple.com/license/apsl/).

## Credits

Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw) and [QEMU](https://www.qemu.org). The kernel started as a port to the Redmi Note 10 Pro (`sweet`), which is where the `SWEET` names come from.
