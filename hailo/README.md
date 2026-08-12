# Hailo-8 AI HAT (26 TOPS)

**Status: not working yet.** `setup.sh` here installs the build toolchain only.

## Current state on this machine

The accelerator is present and enumerated on PCIe:

```
0001:01:00.0 Co-processor: Hailo Technologies Ltd. Hailo-8 AI Processor (rev 01)
```

but there is no `/dev/hailo0`, so nothing has bound to it. `lsmod` shows no
`hailo_pci`.

Note this is a full **Hailo-8**, not the 13 TOPS Hailo-8L — relevant when
choosing compiled model binaries (`.hef` files), which are built per accelerator.

## Why this isn't just `apt install`

On Raspberry Pi OS the whole stack comes from `hailo-all` in the Raspberry Pi apt
repo. That package is not in the Ubuntu archive, and adding the Raspberry Pi repo
to an Ubuntu system is not a safe workaround — its packages are built against
Raspberry Pi OS's library versions.

So three pieces have to be built or fetched separately:

1. `hailo_pci` kernel module, via DKMS, compiled against the `7.0.0-raspi` kernel
2. matching accelerator firmware
3. HailoRT userspace library (and Python bindings, against Python 3.14)

The versions of these three must match each other.

## Also worth checking

`/boot/firmware/config.txt` has no PCIe generation setting. The AI HAT is
generally run at Gen 3 for full bandwidth (`dtparam=pciex1_gen=3`), which needs a
reboot. Worth confirming against current Raspberry Pi guidance before changing —
Gen 3 on the Pi 5 is officially "not certified", though it's what the AI HAT
documentation recommends.
