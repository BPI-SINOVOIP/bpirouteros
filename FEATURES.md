# BpiRouter v1.6: features and use

[Chinese](FEATURES.zh-CN.md) · [Installation guide](INSTALLATION.md)

This guide describes the v1.6 series for home users. Check your installed version;
these instructions do not describe v1.5. Versions with an `rc` suffix are release
candidates for testing before the final release. Keep a backup and a way to
reinstall before using it on a network
you depend on. Available ports, Wi-Fi bands and mobile connections depend on
your board and installed hardware.

## Choose your hardware

Images are provided for BPI-R4, BPI-R3, BPI-R4-Lite, BPI-R3-Mini, OpenWrt One,
BPI-R4-Pro 8X and BPI-R4-Pro 4E. Always use the exact model's download.
R4-Pro 4E requires its own image; do not use an 8X image on it. On 4E, the WAN copper
and SFP connections are alternatives selected at startup, not two simultaneous
WAN ports. Copper is the default. They do not switch automatically when a cable
is inserted.
On 8X, each 10G combo port (WAN and LAN) also uses either its copper jack or
its SFP+ cage, chosen at startup with the U-Boot settings `r4pro_8x_wan_media`
and `r4pro_8x_lan_media` (`copper` or `sfp`, default `copper`) and applied after
a reboot. Choosing SFP requires a fresh installation; a board updated only
over the air keeps copper. The LAN SFP+ cage does not accept 2.5G modules.
Known issue: if the LAN combo copper port has been connected to a 10G device
and is then connected to a slower one, restart the router; until then that
port may receive with errors.

## Get started

After installation, connect a computer to a LAN port and open
`https://192.168.100.1`. Complete the setup wizard and choose your administrator
and Wi-Fi passwords. The interface offers English and Chinese, light and dark
themes, and layouts for computers and phones.

Find the product version in **Home → System** or at the top of **System**.
Check that it matches the version you installed. The separately listed OpenWrt
version is not the BpiRouter product version. If the version is unknown, do not
assume which release is installed.

## Features by page

| Page | What you can do |
|---|---|
| Home | See Internet status, traffic, connected devices, Wi-Fi and router resource use. |
| Network | Configure Internet connections, LAN addressing, Wi-Fi, mobile modules, USB sharing, Multi-WAN and WAN bandwidth shaping. |
| Devices | Identify connected devices, give them names, and allow or block their access. |
| Segments | Set up separate Guest and IoT Wi-Fi networks, their access rules and shared bandwidth limits. |
| Advanced | Configure remote networking, DNS filtering, access schedules, port forwarding, firewall rules, VPN and dynamic DNS; use network diagnostics. |
| System | Change the router name, time and password; back up or restore settings, manage firmware, reboot or reset the router. |
| Users | Manage administrator, operator and read-only accounts. Administrator access is required. |

### Internet and Wi-Fi

In **Network**, choose the Internet connection and supply the details required
by your provider. Wired connections include automatic addressing, a fixed
address and PPPoE. IPv6 requires support from the provider and connected devices.
You can also use a compatible mobile module or a phone with USB tethering enabled.
On the BPI-R4 Pro (8X/4E), connect the phone or USB dongle to the USB 3.2 port; the board's USB 2.0
port is not available in this release.

Edit a Wi-Fi network to change its name, password and radio settings. Only the
bands fitted to your board are available. Channel and 6 GHz availability depend
on your country setting and client support. Changing Wi-Fi settings can disconnect
wireless clients; use a wired connection when making these changes.

For mobile Internet, this release supports compatible Quectel QMI and NCM
modules and supported EC200A-family ECM USB dongles, not MBIM. This does not
mean every USB modem is compatible. Network availability and 4G/5G operation
depend on the module,
SIM, antenna, provider and coverage. SIM hot-swapping is not supported. Power off
the router before changing an internal module's SIM. Unplug an external USB
dongle before changing its SIM, then reconnect it. Do not repeatedly remove just
the SIM while the module is powered.

### Multiple Internet connections

Use **Network → Multi-WAN** to select participating connections and choose
failover or load balancing. Failover uses an alternative connection when the
preferred one fails. Load balancing shares connections across multiple lines;
it does not promise the sum of their speeds for a single download.

Multi-WAN switching applies to IPv4 only. IPv6 remains available where supported,
but does not follow these failover rules.

This version supports at most eight Multi-WAN interfaces; disabled entries also
count. Keeping settings during an upgrade or restoring an older backup can bring
in more entries and prevent Multi-WAN from starting. This also applies to OpenWrt
One after reinstallation and backup restore.

If the page reports this limit, an administrator can use **Reset Multi-WAN and
reboot** from the local network. This deletes Multi-WAN members, policies and
health checks, then restarts the router. WAN addresses, connection credentials
and other settings are retained; recreate the required Multi-WAN policy afterward.
During a firmware trial, reset is unavailable. Returning to the previous firmware
also returns to its settings, without guaranteeing immediate connectivity.
Keeping the new firmware ends the trial's automatic rollback protection but does
not fix Multi-WAN: reset still requires a separate confirmation and restart.
Once kept, that trial's rollback option is no longer available.

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

### Remote networking with Tailscale

In **Advanced → Remote access → Remote networking**, an administrator can link
home networks through the official Tailscale service, including on OpenWrt One.
Remote networking, local-network sharing and remote web management are off by
default. Joining an account does not open access by itself.

1. For two routers, give their LANs different address ranges before connecting
   them. Both default to `192.168.100.0/24`. Choose a range that does not overlap
   either site's LAN, Guest, IoT or upstream networks. For example, if
   `192.168.110.0/24` is unused, edit one router's LAN settings: enter
   `192.168.110.1` as the IP address and `255.255.255.0` as the subnet mask.
   After saving, let your computer obtain an address in the new network,
   reconnect at `https://192.168.110.1`, sign in and keep the settings using
   the confirmation banner before the trial expires.
2. Enable remote networking, choose **Try these settings**, check that local
   access still works, and keep the configuration using the confirmation banner.
3. Get the sign-in link and complete sign-in with your Tailscale account. Join
   both routers to the same Tailscale network. Keep sign-in links private.
4. Select each local network you want to share: LAN, Guest or IoT. Keep this
   configuration trial, then use the linked Tailscale console to approve those
   subnet routes and review access permissions. If device approval is requested,
   complete that separately. Check the router's key-expiry setting there; disable
   expiry for a router that must stay connected, and remove it if no longer trusted.
5. To connect a phone or computer from outside, install its Tailscale client,
   join the same network and enable subnet-route access if the client requires
   it. Open a service using the shared device's IPv4 address. Devices behind the
   two routers do not need a Tailscale app. Both uses can operate together.
   This release has not been verified with the Windows or macOS Tailscale
   clients; their subnet-route settings and system firewalls may differ.

Only selected networks behind BpiRouter are shared. Sharing works in both
directions: devices on a shared network, including Guest or IoT, can also start
connections to the other site's shared networks and to devices in your Tailscale
network, as far as the other side's settings and your Tailscale access policy
allow. Devices and management pages on its upstream network are not exposed
through this connection. Remote web
management is a separate option: it allows the BpiRouter page and LuCI, still
with their normal sign-in requirements. It does not enable remote SSH or other
router services. Removing sharing or management permission disconnects affected
remote access; keep a local way to manage the router.

The page separates the running service, local permissions and observed route
approval. Devices reached this way normally use BpiRouter as their default
gateway. A device that uses another gateway or several network interfaces needs
a route back to the remote networks, and its own firewall must accept those
connections. An installed or approved route does not prove that a remote device
or its application is reachable. Unknown or stale information is not a current
approval or a clean conflict check. Check the Tailscale console and the target
service when access fails. The page does not report a verified direct/relay path;
connections may use either, and performance depends on the available path.

The page shows the reported node-key expiry date in your browser's local time.
An unavailable date is shown as unknown. There is no advance expiry reminder;
if the key is reported expired, an error asks you to reauthorize the device.
If the router restarts after the key has expired, the page may show only that
sign-in is required, without the expiry error. You can still get the sign-in
link and sign in again, then check the device and route approvals in the
Tailscale console.

A network shared by one site must not overlap any LAN, Guest or IoT network at
the other site, whether or not the other site shares it. Guest and IoT use the
same default ranges on every BpiRouter, so change one site's range before
sharing them. Overlaps are reported but are not automatically fixed or blocked;
they can stop local devices from reaching the Internet or the management page.
To recover, on the affected router disable remote networking or revoke the
conflicting route approval in the Tailscale console; on the sharing router,
stop sharing that network. Then change the range.

When an accepted remote LAN overlaps your local upstream network, traffic routed
by BpiRouter can go to the remote network instead.
To reach the local upstream device, connect directly to that upstream network;
if the client itself runs Tailscale, disconnect it or stop accepting subnet routes
there as needed. The router cannot see every network used by remote clients.

This feature shares IPv4 local networks by IP address; it does not configure remote
DNS or MagicDNS, or offer an exit-node option for sending all Internet traffic
through another router. Normal Internet access stays local in this supported setup. Extra routes
you approve on other nodes can change that behavior; BpiRouter does not filter
all such routes by address range or IP version. IPv6 subnet sharing and additional
public-address routes are outside this version's supported setup.

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

Restoring a backup to a replacement router also restores any WAN MAC address
saved in that backup. Disconnect the old router before restoring: connecting
both routers to the same upstream network with the same WAN MAC can disrupt
connectivity. If you need to keep both routers in use on that network, configure
the new router separately instead of restoring the other router's full settings
backup. Restoring settings does not automatically assign a new WAN MAC address.

Remote-network identity is not included in a downloaded settings backup. A
replacement router must sign in separately; restoring to an already bound router
keeps that router's identity while applying the restored settings. Disabling
remote networking keeps the identity. **Unlink this router** disables remote
networking and removes the identity in use, but it does not remove every
identity copy kept on the router or delete the cloud device record. Before
handing over or retiring the router, perform a factory reset and delete the
device in the Tailscale console.

Keeping settings during an update preserves the current firmware's identity, if
it has one. If you return to older firmware without that identity and then update
again, sign-in is required again. Review route approval and remove obsolete cloud
devices as needed. Rolling back a settings trial does not undo account sign-in
or cloud approvals.

Follow the [installation guide](INSTALLATION.md) for v1.5-to-v1.6 migration.
OpenWrt One requires a complete reinstall using the new flashkit's serial loader;
neither an in-place update nor the old reset-button USB restore can migrate it.
Back up settings first. An upgrade image is not initial installation media.

After a firmware update, allow several minutes for startup and any automatic
restart to complete. Keep the power connected during this process. If the web
interface remains unavailable, follow the troubleshooting steps in the
[installation guide](INSTALLATION.md). Keep a way to reinstall the router;
rollback is not a substitute for a settings backup.

The standard OpenWrt web interface, LuCI, remains available for users who
prefer it at `https://192.168.100.1/cgi-bin/luci` (use the new address if you
changed the router's LAN address). Sign in as `root` with the same
administrator password. Do not change the same setting in both interfaces.
LuCI does not include Multi-WAN or WAN bandwidth shaping; manage them only in
BpiRouter. Changing them elsewhere may cause configuration conflicts or errors,
and BpiRouter does not guarantee automatic recovery.

For product support, contact [Banana Pi](https://www.banana-pi.org/contact-us/)
or use its [official forum](https://forum.banana-pi.org/). Provide your exact
board model, product version, the action you took and the message shown.
Never send passwords, tokens, private keys or SIM identifiers.
