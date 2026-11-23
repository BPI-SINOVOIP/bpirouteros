# Changelog

This file summarizes user-visible releases and changes to the public source
repository. For build commands, see [README](README.md). For supported features
and installation instructions, see the [feature guide](FEATURES.md) and
[installation guide](INSTALLATION.md).
For the purpose, board scope and origin of the current patch groups, see the
[patch guide](PATCHES.md).

## v1.6.1

Maintenance release for the same seven models, based on OpenWrt 25.12.6.

### Security fixes

- The built-in Tailscale client has no standalone updater. Update it through
  a BpiRouter firmware upgrade.
- First setup is wired: a new or reset router keeps Wi-Fi off and stores no
  Wi-Fi password, and Wi-Fi can only be turned on with a password of the
  owner's choosing. Earlier versions broadcast Wi-Fi with a shared, published
  factory password, which stayed in use after setup if Wi-Fi was skipped.
- OpenWrt 25.12.6 security updates (hostapd, mac80211, uhttpd, rpcd, LuCI,
  OpenSSL, Mbed TLS and others) and the Linux fix for CVE-2026-98432; the
  management service is built with Go 1.27.4.
- OpenWrt's default IPsec forward rules (ESP, UDP 500) are restricted to IPv4
  when unchanged, so they no longer reach LAN devices over IPv6.

### Fixes and changes

- Fixed Guest and IoT Wi-Fi client isolation across bands. Enable client isolation on both bands to prevent clients on one band from reaching clients on the other.

- Dynamic DNS fixes cover HTTPS certificate checks, Cloudflare subdomains, provider error reporting and forced updates when the address is unchanged. DuckDNS and Cloudflare were verified with live accounts. No-IP, Dynu and FreeDNS were verified against simulated provider responses.
- WAN MTU settings now apply to the underlying device for DHCP and static WANs. Clear the MTU field to restore the protocol default. If you previously entered a custom DHCP or static WAN MTU, enter it again after upgrading.
- Client names and notes now count the 128-character limit by character and reject control characters.
- The setup wizard records the country or region and the time zone, prefilled
  from the browser, also when Wi-Fi is skipped; full time zone list.
- Saving time zones such as Singapore or Dubai in System works again.
- Signed-in sessions survive the router setting its clock after start-up.
- The unpublished `bpirouter` package feed is no longer listed.
- Kernel support for user-installed software: USB storage (exFAT, NTFS), USB
  Ethernet and USB serial adapters, zram, transparent-proxy firewall features.
- Package metadata no longer records the build machine's paths.
- Public source repository: release-maintenance tools and tests that need the
  development workspace are no longer included; the UI package's third-party
  notices are exported with it.

### Corrections

- v1.5.0 listed access schedules and DNS filtering, which BpiRouter does not
  provide; v1.6.0 listed per-device DNS servers, which are available only
  through the API in v1.6.

## v1.6.0

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

- Remote networking with Tailscale (Tailscale 1.98.3, official coordination
  service) on all seven models: devices behind two BpiRouters can reach each
  other, and Tailscale clients can reach devices behind a BpiRouter while away.
  Remote networking, network sharing and remote web management are off by
  default; only selected networks behind BpiRouter are shared.
- A warning when a WAN connection's firewall zone membership differs from its
  configuration.
- Per-device DNS servers apply without a static address reservation and can
  no longer be bypassed through the router's IPv6 DNS.
- TCP MSS and PPPoE MTU corrections on WAN connections.
- A new OpenWrt One storage layout with larger firmware slots, keeping A/B
  recovery.

### Public-source changes since v1.5.0

#### Remote networking

- Add the Tailscale package integration used by remote networking: policy
  routing that coexists with Multi-WAN, a product-managed service, clearing of
  an explicitly empty exit-node setting, local key-expiry reporting, and a
  build without the peer API server, Wake-on-LAN and exit-node advertisement.
- Record Tailscale's upstream module constraints, linked module versions and
  licence notices in the firmware under `/usr/share/tailscale/`.
- Run the product's remote-networking firewall check before each firewall
  start or reload, and keep the default-deny table in place when that check
  cannot be completed.
- Limit Multi-WAN's routing-table cleanup to its own reserved tables so other
  services' policy routing tables are not removed.

#### Network fixes

- Bound the TCP MSS of forwarded traffic by the ingress link MTU, so replies
  over a smaller-MTU WAN selected by Multi-WAN advertise a correct MSS.
- Apply a PPPoE interface's MTU setting to the PPP link only, not to its parent
  Ethernet device, whose MTU must also carry the PPPoE encapsulation.
- Pass the saved bootloader MAC address to the R4-Lite LAN interface instead
  of a random address on each boot.
- Correct the kernel log message that reports a randomly assigned MediaTek
  Ethernet MAC address.

#### OpenWrt One

- Move to a new A/B layout with larger UBI firmware volumes, and reject
  over-the-air updates between the v1.5 and v1.6 layouts.
- Use the NOR U-Boot as a button-gated USB-to-NAND installer, and publish only
  the separate NOR boot firmware rather than a whole-NOR factory image.
- Stop the installers when a NAND erase operation fails instead of continuing
  or reporting success.
- Update the One boot environment and provisioning U-Boot for the new layout.

#### Build and delivery

- Add [third-party notices](proprietary-artifacts/THIRD_PARTY_NOTICES.md) for
  the components contained in the precompiled UI/APID package.
- Add host regression checks for the changes above; they use BusyBox `ash`
  (set `BUSYBOX` if it is outside `PATH`).
- The public source lock is the firmware input lock for this release; the
  separate original-firmware lock used for v1.5.0's revised sources is no
  longer present.

### UI and API package

The supplied precompiled UI/APID package is updated to v1.6.0. It includes the
management interface and API used by the firmware, including remote networking.
The installed product version is visible in **Home → System** and at the top of
**System**.

This repository provides that package as a binary; it does not include the
private UI/APID source. See [licensing information](LICENSING.md) for the
applicable terms.

### Installation and usage notes

- OpenWrt One cannot be updated in place from v1.5. Back up settings and
  reinstall with the v1.6 One flashkit and its serial (UART) loader; the old
  reset-button USB restore cannot perform this migration.
- The other six models update from v1.5 with the exact model's sysupgrade
  image in **System → Firmware**; confirm the firmware trial after checking
  access and connectivity.
- v1.6 supports at most eight Multi-WAN interfaces, including disabled ones.
  Keeping settings or restoring a v1.5 backup can exceed this; the feature
  guide describes **Reset Multi-WAN and reboot**.
- Remote networking shares IPv4 local networks only, without remote DNS,
  MagicDNS or an exit node. Shared networks must not overlap the other site's
  LAN, Guest or IoT networks.
- `apk update` reports an error for the unpublished `bpirouter` package feed
  listed in the firmware. Comment out the line containing `/bpirouter/` in
  `/etc/apk/repositories.d/distfeeds.list` until a later release fixes it.
- The R4-Pro media, USB, mobile, Multi-WAN and bandwidth notes listed under
  v1.5.0 still apply.

For full details, see [Features](FEATURES.md),
[Features in Chinese](FEATURES.zh-CN.md), [Installation](INSTALLATION.md) and
[Installation in Chinese](INSTALLATION.zh-CN.md).

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
