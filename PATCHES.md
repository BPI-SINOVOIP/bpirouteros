# Patch guide

This guide explains the functional patch groups in the current source tree.
It is a source-navigation guide, not a list of newly introduced features or
a claim that every driver capability is exposed by the product. For changes
between releases, see [CHANGELOG](CHANGELOG.md); for user-facing support and
limits, see [Features](FEATURES.md).

## Reading the patch tree

The application order is defined by [prepare.sh](scripts/prepare.sh): common
patches first, then the selected board's patches. The directory name identifies
the patch application target; some Linux device-tree changes live under
`base-files/` because their files reside in the OpenWrt target tree.

`bpi-r4-pro` means **8X**; `bpi-r4-pro-4e` means **4E**. The 4E build also imports
the shared `930-*`/`931-*` MxL series and `987-*` from the 8X kernel directory.
It does not import the 8X device tree or its AS21xxx PHY patches.

Sources below are classified as:

- **Local:** project changes to the named upstream component, not a claim of
  sole authorship of the surrounding code.
- **Upstream:** retained upstream patches; authorship remains in their headers.
- **Reference-derived:** project board integration based on third-party reference
  code, with the original notices retained.

See [LICENSING](LICENSING.md) for attribution and applicable licences. File
prefixes in a group refer to the files in its linked directory; the tables
group related patches rather than repeat every board's equivalent file.

## Bootloader, early firmware and installation

Board U-Boot directories:
[R3](patches/bpi-r3/uboot/), [R3-Mini](patches/bpi-r3-mini/uboot/),
[R4](patches/bpi-r4/uboot/), [R4-Lite](patches/bpi-r4-lite/uboot/),
[8X](patches/bpi-r4-pro/uboot/), [4E](patches/bpi-r4-pro-4e/uboot/) and
[OpenWrt One](patches/openwrt-one/uboot/).

| Patch group | Boards | Purpose | Source |
|---|---|---|---|
| Board U-Boot `z01-*` | All seven | Configure product autoboot behavior. | Local |
| Board U-Boot `z02-*` | All seven | Enable persistent boot-attempt counting used by slot selection and recovery. | Local |
| Board U-Boot `z03-*` | All seven | Select the active firmware slot's root disk in the device tree. | Local |
| Board U-Boot `z06-*` | All seven; media vary | Supply default boot environments for installation, A/B slots and recovery. The maintained inputs are in [env-templates](env-templates/). | Local |
| [R3 `z04-*`](patches/bpi-r3/uboot/) | R3 | Add recovery-button handling during boot. | Local |
| [R4-Lite `z05-*`, `z07-*`](patches/bpi-r4-lite/uboot/) | R4-Lite | Initialize its system LED and stabilize provisioning writes by using 48 MHz eMMC high-speed mode instead of HS200/HS400. | Local |
| [R3-Mini `z08-*`](patches/bpi-r3-mini/uboot/) | R3-Mini | Keep the NAND provisioning environment independent of saved user environment. | Local |
| [One `z07-*`, `z08-*`](patches/openwrt-one/uboot/) | OpenWrt One | Add the RAM provisioning U-Boot variant and correct the orange LED label. | Local |
| [8X `450-*`](patches/bpi-r4-pro/uboot/), [4E `450-*`](patches/bpi-r4-pro-4e/uboot/) | R4-Pro 8X/4E | Add board device trees, build configurations and media variants. | Reference-derived; MediaTek notices retained |
| [8X `z12-*`](patches/bpi-r4-pro/uboot/), [4E `z12-*`](patches/bpi-r4-pro-4e/uboot/) | R4-Pro 8X/4E | Initialize system LEDs through the I2C GPIO expander. | Local |
| [8X `z13-*`, `z14-*`](patches/bpi-r4-pro/uboot/) | R4-Pro 8X | Reset both firmware-loaded 10G PHYs on boot and enable combo-media preboot selection. | Local |
| [4E `z14-*`](patches/bpi-r4-pro-4e/uboot/) | R4-Pro 4E | Enable the WAN-media selector's preboot reporting on each boot medium. | Local |
| [Common U-Boot `z09-*`](patches/common/uboot/) | Shared build | Enable environment reload support. | Local |
| [Common U-Boot `z10-*`](patches/common/uboot/) | Boards using EN8811H | Handle missing PHY firmware without dereferencing an uninitialized buffer. | Local |
| [Common U-Boot `z11-*`](patches/common/uboot/) | UBI provisioning paths | Reject volume lookup when no UBI device is attached. | Local |
| [Common TF-A `z10-*`](patches/common/atf/) | SPI-NAND BL2 paths | Reduce logging for normally erased UBI blocks while retaining corrupt-header diagnostics. | Local |
| [8X base-files `452-*`](patches/bpi-r4-pro/base-files/) | R4-Pro 8X | Add the required 8 GB, four-bank-group DDR firmware package variants. Not the 4E DDR configuration. | Local |

Image-layout and installation integration:

| Patch group | Boards | Purpose | Source |
|---|---|---|---|
| [Common base-files `001-*`](patches/common/base-files/) | Shared Filogic images | Adjust image construction for the product's installation layout. | Local |
| [R3-Mini base-files `011-*`, `012-*`](patches/bpi-r3-mini/base-files/) | R3-Mini | Build A/B eMMC provisioning content in NAND media and omit an unused recovery initramfs image. | Local |
| [One base-files `011-*`, `012-*`, `013-*`](patches/openwrt-one/base-files/) | OpenWrt One | Build dual UBI firmware volumes, wire in RAM provisioning U-Boot, and reserve firmware-volume headroom for upgrades. | Local |
| [8X base-files `450-*`, `451-*`, `460-*`, `461-*`, `462-*`](patches/bpi-r4-pro/base-files/), [4E equivalents](patches/bpi-r4-pro-4e/base-files/) | R4-Pro 8X/4E | Register U-Boot/image targets, environment access, compatibility identifiers and upgrade dispatch. | Local |
| [Common base-files `z13-*`](patches/common/base-files/) | Shared product configuration | Connect the hardware reset button to the product factory-reset action. | Local |

## Kernel, device trees and hardware initialization

| Patch group | Boards | Purpose | Source |
|---|---|---|---|
| [R3 kernel `z10-*`](patches/bpi-r3/kernel/), [R4 kernel `z10-*`](patches/bpi-r4/kernel/), [R3-Mini base-files `z10-*`](patches/bpi-r3-mini/base-files/), [R4-Lite base-files `z10-*`](patches/bpi-r4-lite/base-files/) | Named boards | Describe the second eMMC slot and the root-disk references used for A/B boot. | Local |
| [8X kernel `991-bpirouter-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X | Add A/B root-disk device-tree integration. | Local |
| [One base-files `z10-*`](patches/openwrt-one/base-files/), [kernel `z12-*`](patches/openwrt-one/kernel/) | OpenWrt One | Describe the two UBI firmware slots and create the block devices needed to boot either slot. | Local |
| [R3 kernel `z11-*`](patches/bpi-r3/kernel/), [R4 kernel `z11-*`](patches/bpi-r4/kernel/), [R3-Mini base-files `z11-*`](patches/bpi-r3-mini/base-files/), [R4-Lite base-files `z11-*`](patches/bpi-r4-lite/base-files/), [One base-files `z11-*`](patches/openwrt-one/base-files/) | Named boards | Set board-appropriate running, failsafe and status LED behavior. | Local |
| [R3 kernel `z12-*`](patches/bpi-r3/kernel/) | R3 | Correct active-low fan cooling levels so the fan starts at the intended 60 C trip. | Local |
| [Common kernel `980-*`](patches/common/kernel/) | Shared MediaTek Ethernet driver | Restrict tag-dependent DSA queue mapping to the MediaTek tag format. | Local |
| [Common kernel `989-*`](patches/common/kernel/) | Shared MediaTek Ethernet driver | Unregister the netdevice notifier when probe is deferred, preventing stale registrations. | Local |
| [Common openwrt `002-*`](patches/common/openwrt/) | Shared kernel configuration | Include source-version metadata in loadable modules for module identification. | Local |
| [8X kernel `990-*`](patches/bpi-r4-pro/kernel/), [4E kernel `990-*`](patches/bpi-r4-pro-4e/kernel/) | R4-Pro 8X/4E | Describe each board's devices, storage and network topology. | Reference-derived; MediaTek notices retained |
| [4E kernel `991-*`, `993-*`, `998-*`](patches/bpi-r4-pro-4e/kernel/) | R4-Pro 4E | Add WAN-media overlays, Ethernet LEDs, and correct the onboard PHY firmware-trigger register access. | Local |
| [8X kernel `991-bpi-*`, `992-*`, `998-*`, `999-*`, `999a-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X | Configure USB host, I2C LEDs, Wi-Fi PCIe, unrouted-port exclusions and fan control. | Local |
| [8X kernel `993-*`, `996-*`, `997a-*`, `999b-*`, `999c-*`, `999d-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X | Connect the 10G WAN/LAN PHYs and MxL switch, add ETH5/combo LED definitions and combo SFP overlays. | Local board integration |

### R4-Pro switch and external PHY stack

| Patch group | Boards | Purpose | Source |
|---|---|---|---|
| [Kernel `930-*` and `931-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X/4E | MxL862xx PHY identification, MDIO access, DSA tagging, switch/bridge/VLAN support, SerDes and related driver capabilities. | Upstream; 41-file series from OpenWrt commit `93cf01b0b6fe169492be255db8613016b9d0c3cd` |
| [Kernel `980-*` through `985-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X | AS21xxx detach/reset handling, link negotiation, reported speed and Clause 45 register access. | Upstream-authored by Christian Marangi; retain individual headers |
| [Kernel `986-*`, `997-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X | Adapt AS21xxx register reads and MDIO discovery timing to the MediaTek host. | Local |
| [Kernel `987-*`](patches/bpi-r4-pro/kernel/) | R4-Pro 8X/4E | Retry initial MxL PHY identification instead of losing a port after an initial failed read. | Local |
| [8X base-files `463-*`, `466-*`, `468-*`, `469-*`](patches/bpi-r4-pro/base-files/) | R4-Pro 8X | Package the switch as modules, enable early GPIO dependencies, configure firmware loading and prepare external PHYs before a non-destructive switch load. PHY failure does not prohibit loading the four-port baseline. | Local |
| [4E base-files `463-*`, `466-*`](patches/bpi-r4-pro-4e/base-files/) | R4-Pro 4E | Supply switch-module packaging and built-in GPIO-expander dependencies. | Local |
| [8X base-files `471-*`, `472-*`](patches/bpi-r4-pro/base-files/) | R4-Pro 8X | Configure combo copper link/activity LEDs and migrate matching older defaults after configuration restoration. | Local |

The MxL series is imported as a group. Its `931-17`, `931-18` and `931-19`
patches retain upstream's **DO-NOT-SUBMIT** labels: legacy-firmware PCE
workaround, legacy SFP API fallback and command-timeout adjustment. Being carried
in OpenWrt does not mean these workarounds are accepted in mainline Linux.
See the [MxL origin note](patches/bpi-r4-pro/MXL862XX-UPSTREAM.md) for provenance.

## Networking, wireless and service integration

| Patch group | Boards | Purpose | Source |
|---|---|---|---|
| [8X base-files `467-*`, `470-*`](patches/bpi-r4-pro/base-files/), [4E equivalents](patches/bpi-r4-pro-4e/base-files/) | R4-Pro 8X/4E | Set board-specific network defaults and Wi-Fi MAC address assignment. | Local |
| [Common base-files `002-*`](patches/common/base-files/) | Shared wireless build | Download Broadcom firmware only when the associated package is selected. | Local |
| [Common openwrt `001-*`](patches/common/openwrt/) | mt7915/mt7996 configurations | Explicitly keep WED off under the product's current offload policy. | Local |
| [Common openwrt `003-*`](patches/common/openwrt/) | netifd | Refresh IPv6 prefix assignment on dynamic interfaces. | Local |
| [Common openwrt `004-*`, `005-*`](patches/common/openwrt/) | netifd and supported mobile connections | Expose protocol activity and coordinate protocol-script lifetime so stale setup/teardown work does not overlap a later modem session. | Local |
| [Common openwrt `006-*`](patches/common/openwrt/) | netifd | Tie generated host routes to their interface lifetime and clean them up when that lifetime ends. | Local |
| [Common base-files `003-*`](patches/common/base-files/) | Supported QMI modules | Preserve the modem-provisioned APN when the interface does not specify one. | Local |
| [Common base-files `004-*`](patches/common/base-files/) | Supported QMI/NCM modules | Coordinate protocol setup/teardown and retry ownership with the product's modem lifecycle. | Local |
| [Common base-files `005-*`](patches/common/base-files/) | Supported NCM modules | Normalize modem manufacturer responses before selecting NCM commands. | Local |
| [Common base-files `006-*`, `007-*`](patches/common/base-files/) | Supported QMI modules | Check data-format evidence and wait for control readiness before negotiating a data session. | Local |
| [Common packages `001-*`, `003-*`](patches/common/packages/) | Multi-WAN | Refresh connected-route handling after cleanup and restart parent tracking when a dynamic child obtains an address. | Local |
| [Common packages `002-*`](patches/common/packages/) | WAN SQM | Coordinate SQM start/stop ownership with the product's network lifecycle. | Local |

The public patches are only part of the complete firmware. The proprietary
UI/APID package is supplied separately as a binary; this guide does not describe
its private implementation. A patch's presence alone is not a promise of support
for every module, port mode or upstream driver feature.
