# Changelog

This file summarizes user-visible releases and changes to the public source
repository. For build commands, see [README](README.md). For supported features
and installation instructions, see the [feature guide](FEATURES.md) and
[installation guide](INSTALLATION.md).
For the purpose, board scope and origin of the current patch groups, see the
[patch guide](PATCHES.md).

## v1.5.0

### Supported hardware

- BPI-R3
- BPI-R3-Mini
- BPI-R4
- BPI-R4-Lite
- BPI-R4-Pro 8X
- BPI-R4-Pro 4E
- OpenWrt One

R4-Pro 8X and 4E require different images. Always select the exact board model.

### Release highlights

- English and Chinese management interface, light and dark themes, and layouts
  for desktop and mobile screens.
- Multi-WAN failover and load balancing, with optional WAN bandwidth shaping.
- Guest and IoT networks with access rules and shared bandwidth limits.
- Compatible Quectel mobile modules, supported ECM USB dongles and Android
  USB tethering.
- Device access controls, access schedules, DNS filtering and port forwarding.
- WireGuard and OpenVPN, dynamic DNS, settings backup and firmware management.
- Administrator, operator and read-only accounts.

These describe the v1.5.0 feature set; not every feature is new since RC1.
Available ports, wireless bands and mobile connections depend on the hardware.

### Public-source changes since v1.5.0-rc1

#### R4-Pro networking and indicators

- Update 8X combo-port support so copper or SFP can be selected at startup for
  each WAN/LAN combo port.
- Correct 8X Ethernet link and activity indicators, including migration of
  older default LED settings after a settings-preserving update.
- Skip copper PHY preparation and related failure diagnostics for combo ports
  configured for SFP, while retaining the existing four-port fallback.
- Update 4E Ethernet indicators, switch PHY discovery and onboard PHY startup.
- Add board-specific Wi-Fi MAC address configuration for both R4-Pro models.
- Apply the network notifier cleanup fix through the common kernel patch set
  rather than only the 8X patch directory.

#### Mobile connections and Multi-WAN

- Wait for QMI control readiness before starting data-format negotiation after
  a modem reset or cold boot, reducing premature setup failures.
- Refresh Multi-WAN tracking when a mobile connection obtains its address
  after the parent interface has already started.
- Extend build checks for modem session handling and dynamic WAN interfaces.

#### Installation, recovery and build delivery

- Update installation boot environments and recovery-slot configuration across
  the supported boards, including 8X combo-media startup settings.
- Include the current English and Chinese user guides in the R3-Mini and
  OpenWrt One recovery kits.
- Remove fault-injection acceptance scripts from the normal UI package's
  installation recipe.
- Update build-time checks for board identity, switch startup, recovery and
  package contents.
- Keep the original firmware input lock separate from the revised public
  source input lock. Both retain the selected upstream versions and UI package;
  see the README for how source revisions are identified.
- Refresh public build instructions and source comments while retaining
  copyright, licence and upstream attribution notices.

### UI and API package

The supplied precompiled UI/APID package is updated to v1.5.0. It includes the
management interface and API used by the firmware. The installed product
version is visible in **Home → System** and at the top of **System**.

This repository provides that package as a binary; it does not include the
private UI/APID source. Public-source changes listed above refer to the build
scripts, patches and package recipes available in this repository. See
[licensing information](LICENSING.md) for the applicable terms.

### Installation and usage notes

- For v1.5, reinstall an older or another vendor's installation using the
  matching installation media. Back up settings first; installation erases
  the destination storage. A sysupgrade image is not first-installation media.
- After a firmware update, allow several minutes for startup and any automatic
  restart. Keep power connected and follow the installation guide if the Web
  interface remains unavailable.
- R4-Pro combo copper and SFP connections are alternatives selected at startup,
  not automatically switched connections. On 8X, enabling SFP requires a fresh
  installation; an OTA-only update retains copper operation.
- The 8X LAN SFP+ cage does not accept 2.5G modules. If the LAN combo copper
  port is moved from a 10G peer to a slower peer, restart the router.
- On R4-Pro 8X/4E, use USB 3.2 for dongles and phone tethering; the USB 2.0
  port is unavailable in this release.
- Mobile support covers compatible Quectel QMI/NCM modules and supported
  EC200A-family ECM dongles, not every USB modem or MBIM. SIM hot-swapping is
  not supported; follow the feature guide when changing a SIM.
- Multi-WAN load balancing does not combine line speeds for a single download.
  WAN bandwidth shaping cannot be used with load balancing. Guest/IoT limits
  are shared per segment; per-device and per-protocol limits are unavailable.
- Wi-Fi channel and 6 GHz availability depend on the board, country setting
  and client capabilities.
- Manage Multi-WAN and WAN bandwidth shaping in BpiRouter. Avoid editing the
  same settings through both BpiRouter and LuCI.

For full details, see [Features](FEATURES.md),
[Features in Chinese](FEATURES.zh-CN.md), [Installation](INSTALLATION.md) and
[Installation in Chinese](INSTALLATION.zh-CN.md).

## v1.5.0-rc1

First public source repository snapshot, released as a candidate for user
evaluation. This historical entry describes RC1, not the current support status.

### Hardware and features at RC1

- Images for BPI-R3, BPI-R3-Mini, BPI-R4, BPI-R4-Lite, BPI-R4-Pro 8X,
  BPI-R4-Pro 4E and OpenWrt One.
- English/Chinese management, light/dark themes, desktop/mobile layouts and
  product version display.
- Wired Internet configuration, Wi-Fi, compatible Quectel QMI/NCM modules
  and phone USB tethering.
- Multi-WAN failover/load balancing, optional WAN SQM, and shared Guest/IoT
  bandwidth limits.
- Guest/IoT isolation controls, device access management, DNS filtering,
  access schedules, port forwarding, VPN and dynamic DNS.
- Settings backup/restore, firmware management, and administrator, operator
  and read-only accounts.
- Public build scripts, configurations and patches with a precompiled
  proprietary UI/APID package. Upstream inputs are downloaded during building.

### RC1-specific notes

- The RC1 guide classified 4E support as experimental and stated that firmware
  rollback was unavailable on 4E. These were RC1 restrictions; use the current
  feature guide for v1.5.0 support.
- The documented mobile support covered compatible Quectel QMI/NCM modules;
  the current EC200A-family ECM support must not be inferred from this RC1 entry.
- Installation required matching installation media rather than an in-place
  upgrade of an older or another vendor's firmware.
- MBIM, SIM hot-swapping, and per-device/per-protocol bandwidth limits were
  not supported. WAN SQM could not be combined with Multi-WAN load balancing.

Later fixes and public-source updates are listed under v1.5.0 above.
