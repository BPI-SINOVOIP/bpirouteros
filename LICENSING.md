# Licensing boundaries (bpirouter-build)

> **Status: the licensing boundaries were finalized by legal review on 2026-08-05.**
> This document describes the licences applicable to each part of this repository.
> If it conflicts with the root `LICENSE`, **this document takes precedence**:
> proprietary terms in `LICENSE` apply only to material identified here as proprietary.

This repository has mixed licensing: modifications to third-party GPL works,
build scripts required for their corresponding source, and genuinely independent
proprietary material. A single EULA cannot cover everything: GPLv2 section 6
prohibits further restrictions on the rights granted by the GPL.

## 1. Directory-level scope

| Path | Licence | Notes |
|---|---|---|
| `patches/**/kernel/` | **GPL-2.0** (Linux) | Linux kernel modifications; derivative works |
| `patches/**/uboot/` | **GPL-2.0+** (U-Boot) | U-Boot modifications; some files have other licences, as indicated by the modified file's SPDX header |
| `patches/**/atf/`<br>ATF-related files in `patches/**/base-files/` | **BSD-3-Clause** (TF-A) | ARM Trusted Firmware is not GPL and must not be labelled GPL-2.0 |
| Other files in `patches/**/base-files/` | **GPL-2.0** (OpenWrt) | OpenWrt build-system modifications, including filogic.mk and package Makefiles |
| `scripts/**` | **GPL-2.0** | See section 2 |
| `config/**` | **GPL-2.0** | See section 2 |
| `env-templates/**` | **GPL-2.0** | Also used in image generation |
| `flashkit/bin/mtk_uartboot-*`<br>`flashkit/src/**` | **AGPL-3.0-only** | Third-party tool; complete source and licence text are supplied |
| `flashkit/RUNBOOK-*.md` | **Proprietary** | Operating instructions written by this project |
| `docs/**` | **Proprietary** | Internal design and diagnostic documents |
| Original repository `README.md` | **Proprietary** | Not the generated build instructions in the public delivery |
| Brand identifiers, trademarks and logos | **All rights reserved** | See section 4 |

`openwrt/` and `output/` are not version-controlled; they contain the upstream
checkout and build outputs respectively.

### 1.1 Attribution for patches

Except for the entries below, the patches are original work by this project.
Their common upstream baseline is the OpenWrt `url`, `tag` and `commit` in
`RELEASE-INPUTS.lock.json`; it is recorded once rather than repeated per patch.

These patches contain third-party copyrighted material. Attribution is retained
inside each patch and distributed with it. Filenames are listed individually:
the checker matches exact names and cannot validate abbreviated ranges.

| Patch | Copyright holder | Attribution location | Origin |
|---|---|---|---|
| `980-net-phy-add-PHY_DETACH_NO_HW_RESET-flag.patch`<br>`981-net-phy-as21xxx-flag-PHY_DETACH_NO_HW_RESET.patch`<br>`982-net-phy-as21xxx-corner-case-link-autoneg.patch`<br>`983-net-phy-as21xxx-fix-read_status-speed.patch`<br>`984-net-phy-as21xxx-force-C45-OPs-autoneg.patch`<br>`985-net-phy-as21xxx-c45-read-workaround.patch`<br>(all under `bpi-r4-pro/kernel/`) | Christian Marangi | `From:` / `Signed-off-by:` headers | Taken in full from upstream |
| `bpi-r4-pro/kernel/930-00-760-v6.18-net-phy-introduce-phy_id_compare_model-PHY-ID-helper.patch`<br>`bpi-r4-pro/kernel/930-01-761-v6.19-net-phy-mxl-gpy-add-support-for-mxl86252-and-mxl86282.patch`<br>`bpi-r4-pro/kernel/930-02-762-v7.0-net-dsa-add-tag-format-for-MxL862xx-switches.patch`<br>`bpi-r4-pro/kernel/930-03-763-v7.0-net-mdio-add-unlocked-mdiodev-C45-bus-accessors.patch`<br>`bpi-r4-pro/kernel/930-04-764-v7.0-net-dsa-add-basic-initial-driver-for-MxL862xx-switch.patch`<br>`bpi-r4-pro/kernel/930-05-765-v7.0-net-dsa-mxl862xx-rename-MDIO-op-arguments.patch`<br>`bpi-r4-pro/kernel/930-06-766-v7.0-net-dsa-mxl862xx-don-t-set-user_mii_bus.patch`<br>`bpi-r4-pro/kernel/930-07-767-v7.0-net-dsa-MxL862xx-don-t-force-enable-MAXLINEAR_GPHY.patch`<br>`bpi-r4-pro/kernel/930-08-768-v7.1-net-dsa-MxL862xx-don-t-force-enable-MAXLINEAR_GPHY.patch`<br>`bpi-r4-pro/kernel/930-09-769-v7.1-net-dsa-mxl862xx-add-CRC-for-MDIO-communication.patch`<br>`bpi-r4-pro/kernel/930-10-770-v7.1-net-dsa-mxl862xx-use-RST_DATA-to-skip-writing-zero-w.patch`<br>`bpi-r4-pro/kernel/930-11-771-v7.1-net-dsa-mxl862xx-cancel-pending-work-on-probe-error.patch`<br>`bpi-r4-pro/kernel/930-12-772-v7.1-net-dsa-move-dsa_bridge_ports-helper-to-dsa.h.patch`<br>`bpi-r4-pro/kernel/930-13-773-v7.1-net-dsa-add-bridge-member-iteration-macro.patch`<br>`bpi-r4-pro/kernel/930-14-774-v7.1-dsa-tag_mxl862xx-set-dsa_default_offload_fwd_mark.patch`<br>`bpi-r4-pro/kernel/930-15-775-v7.1-net-dsa-mxl862xx-implement-bridge-offloading.patch`<br>`bpi-r4-pro/kernel/930-16-776-v7.1-net-dsa-mxl862xx-reject-DSA_PORT_TYPE_DSA.patch`<br>`bpi-r4-pro/kernel/930-17-777-v7.1-net-dsa-mxl862xx-don-t-skip-early-bridge-port-config.patch`<br>`bpi-r4-pro/kernel/930-18-778-v7.1-net-dsa-mxl862xx-implement-VLAN-functionality.patch`<br>`bpi-r4-pro/kernel/930-19-779-v7.1-net-dsa-mxl862xx-add-ethtool-statistics-support.patch`<br>`bpi-r4-pro/kernel/930-20-780-v7.1-net-dsa-mxl862xx-implement-.get_stats64.patch`<br>`bpi-r4-pro/kernel/930-99-730-10-v6.19-net-phy-mxl-gpy-add-support-for-MxL86211C.patch`<br>`bpi-r4-pro/kernel/931-01-760-01-net-dsa-mxl862xx-store-firmware-version-for-feature-.patch`<br>`bpi-r4-pro/kernel/931-02-760-02-net-dsa-mxl862xx-move-phylink-stubs-to-mxl862xx-phyl.patch`<br>`bpi-r4-pro/kernel/931-03-760-03-net-dsa-mxl862xx-move-API-macros-to-mxl862xx-host.h.patch`<br>`bpi-r4-pro/kernel/931-04-760-04-net-dsa-mxl862xx-add-support-for-SerDes-ports.patch`<br>`bpi-r4-pro/kernel/931-05-760-05-net-dsa-mxl862xx-add-SerDes-ethtool-statistics.patch`<br>`bpi-r4-pro/kernel/931-06-760-06-net-dsa-mxl862xx-trap-link-local-and-multicast-snoop.patch`<br>`bpi-r4-pro/kernel/931-07-760-07-net-dsa-mxl862xx-warn-about-old-firmware-default-PCE.patch`<br>`bpi-r4-pro/kernel/931-08-760-08-net-dsa-add-802.1Q-VLAN-based-tag-driver-for-MxL862x.patch`<br>`bpi-r4-pro/kernel/931-09-760-09-net-dsa-mxl862xx-add-link-aggregation-support.patch`<br>`bpi-r4-pro/kernel/931-10-760-10-net-dsa-mxl862xx-add-support-for-mirror-port.patch`<br>`bpi-r4-pro/kernel/931-11-760-11-net-dsa-wire-flash_update-devlink-callback-to-driver.patch`<br>`bpi-r4-pro/kernel/931-12-760-12-net-dsa-mxl862xx-add-SMDIO-clause-22-register-access.patch`<br>`bpi-r4-pro/kernel/931-13-760-13-net-dsa-mxl862xx-add-devlink-flash_update-and-info_g.patch`<br>`bpi-r4-pro/kernel/931-14-760-14-net-dsa-mxl862xx-implement-port-MTU-configuration.patch`<br>`bpi-r4-pro/kernel/931-15-760-15-net-dsa-mxl862xx-support-BR_HAIRPIN_MODE-bridge-flag.patch`<br>`bpi-r4-pro/kernel/931-16-760-16-net-dsa-mxl862xx-support-BR_ISOLATED-bridge-flag.patch`<br>`bpi-r4-pro/kernel/931-17-760-17-DO-NOT-SUBMIT-net-dsa-mxl862xx-re-introduce-PCE-work.patch`<br>`bpi-r4-pro/kernel/931-18-760-18-DO-NOT-SUBMIT-net-dsa-mxl862xx-legacy-SFP-API-fallba.patch`<br>`bpi-r4-pro/kernel/931-19-760-19-DO-NOT-SUBMIT-net-dsa-mxl862xx-increase-CMD-timeout.patch` | Contributors named in each patch's `From:` / `Signed-off-by:` headers | Patch headers and retained `Copyright` lines in added files | Taken file by file from OpenWrt upstream; exact sources are recorded in `patches/bpi-r4-pro/MXL862XX-UPSTREAM.md` |
| `bpi-r4-pro/kernel/990-add-bpi-r4-pro-8x.patch`<br>`bpi-r4-pro/uboot/450-add-bpi-r4-pro-8x.patch` | MediaTek Inc. | Retained `Copyright` lines in added files | Written by this project, derived from MediaTek reference DTS files |
| `bpi-r4-pro-4e/kernel/990-add-bpi-r4-pro-4e.patch`<br>`bpi-r4-pro-4e/uboot/450-add-bpi-r4-pro-4e.patch` | MediaTek Inc. | Retained `Copyright` lines in added files | Written by this project, derived from MediaTek reference DTS files |

The root `LICENSE` copyright notice applies only to this project's original
contributions. It does not claim copyright over the third-party material above.

The following command lists patches containing third-party copyright or sign-off
lines. The results must agree with the table; an unlisted file is an attribution gap.

```sh
find patches -name '*.patch' | LC_ALL=C sort | xargs grep -lE \
    '^(From: |Signed-off-by: )|^\+.*(Copyright|SPDX-FileCopyrightText)'
```

## 2. Why scripts and configurations use GPL-2.0

GPLv2 section 3 defines complete corresponding source to include:

> plus the scripts used to control compilation and installation of the executable

`prepare.sh`, `build-full.sh`, `boards.sh` and `config/*.config` control
compilation and installation of this firmware. They must be supplied with the
GPL binaries, with recipients free to use, modify and redistribute them.
Otherwise, additional restrictions would be imposed on GPL rights.

These files therefore use **GPL-2.0**. Copyright remains with the author;
licensing does not transfer ownership.

This does not change the status of `bpirouter-ui` (Go backend and Vue frontend).
It is an independent program invoked through exec, does not link GPL libraries
(`CGO_ENABLED=0`), and is treated as aggregation rather than a derivative work.
It remains proprietary. See the README supplied with this source.

## 3. Non-source binary inputs

No non-source firmware blob is carried in this source repository.

Previously, `patches/bpi-r4-pro/firmware/as21x1x_fw.bin` was embedded into
vmlinux using `CONFIG_EXTRA_FIRMWARE`. It was found to match
`linux-firmware-20251125/aeonsemi/as21x1x_fw.bin` byte for byte. Upstream
`WHENCE` records it as `Licence: Redistributable`, with `LICENSE.aeonsemi`.

That licence allows use and redistribution for devices containing AEONSEMI
silicon products, but excludes distribution as part of the Linux kernel or in
another form requiring these files themselves to be covered by the GNU GPL.

Embedding in vmlinux is an excluded form and has been discontinued. The upstream
`aeonsemi-as21xxx-firmware` package now supplies it separately as
`/lib/firmware/as21x1x_fw.bin`, with its upstream licence. Source and hashes are
recorded in the release lock.

The licence defines exclusions rather than enumerating permitted forms. This
approach matches OpenWrt upstream; the wording was finalized by legal review on
2026-08-05. See the `resolved` entry in `config/blob-licences.json`.

## 4. Trademarks and branding

The BpiRouter name, logo and brand identifiers are not licensed by any software
licence. The GPL grants copyright permissions, not trademark permissions;
retaining brand rights is therefore not inconsistent with the GPL.

Trademark terms must not restrict modification or redistribution of GPL-covered
code itself. Requiring derivative products not to use this project's branding
does not entitle the project to forbid changes to its kernel patches.

## 5. GPL compliance

The corresponding-source delivery process is described in the README supplied with this source. The licence classifications in this document were finalized by legal
review on 2026-08-05 for external use.
