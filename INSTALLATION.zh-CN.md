# BpiRouter 烧录手册

[English](INSTALLATION.md) · [功能与限制](FEATURES.zh-CN.md)

请使用与准备安装的版本配套的文件和功能说明。
本手册用于首次安装和完整重装。安装会清除目标存储中的设置和数据。
安装 v1.5 时，不要从旧版或其他厂商固件直接升级，请按本手册重新安装。

## 1. 准备并选择正确下载

需要电脑、有线 LAN 连接、适合板子的稳定电源，以及下表对应的安装介质。
使用串口终端查看安装进度。需要保留的文件和设置，请提前另存。

| 准确型号 | 下载目录 | 安装文件 |
|---|---|---|
| BPI-R4 | `bpi-r4` | `openwrt-mediatek-filogic-bananapi_bpi-r4-sdcard.img.gz` |
| BPI-R3 | `bpi-r3` | `openwrt-mediatek-filogic-bananapi_bpi-r3-sdcard.img.gz` |
| BPI-R4-Lite | `bpi-r4-lite` | `openwrt-mediatek-filogic-bananapi_bpi-r4-lite-sdcard.img.gz` |
| BPI-R4-Pro 8X | `bpi-r4-pro` | `openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-sdcard.img.gz` |
| BPI-R4-Pro 4E | `bpi-r4-pro-4e` | `openwrt-mediatek-filogic-bananapi_bpi-r4-pro-4e-sdcard.img.gz` |
| BPI-R3-Mini | `bpi-r3-mini` | `openwrt-mediatek-filogic-bananapi_bpi-r3-mini-flashkit.tar.gz` |
| OpenWrt One | `openwrt-one` | `openwrt-mediatek-filogic-openwrt_one-flashkit.tar.gz` |

R4-Pro 4E 为实验性支持。8X 和 4E、不同板型、不同版本之间不得混用文件。
`sysupgrade.itb` 不是首次安装文件。不要猜测存储位置并写入单独文件。

核对安装文件的 SHA-256 与下载页面提供的值是否一致。
Linux 可运行 `sha256sum <下载文件>`；Windows PowerShell 可运行
`Get-FileHash <下载文件> -Algorithm SHA256`。将占位符替换为准确文件名。
若结果不一致，不要烧录，应重新下载。

按厂家对准确硬件修订版的说明连接串口适配器，确认电压和引脚匹配，
不要将适配器的供电引脚连接到板子。终端设置为
**115200 波特率、8 数据位、无校验、1 停止位、无流控**。
同一时刻只能有一个程序占用该串口。

改变启动拨码、更换安装介质或 SIM 卡前必须断电。写入期间不得断电。
如果串口出现读取、写入或校验错误，应停止；返回命令提示符或指示灯变化，
本身不代表安装成功。

## 2. 带 SD 卡槽的板型

适用于 R4、R3、R4-Lite、R4-Pro 8X 和 R4-Pro 4E。
SD 卡是安装介质，不是日常运行系统的存储。
安装依次选择 **SD → NAND → eMMC** 启动，三个阶段都必须完成。

### 准备 SD 卡及启动选择

1. 使用支持写后校验的磁盘镜像写入工具，选择表中准确的 `.img.gz` 文件，
   目标选择 SD 卡。这会清除 SD 卡，务必区分它与电脑硬盘。
2. 如果工具不支持 `.gz`，先解压，再写入得到的 `.img` 文件。
   不能只是把这两个文件之一复制到格式化后的卡里。
3. 等待写入和校验均成功后，安全弹出 SD 卡。
4. 根据厂家对本板硬件修订版的说明找到启动拨码，开始前确认 SD、NAND
   和 eMMC 三种设置。不同板型或修订版的 ON/OFF 位置不能互相套用。

| 型号 | 启动选择开关 | 还需确认的选择 |
|---|---|---|
| R4 | SW3 | 中间阶段选择 NAND，而非 NOR。 |
| R3 | SW1 | 选择 NAND 而非 NOR；第一阶段保证 SD 可用，第二、三阶段保证 eMMC 可用。 |
| R4-Lite | SW3 | 选择 NAND 而非 NOR；第一阶段保证 SD 可用，第二、三阶段保证 eMMC 可用。 |
| R4-Pro 8X / 4E | SW3 | 中间阶段选择 NAND 而非 NOR，不要改动内存跳线。 |

如果板上标识无法明确对应这些设置，先向比派公司获取正确拨码位置，
确认后再操作。不要根据其他型号的照片猜测。

### 安装

1. **SD 阶段：**断电，选择 SD 启动，插入准备好的 SD 卡，连接串口后上电。
   不按键打断自动启动。等待写入结束、串口返回命令提示符且没有错误。
   这一阶段没有 Web 页面。
2. **NAND 阶段：**确认上一步成功后断电，取出 SD 卡，选择 NAND 启动并
   保证 eMMC 可用，再上电。安装自动继续。等所有写入无错误完成后再断电。
   这一阶段仍没有 Web 页面。
3. **eMMC 阶段：**选择 eMMC 启动后上电，等待系统启动，继续第 4 节。
   日常使用保持这一设置。

日常使用不要重新进入 NAND 安装阶段，否则可能清除设置并重装系统。
判断是否可以继续时以串口提示为准，不要只看指示灯颜色。

## 3. 不带 SD 卡槽的板型

适用于 BPI-R3-Mini 和 OpenWrt One。准备对应 flashkit、FAT32 格式的 U 盘、
串口适配器和 x86_64 Linux 电脑。安装包中的文件应保持配套。

### 准备 U 盘并启动安装程序

1. 将准确型号的 `flashkit.tar.gz` 解压到一个新目录，在该目录运行
   `sha256sum -c SHA256SUMS`，所有项目都必须通过。
2. 将 `snand-factory.bin` 和 `snand-factory.crc` **两个文件一起**复制到
   U 盘根目录，保持文件名不变，再从电脑安全弹出。
3. 板子断电时插入 U 盘、连接串口适配器。按厂家说明进入该板的串口下载
   模式。运行下载工具前关闭串口终端。
4. 在解压出的安装包目录运行下列命令，将 `/dev/ttyUSB0` 替换为
   适配器的实际串口：

   ```bash
   ./mtk_uartboot -s /dev/ttyUSB0 -p ram-ddr4-bl2.bin --aarch64 -f snand-uboot.fip
   ```

5. 按串口下载连接要求上电或复位。工具结束并释放串口后，重新打开串口终端。
   准备好的 U 盘已插入时，安装将自动开始，不要打断。
   此过程可能清除板载存储。

首次安装应使用此下载入口，不要假设原厂固件具有相同的 USB 安装功能。

### BPI-R3-Mini 后续步骤

1. 等待 `NAND OK: remove USB, strap NAND, power-cycle`。
   若写入或校验失败，不要继续下一步。
2. 断电，取出 U 盘，选择 NAND 启动并保证 eMMC 可用，再上电。
   等待 `eMMC OK: set strap to eMMC and power-cycle`。
3. 断电，选择 eMMC 启动，再上电，继续第 4 节。

### OpenWrt One 后续步骤

1. 通过下载工具启动的安装程序会自动读取 U 盘，此入口不需要按恢复键。
2. 等待 `PROVISION OK - booting NAND` 和自动重启。
   写入完成后断电，取出 U 盘，选择 NAND 启动后上电，继续第 4 节。
   此板没有 eMMC 阶段。
3. 已完成对应 BpiRouter 安装的设备，以后如需完整重装，可在断电时插入
   准备好的 U 盘，按住背面的 reset/back 键上电，等待
   `USB restore done - rebooting`。此操作同样清除设置。
   若该入口不可用，使用前面的下载工具步骤。

## 4. 首次登录

1. 电脑连接 LAN 口，不要接 WAN 口；设置为自动获取地址。
   避免同一网络中另一台路由器也使用 `192.168.100.1`。
2. 打开 `https://192.168.100.1`。若浏览器提示本地证书警告，
   确认连接的是自己的路由器后再继续。
3. 完成初始设置，选择新的管理员和 Wi-Fi 密码，不要沿用示例密码。
   完整重新安装后应进入初始设置，而不是要求输入原系统密码。
4. 在首页或系统页检查板型和 BpiRouter 产品版本。接好上网线路或开启
   手机 USB 共享，用电脑确认可以上网。设置 Guest、IoT、多 WAN 或 VPN
   前，请阅读[功能说明](FEATURES.zh-CN.md)。

## 5. 常见问题

- **下载文件或安装包校验失败：**停止，重新下载同一型号的配套文件，
  不要关闭校验。
- **安装程序报错：**记下最后完成的阶段和错误提示，检查文件、安装介质、
  启动选择和供电。写入失败后不要继续下一阶段。
- **最终启动后没有 Web 页面：**检查最终启动选择、LAN 网线、自动获取
  地址设置，以及是否有其他路由器使用相同地址。
- **需要完整重装：**保存所需内容后，重新执行本板对应的步骤。
  重装会清除设置，不要替换成其他板型镜像或手工改写存储区域。

烧录问题请联系[比派公司](https://www.banana-pi.org/contact-us/)，
或前往[比派官方论坛](https://forum.banana-pi.org/)，说明准确板型、产品版本
（如能查看）、安装阶段和错误提示。不要发送密码、令牌、私钥或 SIM 卡标识。
