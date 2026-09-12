# BpiRouter v1.5.0-rc1: features and use

[Chinese](FEATURES.zh-CN.md) · [Installation guide](INSTALLATION.md)

This guide describes v1.5.0-rc1, a release candidate for users to try before the
final release. Keep a backup and a way to reinstall before using it on a network
you depend on. Available ports, Wi-Fi bands and mobile connections depend on
your board and installed hardware.

## Choose your hardware

Images are provided for BPI-R4, BPI-R3, BPI-R4-Lite, BPI-R3-Mini, OpenWrt One,
BPI-R4-Pro 8X and BPI-R4-Pro 4E. Always use the exact model's download.
R4-Pro 4E is experimental; do not use an 8X image on it. On 4E, the WAN copper
and SFP connections are alternatives selected at startup, not two simultaneous
WAN ports. Copper is the default. They do not switch automatically when a cable
is inserted. Firmware rollback is not available on 4E in this release.

## Get started

After installation, connect a computer to a LAN port and open
`https://192.168.100.1`. Complete the setup wizard and choose your administrator
and Wi-Fi passwords. The interface offers English and Chinese, light and dark
themes, and layouts for computers and phones.

Find the product version in **Home → System** or at the top of **System**.
For this release it is `BpiRouter v1.5.0-rc1`. The separately listed OpenWrt
version is not the BpiRouter product version. If the version is unknown, do not
assume which release is installed.

## Features by page

| Page | What you can do |
|---|---|
| Home | See Internet status, traffic, connected devices, Wi-Fi and router resource use. |
| Network | Configure Internet connections, LAN addressing, Wi-Fi, mobile modules, USB sharing, Multi-WAN and WAN bandwidth shaping. |
| Devices | Identify connected devices, give them names, and allow or block their access. |
| Segments | Set up separate Guest and IoT Wi-Fi networks, their access rules and shared bandwidth limits. |
| Advanced | Configure DNS filtering, access schedules, port forwarding, firewall rules, VPN and dynamic DNS; use network diagnostics. |
| System | Change the router name, time and password; back up or restore settings, manage firmware, reboot or reset the router. |
| Users | Manage administrator, operator and read-only accounts. Administrator access is required. |

### Internet and Wi-Fi

In **Network**, choose the Internet connection and supply the details required
by your provider. Wired connections include automatic addressing, a fixed
address and PPPoE. IPv6 requires support from the provider and connected devices.
You can also use a compatible mobile module or a phone with USB tethering enabled.

Edit a Wi-Fi network to change its name, password and radio settings. Only the
bands fitted to your board are available. Channel and 6 GHz availability depend
on your country setting and client support. Changing Wi-Fi settings can disconnect
wireless clients; use a wired connection when making these changes.

For mobile Internet, this release supports compatible Quectel QMI and NCM
modules, not MBIM. Network availability and 4G/5G operation depend on the module,
SIM, antenna, provider and coverage. SIM hot-swapping is not supported. Power off
the router before changing an internal module's SIM. Unplug an external USB
dongle before changing its SIM, then reconnect it. Do not repeatedly remove just
the SIM while the module is powered.

### Multiple Internet connections

Use **Network → Multi-WAN** to select participating connections and choose
failover or load balancing. Failover uses an alternative connection when the
preferred one fails. Load balancing shares connections across multiple lines;
it does not promise the sum of their speeds for a single download.

### Bandwidth controls

- **Network → WAN bandwidth shaping:** optionally enable SQM for each WAN and
  enter its download and upload rates. Use the offered presets or your measured
  line rates; a setting slightly below the available rate helps reduce delays
  when the connection is busy. It is off by default. In failover mode, shaping
  follows the active WAN. It cannot be used with load balancing.
- **Segments → Guest / IoT:** set separate upload and download limits for each
  network. Each limit is shared by all devices in that segment, not assigned to
  every device individually. A value of zero means no limit in that direction.
  These limits can be used with Multi-WAN load balancing.
- Per-device and per-protocol bandwidth limits are not available in this release.

### Guest, IoT and device access

In **Segments**, enable Guest or IoT, choose a Wi-Fi radio, and set the network
name and password. These networks share the board's existing Wi-Fi radios; they
do not need an extra Wi-Fi adapter. Review Internet access, local-network access
and device-isolation settings before saving. Each enabled segment needs at least
one Wi-Fi network.

In **Devices**, use Allow or Block to change a device's access. A device name or
address is a management aid, not proof of who is using it. Access schedules and
DNS filtering are available in **Advanced**; DNS filtering cannot block every
application or every way of reaching a website.

### VPN, dynamic DNS and advanced connections

In **Advanced**, administrators can import a WireGuard or OpenVPN client
configuration to connect to a VPN, configure a VPN server and create client
configurations. Remote access requires a reachable Internet address and suitable
provider/network settings; a VPN server cannot bypass a provider's restrictions
on incoming connections.

Dynamic DNS associates a domain with your changing Internet address. Choose
DuckDNS, No-IP, Dynu, Cloudflare or FreeDNS and fill in the credentials requested
for that provider. Requesting an update does not guarantee provider acceptance;
check the domain before relying on it for remote access. Dynamic DNS does not
make an otherwise unreachable connection reachable.

Only expose services you intend to make public when configuring port forwarding
or firewall rules. Keep an alternative way to access the router while changing
network access settings. If a confirmation countdown appears, confirm only after
checking that the connection still works.

## Settings, firmware and help

Download a settings backup from **System** before significant changes. Backups
may contain passwords and keys: store them privately and do not send them with
a support request. Firmware updates, settings restore and factory reset are
administrator operations. A factory reset removes your settings.

For v1.5, install from the matching installation media rather than upgrading
an older or another vendor's firmware in place. Follow the
[installation guide](INSTALLATION.md); an upgrade image is not initial
installation media.

For product support, contact [Banana Pi](https://www.banana-pi.org/contact-us/)
or use its [official forum](https://forum.banana-pi.org/). Provide your exact
board model, product version, the action you took and the message shown.
Never send passwords, tokens, private keys or SIM identifiers.
