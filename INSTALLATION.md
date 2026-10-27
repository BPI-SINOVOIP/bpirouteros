# BpiRouter installation guide

[Chinese](INSTALLATION.zh-CN.md) · [Features and limitations](FEATURES.md)

Use the files and feature guide supplied with the version you are installing.
This guide covers first installation and complete reinstallation. Installation
erases settings and data on the destination storage. For v1.5, do not upgrade
an older or another vendor's installation in place; reinstall using this guide.

## 1. Prepare and choose the correct download

You need a computer, a wired LAN connection, a stable power supply suitable for
your board, and the installation media listed below. Use a serial console to
follow installation progress. Keep any files or settings you need somewhere else.

| Exact model | Download directory | Installation file |
|---|---|---|
| BPI-R4 | `bpi-r4` | `openwrt-mediatek-filogic-bananapi_bpi-r4-sdcard.img.gz` |
| BPI-R3 | `bpi-r3` | `openwrt-mediatek-filogic-bananapi_bpi-r3-sdcard.img.gz` |
| BPI-R4-Lite | `bpi-r4-lite` | `openwrt-mediatek-filogic-bananapi_bpi-r4-lite-sdcard.img.gz` |
| BPI-R4-Pro 8X | `bpi-r4-pro` | `openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-sdcard.img.gz` |
| BPI-R4-Pro 4E | `bpi-r4-pro-4e` | `openwrt-mediatek-filogic-bananapi_bpi-r4-pro-4e-sdcard.img.gz` |
| BPI-R3-Mini | `bpi-r3-mini` | `openwrt-mediatek-filogic-bananapi_bpi-r3-mini-flashkit.tar.gz` |
| OpenWrt One | `openwrt-one` | `openwrt-mediatek-filogic-openwrt_one-flashkit.tar.gz` |

Do not exchange files between 8X and 4E, between
different models, or between releases. A `sysupgrade.itb` file is not the first
installation file. Do not write individual files to storage areas by guessing.

Check the installation file against the SHA-256 value provided with the download.
On Linux use `sha256sum <downloaded-file>`; on Windows PowerShell use
`Get-FileHash <downloaded-file> -Algorithm SHA256`. Replace the placeholder with
the exact filename. If the value differs, do not flash; download the file again.

Connect the serial adapter following the manufacturer's instructions for your
exact board revision. Match its voltage and pins; do not connect the adapter's
power pin to the board. Set the terminal to **115200 baud, 8 data bits, no parity,
1 stop bit, no flow control**. Only one program may use that serial port at a time.

Always power off before changing boot switches, installation media or SIMs.
Never disconnect power while installation is writing. If the console reports
a read, write or verification error, stop: a prompt or LED change is not by
itself a successful installation.

## 2. Boards with an SD slot

Applies to R4, R3, R4-Lite, R4-Pro 8X and R4-Pro 4E. The SD card is installation
media, not the normal system drive. Installation requires three boot selections:
**SD → NAND → eMMC**. Follow all three stages in order.

### Prepare the SD card and boot selections

1. Use a disk-image writing application that verifies its writes. Select the
   exact `.img.gz` file from the table and the SD card as the destination.
   This erases the SD card. Carefully distinguish it from your computer's disk.
2. If the application does not accept `.gz`, decompress it first and write the
   resulting `.img`. Do not merely copy either file onto a formatted card.
3. Wait for writing and verification to finish successfully, then safely eject.
4. Locate the boot-source switches using the manufacturer's guide for your
   board revision. Determine the SD, NAND and eMMC settings before starting.
   Do not assume that ON/OFF positions are the same across boards or revisions.

| Model | Boot-source control | Additional selection to check |
|---|---|---|
| R4 | SW3 | Use NAND, not NOR, for the middle stage. |
| R3 | SW1 | Select NAND, not NOR; make SD accessible in the first stage and eMMC in the second and third. |
| R4-Lite | SW3 | Select NAND, not NOR; make SD accessible in the first stage and eMMC in the second and third. |
| R4-Pro 8X / 4E | SW3 | Use NAND, not NOR, for the middle stage. Do not change memory jumpers. |

If your board labels do not clearly identify the settings, obtain the correct
switch positions from Banana Pi before proceeding. Do not
guess from another model's photograph.

### Install

1. **SD stage:** power off, select SD boot, insert the prepared SD card, connect
   the serial console and power on. Let automatic startup proceed without
   pressing keys. Wait until writing completes and the console returns to the
   command prompt without errors. There is no Web page at this stage.
2. **NAND stage:** after successful completion, power off, remove the SD card,
   select NAND boot with eMMC accessible, and power on. Installation continues
   automatically. Wait for all writes to finish without errors before powering
   off. There is still no Web page at this stage.
3. **eMMC stage:** select eMMC boot and power on. Wait for the system to start,
   then proceed to section 4. Leave this selection in place for normal use.

Do not return to the NAND installation stage during normal use: it can erase
your settings and reinstall the system. Use console messages, not LED colour
alone, to decide whether it is safe to continue.

## 3. Boards without an SD slot

Applies to BPI-R3-Mini and OpenWrt One. Use the matching flashkit, a FAT32 USB
stick, a serial adapter and an x86_64 Linux computer. Keep the kit's files together.

### Prepare the USB stick and start the installer

1. Extract the exact `flashkit.tar.gz` into a new directory. From that directory
   run `sha256sum -c SHA256SUMS`. All entries must pass.
2. Copy **both** `snand-factory.bin` and `snand-factory.crc` to the USB stick's
   top level. Keep these names unchanged. Safely eject it from the computer.
3. With the board powered off, insert the USB stick and connect the serial
   adapter. Follow the manufacturer's serial-download entry instructions for
   the board. Close any serial terminal before running the loader.
4. From the extracted kit directory run the following, replacing `/dev/ttyUSB0`
   with your adapter's actual port:

   ```bash
   ./mtk_uartboot -s /dev/ttyUSB0 -p ram-ddr4-bl2.bin --aarch64 -f snand-uboot.fip
   ```

5. Power on or reset the board as required for the download connection. Once
   the loader finishes and releases the port, reopen the serial terminal.
   Installation starts automatically with the prepared USB stick present;
   do not interrupt it. This can erase onboard storage.

For a first installation, use this loader entry rather than assuming the
original firmware provides the same USB installation procedure.

### Finish on BPI-R3-Mini

1. Wait for `NAND OK: remove USB, strap NAND, power-cycle`. If writing or
   verification fails, do not advance.
2. Power off, remove the USB stick, select NAND boot with eMMC accessible,
   then power on. Wait for `eMMC OK: set strap to eMMC and power-cycle`.
3. Power off, select eMMC boot and power on. Continue with section 4.

### Finish on OpenWrt One

1. The installer started by the loader reads the USB stick automatically.
   No recovery-button press is needed for this entry.
2. Wait for `PROVISION OK - booting NAND` and the automatic restart. After
   writing has finished, power off, remove the USB stick, select NAND boot
   and power on. Continue with section 4. There is no eMMC stage.
3. For later complete reinstallation on a board already running the matching
   BpiRouter installation, insert the prepared USB stick while powered off
   and hold the rear reset/back button during power-on. Wait for
   `USB restore done - rebooting`. This also erases settings. If that entry
   is unavailable, use the loader procedure above.

## 4. First login

1. Connect the computer to a LAN port, not WAN. Set the computer to obtain its
   address automatically. Avoid another router using `192.168.100.1` on the
   same network.
2. Open `https://192.168.100.1`. If the browser warns about the local certificate,
   confirm that you are connected to your own router before proceeding.
3. Complete initial setup and choose new administrator and Wi-Fi passwords.
   Do not reuse example passwords. A complete fresh installation should offer
   initial setup rather than require the previous installation's password.
4. Check the model and BpiRouter product version in Home or System. Connect the
   Internet cable or enable the phone's USB tethering, then check Internet access
   from your computer. Read the [feature guide](FEATURES.md) before configuring
   Guest, IoT, Multi-WAN or VPN.

## 5. If something goes wrong

- **Download or kit checksum fails:** stop and obtain a fresh copy of the same
  model's files. Do not disable verification.
- **Installer reports an error:** note the last completed stage and the error.
  Recheck the file, installation media, boot selections and power supply. Do not
  advance to another stage after a failed write.
- **No Web page after final startup:** check the final boot selection, LAN cable,
  automatic address settings and that no other router is using the same address.
- **A complete reinstall is needed:** repeat the matching procedure above after
  saving anything you need. This clears settings; do not substitute another
  board's image or manually edit storage areas.

For installation support, contact [Banana Pi](https://www.banana-pi.org/contact-us/)
or use its [official forum](https://forum.banana-pi.org/). Provide the exact board
model, product version if available, installation stage and error message.
Do not include passwords, tokens, private keys or SIM identifiers.
