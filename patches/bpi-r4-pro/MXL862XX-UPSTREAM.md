# MXL862xx kernel patch origin

The BPI-R4-Pro kernel uses the MXL862xx Linux 6.12 backport and pending patch
stack from OpenWrt main commit
`93cf01b0b6fe169492be255db8613016b9d0c3cd`.

The vendored files are `kernel/930-*.patch` and `kernel/931-*.patch`. Their
contents are byte-for-byte copies of that commit's Linux 6.12 patches; the
additional numeric prefix only keeps the upstream order ahead of the local
R4-Pro device-tree patches. This replaces the former BPI vendor 6.6
forward-port (`994`/`995`) instead of maintaining a second switch-driver
implementation.

The pending portion is required by this board: it supplies the 802.1Q tag
driver, SerDes support and compatibility for the installed pre-1.0.84 switch
firmware. Do not select isolated patches from the series without re-running the
kernel patch-stack and R4-Pro bridge lifecycle tests.

Three files retain their upstream `DO-NOT-SUBMIT` designation and are deliberate
board compatibility patches rather than accepted mainline functionality:

- `931-17-*` restores the PCE workaround needed by the installed legacy switch
  firmware;
- `931-18-*` supplies the legacy SFP API fallback used by this 6.12 backport;
- `931-19-*` raises the switch command timeout for the observed hardware.

The stack is vendored for the OpenWrt 25.12.5 source baseline. Its presence is
not itself evidence of R4-Pro runtime acceptance; every baseline or stack
change must be rebuilt and retested on that board.

The R4-Pro builds this stack as the non-autoloaded `kmod-dsa-mxl862xx`, not as
a built-in driver. The AS21xxx PHY needs rootfs firmware, so the boot service
prepares that PHY first and then loads the switch module once before netifd.
Do not restore a built-in MxL driver or a boot-time switch unbind/rebind: either
would recreate a destructive second probe on every normal boot.

## 8X initial PHY discovery correction (2026-09-08)

The 8X-local `987-mxl862xx-retry-initial-phy-id.patch` is separate from the
byte-identical 930/931 import; 4E does not inherit it. On the 2026-09-07
development image, a subsequent 8X boot with switch firmware 1.0.70 reported
ready, then failed its first PHY 0 identity read (`CMD 1801`, error -19).
PHYLIB skipped PHY 0 and `mxl_lan0` was never created. Same-boot diagnostic
reads later returned ID `0xc1335528` without a reset or PHY register write;
the bus recorded 22 successful reads, one error and zero writes for PHY 0.
This establishes a transient discovery failure, not its internal firmware or
transport cause, and is not evidence that the fix has passed on hardware.

The correction retries only C22 identity reads during initial registration:
three attempts with 100ms between attempts, preserving the existing per-command
transport timeout. Persistent failure still permits other PHYs to be discovered.
Runtime reads and writes are not retried; CRC shutdown is unchanged. CRC retains a
per-call `-EBADMSG` classification until the PHY read retry decision, then map
back to the existing `-EIO` at the PHYLIB boundary. Other API commands retain
their errno contract. This does not depend on the shutdown worker's flag,
which may already have been cleared when the failed read returns.
The host regression executes driver callbacks and registration against a fake
bus and must fail
against the unpatched import. It also executes the command/API wrapper for
host and firmware CRC6/CRC16 failures with both pending and completed shutdown
workers, checking error propagation and the unchanged shutdown notification.
New-image 8X cold/warm boot tests must still prove all four base ports appear,
followed by port/link/forwarding checks.
No startup-service rebuild or switch firmware update is part of this fix.
