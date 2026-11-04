# Hailo-10H on the Seeed M.2 HAT

**Status: driver bound and firmware booted** (kernel 7.0.0-1020, after the
`no-mip` reboot): `/dev/h1x-0` present, firmware loaded, board SKU-ID 10. HailoRT 5.5 installed and talking to it:

```console
$ hailortcli fw-control identify
Firmware Version: 5.5.0 (release,app)
Device Architecture: HAILO10H
```

Hailo-ollama serves `qwen2.5:1.5b` on 127.0.0.1:8000 and answers `/api/chat`.
The model came in through `import-model.sh`, since `/api/pull` is blocked (below).

```console
$ lspci -nn | grep -i hailo
0001:03:00.0 Co-processor [0b40]: Hailo Technologies Ltd. Hailo-10H AI Processor [1e60:45c4] (rev 01)
```

The Hailo-10H is the generative-AI part: it carries its own DRAM and runs small
LLMs (the v5.5.0 catalogue runs from `llama3.2:1b` to `qwen3:4b`) behind an Ollama-compatible API. It sits on a Seeed
dual M.2 HAT next to the boot NVMe, both behind one ASM2806 PCIe switch.

That pairing is why this exists. The Hailo-8 AI HAT+ (`../hailo8`) took the Pi's
only PCIe slot, which pushed the SSD onto USB 3, and USB 3's 2.4 GHz noise broke
WiFi and the wireless keyboard and mouse. The Seeed HAT puts both on PCIe.

## Install

```bash
bash fetch-sources.sh        # as your user: driver, runtime, hailo-ollama, firmware
sudo bash setup.sh           # driver via DKMS, firmware, udev, modprobe
bash build-hailort.sh        # as your user: libhailort 5.5 + hailortcli
sudo bash install-hailort.sh # replaces HailoRT 4.24 in /usr/local
hailortcli fw-control identify
bash build-ollama.sh         # as your user
sudo bash install-ollama.sh
bash run-ollama.sh           # serves on 127.0.0.1:8000
```

`pkexec bash …` works in place of `sudo bash …` (the scripts resolve the real
user from either).

Then, in another terminal:

```bash
curl -s http://127.0.0.1:8000/hailo/v1/list | jq
curl -s http://127.0.0.1:8000/api/pull -H 'Content-Type: application/json' -d '{"model": "qwen2:1.5b", "stream": false}'
curl -s http://127.0.0.1:8000/api/chat -H 'Content-Type: application/json' \
  -d '{"model": "qwen2:1.5b", "stream": false,
       "messages": [{"role": "user", "content": "Say hello in five words."}]}' | jq -r .message.content
```

Models download from `dev-public.hailo.ai` into `~/.local/share/hailo-ollama`.
Each is 1.5–3 GB.

## Everything is pinned to v5.5.0

The driver, firmware, libhailort and hailo-ollama must match, so
`fetch-sources.sh` takes all four from one `VERSION`. All three GitHub repos tag
`v5.5.0`, and the firmware's S3 path is versioned the same way.

## How this differs from the Hailo-8 setup

**Branch: the opposite of the Hailo-8 trap.** `hailort-drivers`' `master` and
the v5.x tags are Hailo-10/15 *only*. The v4.24 driver in `../hailo8` does define
the 10H's device ID (`PCI_DEVICE_ID_HAILO_HAILO10H 0x45C4`) but leaves it out of
its `hailo_pcie_id_table`, so with only that driver installed the 10H enumerates
and nothing claims it. No error, no `/dev` node.

**It coexists with the Hailo-8 driver, apart from the runtime.**

| | Hailo-8 (`../hailo8`) | Hailo-10H (here) |
|---|---|---|
| Module | `hailo_pci` 4.24.0 | `hailo1x_pci` 5.5.0 |
| PCI IDs | `1e60:2864` | `1e60:45c4` (+ 15L, Mars) |
| Firmware | `/lib/firmware/hailo/hailo8_fw.bin` (150 KB) | `/lib/firmware/hailo/hailo10h/` (32 files, ~110 MB) |
| Device class / node | `hailo_chardev`, `/dev/hailo0` | `hailo1x`, `/dev/h1x-0` |
| udev rule | `51-hailo-udev.rules` | `52-hailo1x-udev.rules` |
| HailoRT | 4.24 | 5.5 — **same `/usr/local` slot** |

Both DKMS modules stay installed, and whichever chip is in the slot binds. Only
one HailoRT can live in `/usr/local`; `install-hailort.sh` replaces 4.24 and
`../hailo8/install-hailort.sh` puts it back.

**Firmware is a whole boot chain.** The Hailo-8 loads one 150 KB blob. The 10H
boots its own Linux: `scu_fw.bin`, `u-boot-spl.bin`, `u-boot-tfa.itb`, a signed
device tree per board SKU, `fitImage` (kernel) and `image-fs` (~100 MB root
filesystem). The driver picks the device tree as `u-boot-<sku>.dtb.signed`, or
`u-boot-default.dtb.signed`, which in the tarball is a symlink to
`u-boot-0.dtb.signed`. That's why `setup.sh` copies with `cp -P`.

The firmware's license (`Hailo10H FW License` in the driver checkout) allows
binary-only redistribution and forbids publishing benchmark results, which is one
more reason it stays out of git.

**No `install_dkms` target.** 5.x dropped the Makefile that had the
`../../../../common/include` bug `../hailo8/setup.sh` works around. What's left is
`linux/pcie/dkms.conf.in`, which builds from the repository root. `setup.sh`
copies the checkout to `/usr/src/hailo1x_pci-5.5.0`, renders the template, and
calls `dkms add/build/install` itself.

**`-Werror`.** Kbuild builds the driver with `-Werror`, so a kernel that adds a
warning breaks the build instead of just making it noisy. Kernel 7.0's
`del_timer_sync` → `timer_delete_sync` rename is already handled in
`linux/common/compat.h`. If a future kernel breaks it, the compiler output is in
`/var/lib/dkms/hailo1x_pci/5.5.0/build/make.log`.

**Out of interrupt vectors: `Failed to enable MSI -28`.** This is the one that
needs a reboot. The Pi 5 routes the external slot's MSIs through the "MIP", which
has **8 vectors**. Behind the HAT's switch, all 8 are taken before the 10H probes:

```console
$ grep MIP-MSI /proc/interrupts      # 4 switch ports + 4 NVMe queues = 8
 42: ... MIP-MSI-PCI-MSI-0001:02:00.0    0 Edge  PCIe bwctrl
 ...
 50: ... MIP-MSI-PCI-MSIX-0001:06:00.0   3 Edge  nvme0q3
```

So `pci_enable_msi()` returns `-ENOSPC`, and the driver loads but never activates
the board. `setup.sh` adds `dtoverlay=pciex1-compat-pi5,no-mip` to
`/boot/firmware/config.txt` (backup in `config.txt.bak-hailo10h`), which
`overlays/README` recommends when "more than 8 interrupt vectors are required".
Until you reboot, `setup.sh` stops at that point and says so. The Hailo-8 never
hit this, since it had the slot to itself.

**The headers package can bring a new kernel.** `linux-headers-raspi` pulls
`linux-image-raspi` along, so `setup.sh`'s apt step can install a newer kernel.
DKMS builds a module for a new kernel only if the module was registered before
that kernel arrived, so `setup.sh` builds `hailo1x_pci` for every kernel in
`/lib/modules` rather than only the running one.

## Hailo-Ollama on loopback

Upstream binds `0.0.0.0:8000` with no authentication, so any network the deck
joins could reach the accelerator. `run-ollama.sh` sets
`OLLAMA_HOST=127.0.0.1:8000` unless you override it. It also runs from
`~/.hailo/hailort`, because HailoRT writes `hailort.log` into whatever directory
it's started from.

**`/api/pull` is blocked by Cloudflare (as of 2026-11-04).** `dev-public.hailo.ai`
answers every non-browser request with a bot challenge (`cf-mitigated: challenge`,
HTTP 403, a "Just a moment..." page). hailo-ollama reports that as
`no complete blob pair (HEF + .sha256 companion) ... at v5.5.0 or fallback v5.4.0`,
which reads as if the model were missing. It isn't. Download the `.hef` and its
`.sha256` in a browser from `https://dev-public.hailo.ai/v5.5.0/blob/<Name>.hef`
and `.../<Name>.sha256` (`<Name>` is the manifest's `hef_filename`), then:

```bash
bash import-model.sh ~/Downloads/<Name>.hef ~/Downloads/<Name>.sha256
```

It checks the checksum and writes the `<Name>.hef.version` file that hailo-ollama's
cache check looks for. The next pull then reports a cache hit and never goes
online.

Limits, per upstream: LLMs only (no VLMs or image generation), one connection
with one pending request at a time, no LoRA, no Ollama CLI. Tool calling works on
models whose chat template declares it.

## Bandwidth

Both M.2 devices share the Pi's single x1 link, which negotiates **Gen2**
(5 GT/s, ~4 Gb/s) without `dtparam=pciex1_gen=3`. The NVMe alone saturates it at
~350–370 MB/s. Hailo-Ollama loads each model into the 10H's own DRAM, so this
mostly matters for model load time, not tokens per second. That's unmeasured
here so far.
