# Hailo-8 AI HAT+ (26 TOPS)

**Status: working end to end.** Driver bound, HailoRT installed, YOLOv8s running
at **~174 FPS** (`hailortcli run`), and live camera detection verified via
`detect.py`.

```console
$ hailortcli fw-control identify
Firmware Version: 4.24.0 (release,app,extended context switch buffer)
Device Architecture: HAILO8
```

```console
$ lspci -nn | grep -i hailo
0001:01:00.0 Co-processor [0b40]: Hailo Technologies Ltd. Hailo-8 AI Processor [1e60:2864] (rev 01)
```

Note this is a full **Hailo-8**, not the 13 TOPS Hailo-8L, and the HAT is an
**AI HAT+** — the AI HAT+ 2 carries a Hailo-10H and needs entirely different
software (`hailo-h10-all` on Raspberry Pi OS, `master` branch here). Compiled
model binaries (`.hef`) are built per accelerator, so this distinction matters
when downloading models too.

## Install

```bash
bash fetch-sources.sh                 # as your user: clone driver + firmware
sudo bash setup.sh                    # driver via DKMS, firmware, udev, modprobe
```

## Why this isn't `apt install hailo-all`

On Raspberry Pi OS the whole stack is one package from the Raspberry Pi apt repo.
That package isn't in the Ubuntu archive, and adding the Raspberry Pi repo to an
Ubuntu system is not a safe substitute — its packages are built against Raspberry
Pi OS's library versions. So the driver, firmware and runtime are built from
source, and the pieces must be version-matched (all v4.24.0 here).

## The four things that actually cost time

**1. The branch trap — this is the big one.**
`hailort-drivers`' `master` branch supports **only Hailo-10 and Hailo-15**. It says
so in one line of the README and nowhere else. Hailo-8 lives on the `hailo8`
branch. Cloning the default branch, or checking out the newest-looking tag
(`v5.3.0`), gives you a driver that compiles perfectly and then never binds to the
device. Nothing about the failure points at the branch. Same applies to the
`hailort` repo.

Latest on `hailo8` is **v4.24.0**, not v5.x.

**2. Kernel 7.0 — expected trouble, none found.**
`del_timer_sync()` was renamed `timer_delete_sync()` in kernel 6.15, which broke
Hailo's `master` badly enough to need a dedicated `v5.3.0-hotfix-kernel-above-6.15`
tag. The `hailo8` branch already handles it: clean build against `7.0.0-1016-raspi`,
no patches. Only two cosmetic warnings (pahole version, compiler mismatch).

Incidentally `Kbuild` sets `-DHAILO_RASBERRY_PIE` when `uname -a` contains
`raspi` — which Ubuntu's raspi kernel does, so we land on the same code path
Raspberry Pi OS uses.

**3. Upstream Makefile bug (not an Ubuntu problem).**
`Makefile` and `Kbuild` both reference:

```make
COMMON_INCLUDE_DIRECTORY = ../../../../common/include
```

which resolves *outside* a standalone `hailort-drivers` checkout — it only exists
in Hailo's internal monorepo, where the driver sits at `hailort/drivers/`.
Compiling is unaffected (gcc ignores missing `-I` paths, and the header is found
via `COMMON_SRC_DIRECTORY`), so `make all` succeeds. But `make install_dkms` does a
literal `cp -r` of that path and dies:

```
cp: cannot stat '../../../../common/include': No such file or directory
```

The DKMS tree genuinely needs `common/include`, because `Kbuild` re-resolves the
same relative path once sources are laid out under `KBUILD_PATH`. `setup.sh`
stages a directory of that name and overrides the make variable, rather than
patching upstream files that would need re-patching on every update.

**4. CMake 4 vs CMake 3.**
Ubuntu 26.04 ships **CMake 4.2**, which removed compatibility with
`cmake_minimum_required(VERSION <3.5)`. Raspberry Pi OS Trixie ships CMake 3.x, so
this never surfaces there. HailoRT's own CMakeLists and its vendored dependencies
(`cli11`, `json`, `dotwriter`) still declare old minimums, so configuring fails
outright until you pass:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
```

## Device permissions

Hailo ships `51-hailo-udev.rules` containing `MODE="0666"` — the accelerator
readable and writable by every account on the machine. `setup.sh` installs a
tighter rule instead:

```
SUBSYSTEM=="hailo_chardev", GROUP="hailo", MODE="0660", TAG+="uaccess"
```

Same convenience for the desktop user (logind grants an ACL to the active seat —
verified, `/dev/hailo0` opens with no re-login), plus a `hailo` group for headless
use, without exposing the device to service accounts.

## Not needed

`dtparam=pciex1_gen=3` is documented for the **AI Kit only**. The AI HAT+
negotiates its own link, and this deck works without touching
`/boot/firmware/config.txt`. Left alone deliberately — an unbootable Pi is a worse
problem than a slightly slower PCIe link.
