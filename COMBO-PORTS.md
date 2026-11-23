# R4-Pro 4E and 8X: choosing between Ethernet and SFP+

Use **WAN** to connect to your upstream router or modem. Use **LAN** to connect a home computer or switch. On the **4E**, the LAN Ethernet jacks and the LAN SFP+ slot work independently and can be used at the same time. The 4E WAN and both 8X combo ports default to their Ethernet jacks. To change one of these combo ports, save your choice and reboot.

## 1. Identify your port and choose the modules

If the switch at the other end has a 10G SFP+ slot, all four router slots below can use **10G SFP+ optical modules**. Choose modules and fiber that match at both ends. For example, a single-fiber bidirectional pair needs a matching U module at one end and D module at the other.

| Router port | Name on the Physical ports page | 10G optical module | 2.5G optical module | What to do |
|---|---|---|---|---|
| 4E WAN | `wan` | Yes | Yes | Choose between the ETH7 Ethernet jack and WAN SFP+ slot. Follow steps 2–4. |
| 4E LAN | `sfp-lan` | Yes | No | Follow “Connect a switch to the 4E LAN over fiber” below. |
| 8X WAN | `eth1` | Yes | Yes | Read the installation note below, then follow steps 2–4 for WAN. |
| 8X LAN | `mxl_lan4` | Yes | No | Read the installation note below, then follow steps 2–4 for LAN. |

**8X installation note.** If you performed a full installation with the v1.6.0 image for the 8X, continue with step 2. An 8X that still has the old bootloader after online updates continues to use the Ethernet jacks. In that case, back up your settings and perform a full installation with the 8X image. [Installation guide](https://github.com/BPI-SINOVOIP/bpirouteros/blob/v1.6.0/INSTALLATION.md)

### Connect a switch to the 4E LAN over fiber

You can leave your management computer plugged into a regular LAN Ethernet jack on the 4E.

1. Insert matching 10G optical modules into the **LAN SFP+** slot on the 4E and a **10G SFP+** slot on the switch.
2. If an Ethernet cable already connects the 4E to that same switch, unplug it before connecting the fiber.
3. With fiber as the only connection between the switch and the 4E, plug a computer into the switch by Ethernet, turn off its Wi-Fi, and open the router’s management page. The default is `https://192.168.100.1`. If you changed the LAN address, use your own address. If the page opens, the fiber link is working.
4. To return to Ethernet later, disconnect the fiber between the router and the switch first, then reconnect the original cable to a regular LAN jack.

This completes the 4E LAN setup. It requires no commands or reboot. The remaining steps apply to the 4E WAN and the two 8X combo ports.

For a combo port, `copper` selects the built-in Ethernet jack and `sfp` selects the module slot. Choose `sfp` even if the module itself has an Ethernet jack.

## 2. Keep a separate connection for management

1. Work beside the router. Plug your management computer into a regular LAN Ethernet jack. When changing the 8X LAN combo port, use another LAN jack for this computer.
2. Open the management page and check that you can sign in. Leave this cable connected throughout.
3. Insert the modules and check that the port and module at the far end match. Have the target cable ready for the reboot. Changing WAN briefly interrupts the Internet connection.

## 3. Select the SFP+ slot

On Windows open Terminal or PowerShell. On macOS open Terminal. Enter the following command, substituting your router’s LAN address if you changed it.

```sh
ssh root@192.168.100.1
```

On the first connection, confirm you are connected to your own router at the correct address before typing `yes` if prompted. Enter the router administrator password and press Enter. No characters appear while you type the password.

At the router prompt, choose **one** pair of commands for your model and port. The first command saves your choice. The second reads it back.

### 4E WAN to SFP+

```sh
fw_setenv r4pro_4e_wan_media sfp
fw_printenv r4pro_4e_wan_media
```

### 8X WAN to SFP+

```sh
fw_setenv r4pro_8x_wan_media sfp
fw_printenv r4pro_8x_wan_media
```

### 8X LAN to SFP+

```sh
fw_setenv r4pro_8x_lan_media sfp
fw_printenv r4pro_8x_lan_media
```

Check that the correct setting ends in `=sfp`. For example, the 4E WAN should read `r4pro_4e_wan_media=sfp`. Stop if a command reports an error or the value differs. Once the value is correct, enter:

```sh
reboot
```

The terminal disconnects. Leave the power and management cable connected, connect the target link to the selected slot, and wait until you can open the management page again.

## 4. Verify the link

Sign in through the terminal again. Run the command for your port to see which connector the router actually selected at startup.

| Port changed | Command |
|---|---|
| 4E or 8X WAN | `tr -d '\000' </proc/device-tree/chosen/bpirouter,wan-media; echo` |
| 8X LAN | `tr -d '\000' </proc/device-tree/chosen/bpirouter,lan-media; echo` |

The result should be `sfp`. In **Network → Physical ports**, find the card with the exact name from step 1. **Link up** and the expected speed confirm the physical connection. If you also want to check traffic:

- **WAN:** Test when this WAN is the only available Internet uplink. Connect a computer to the LAN by Ethernet, turn off its Wi-Fi, and open an external website. With a backup uplink available, the website can open through that other connection.
- **LAN:** Use fiber as the only connection between the switch and router. Connect a computer to the switch by Ethernet, turn off its Wi-Fi, and open the router’s management page.

If the result is `sfp` but the link stays down, check the WAN or LAN slot, the modules, and the port at the other end. If you saved `sfp` but the result after reboot is `copper`, or the command reports a missing file, check the model and installation method in step 1.

## 5. Return a combo port to its Ethernet jack

Leave the management computer on its separate LAN jack and sign in as in step 3. Run only the pair for the port you want to restore.

### 4E WAN to Ethernet

```sh
fw_setenv r4pro_4e_wan_media copper
fw_printenv r4pro_4e_wan_media
```

### 8X WAN to Ethernet

```sh
fw_setenv r4pro_8x_wan_media copper
fw_printenv r4pro_8x_wan_media
```

### 8X LAN to Ethernet

```sh
fw_setenv r4pro_8x_lan_media copper
fw_printenv r4pro_8x_lan_media
```

When the saved value reads `copper`, enter `reboot` and reconnect the target cable to its built-in Ethernet jack. After startup, use the command in step 4 to confirm `copper`. In **Network → Physical ports**, find the card named in step 1 and confirm **Link up** at the expected speed.

- **WAN:** To verify Internet access, use the WAN test in step 4 with this WAN as the only available uplink and the wired computer’s Wi-Fi off.
- **LAN:** Leave only the Ethernet cable between the switch and the router. On a computer wired to the switch, turn off Wi-Fi and open the management page.
