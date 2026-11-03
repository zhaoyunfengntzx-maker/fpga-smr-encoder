# 30 · 把位流固化进 QSPI Flash（掉电保留）

> **状态口径**：`[上板验证]` —— 2026-10-30 17:22~17:24 用本流程把
> `deliverables/data/v67/enc_top_lowsig.bit` 烧进板载 N25Q128 并校验通过。
> **一句话**：`tools/program_flash.tcl` 已能一键擦写+校验；唯一必需的“怪招”是
> **先把间接烧写位流（spi bridge）装进 FPGA**，否则 Vivado 必然报 27-3347。

## 1. 为什么要走这条路

`tools/program_enc.tcl` 用的是 `program_hw_devices`，只写 FPGA 的 SRAM 配置：
**断电就没了**，每次上电都要开 Vivado 重烧。要让作品“插电即跑”，必须用
`program_hw_cfgmem` 把位流写进板载 SPI Flash，FPGA 上电自己从 Flash 加载。

| 项 | 值 |
|---|---|
| 板上 Flash | Micron N25Q128，128 Mbit = 16 MB |
| Vivado 里的型号 | `mt25ql128-spi-x1_x2_x4`（`n25q128` 在 part 表里只是它的别名，不能选） |
| 位流 → mcs | `write_cfgmem -format mcs -size 16 -interface SPIx1 -loadbit "up 0x0 <bit>" -checksum -force -disablebitswap` |
| 实测耗时 | 擦除 + 烧写 + 校验 = **38 s**（mcs 4,231,018 B） |

## 2. 一键流程

```powershell
cd C:\Users\zhaoy\Desktop\FPGA

# 板子上电 + JTAG（Digilent HS2）接好，然后：
$env:FLASH_BIT = 'C:/Users/zhaoy/Desktop/FPGA/deliverables/data/v67/enc_top_lowsig.bit'
$env:FLASH_MCS = 'C:/Users/zhaoy/Desktop/FPGA/_flash2_work/enc_top_lowsig.mcs'
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File _flash2_work\run_vivado_hw.ps1 `
  -Tcl _flash2_work\run_full.tcl -LogFile full_flash.log -Tail 25
```

`_flash2_work\run_full.tcl` 内容就是两行：

```tcl
set ::env(FLASH_BIT) {C:/Users/zhaoy/Desktop/FPGA/deliverables/data/v67/enc_top_lowsig.bit}
set ::env(FLASH_MCS) {C:/Users/zhaoy/Desktop/FPGA/_flash2_work/enc_top_lowsig.mcs}
source {C:/Users/zhaoy/Desktop/FPGA/tools/program_flash.tcl}
```

看到 `FLASHPROG FLASH_OK` 就算写完并校验通过。

> 本机 Vivado 是 2026.1（`D:\Vivado\2026.1`），**必须**用
> `_flash2_work\run_vivado_hw.ps1` 启动：它把 `HOME/TEMP/APPDATA` 都指到
> `_flash2_work\` 下，并把 `XILINXD_LICENSE_FILE` 指到 `D:\Vivado\Xlnx_2026_1.lic`。
> 老的 `tools\run_vivado.ps1` 在这个会话里会因 `HOME` 落在受保护目录而报
> `ERROR: [Common 17-354] Could not open 'C' for writing`。

## 3. 唯一必需的特殊步骤（`tools/program_flash.tcl` 第 3.5 步）

不加载间接烧写位流时，`program_hw_cfgmem` 会在 **~100 ms** 内失败：

```
ERROR: [Labtools 27-3347] Flash Programming Unsuccessful: Failure to set flash parameters.
ERROR: [Common 17-39] 'program_hw_cfgmem' failed due to earlier errors.
```

`hw_server -L-` 的 TCF 日志里对应的真因是：

```
TCF ...: Command: C 66 XicomFlash override ...
TCF ...: Invalid context
```

7 系列写 SPI Flash 靠一段“间接烧写位流”在 FPGA 里搭 JTAG→SPI 桥
（`spi_xc7a35t_pullnone.bit`，422,197 B）；Vivado 2026.1 在这个环境不会自动装它。
所以脚本在建好 cfgmem 之后、擦写之前多做一步：

```tcl
set ibit [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]   ;# Vivado 会自己算出这个路径
set_property PROGRAM.FILE $ibit $dev
program_hw_devices $dev                                   ;# 桥先就位
```

> 之前排查中怀疑过的方向（part 型号、JTAG 频率、GUI 争用、`bitfile.zip` 未解压）
> 都不是原因；其中 `bitfile.zip` 只是让上面那行 `get_property` 能取到路径，**仍需
> 解压一次**（见 §4）。

## 4. 前置条件（一次性的）

1. `D:\Vivado\2026.1\Vivado\data\xicom\cfgmem\bitfile\` 必须存在（内含
   `spi_xc7a35t_pullnone.bit`）。若没有，把同目录的 `bitfile.zip`（310 MB）解压进去；
   普通用户对 Vivado 安装目录无写权限，需提权：
   ```powershell
   Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-Command',`
     'Expand-Archive -Path "D:\Vivado\2026.1\Vivado\data\xicom\cfgmem\bitfile.zip" -DestinationPath "D:\Vivado\2026.1\Vivado\data\xicom\cfgmem\bitfile" -Force'
   ```
2. JTAG 电缆在设备管理器里可见（`USB\VID_0403&PID_6014\210512180081`，Digilent HS2）。
3. `hw_server` 在 3121 端口监听：
   ```
   D:\Vivado\2026.1\Vivado\bin\hw_server.bat -L- -l discovery -s TCP::3121
   ```

## 5. 验证（必须做）

* 脚本末尾会 `boot_hw_device`，等价于“不拔电重加载”，日志出现
  `INFO: [Labtools 27-32] Done pin status: HIGH`。
* 回读状态：`REGISTER.CONFIG_STATUS = 01000000000100000111100111111100`
  （`0x401079FC`，DONE=1）——与板上电从 Flash 启动后的值一致即为正常。
* **最终判据是断电重上电**：拔电源 → 再上电（不开 Vivado）→ DONE 灯亮、
  串口/显示正常。若上电不启动，先查板上 BOOT 拨码是否在 Master SPI/QSPI。

## 6. 踩过的坑（恢复手段）

| 现象 | 原因 | 办法 |
|---|---|---|
| 杀了 `cs_server.exe` 后 JTAG 目标消失，`USB\VID_0403&PID_6014` 从设备管理器里也没了 | `cs_server` 是电缆持有者，杀掉会把 USB 设备摘掉 | 提权 `pnputil /scan-devices` 恢复设备，再跑 `_flash2_work\rescan.tcl`；**以后别杀它**，刷新电缆用 `refresh_hw_server` |
| `write_cfgmem: unknown escape sequence` | `-file/-loadbit` 的 Windows 反斜杠路径被当 Tcl 转义（`\U`） | 脚本里 `string map {\\ /}` 统一转正斜杠（已内置） |
| `ERROR: [Common 17-354] Could not open 'C' for writing` | `HOME` 落在沙箱/受保护目录 | 用 `_flash2_work\run_vivado_hw.ps1` |
| `ERROR: [Labtoolstcl 44-49] Value [1500000] is not valid for hw_target` | `PARAM.FREQUENCY` 只接受枚举值 | 保持 `10000000`（10 MHz） |
| `readback_hw_cfgmem` 报 `27-3138 indirect programming bitstream was not found` | 7 系列不支持 cfgmem 回读 | 无视；校验靠 `PROGRAM.VERIFY 1` |

## 7. 本次记录

| 项 | 值 |
|---|---|
| 位流 | `deliverables/data/v67/enc_top_lowsig.bit`，1,504,428 B，mtime 2026-10-29 10:36:27 |
| mcs | `_flash2_work/enc_top_lowsig.mcs`，4,231,018 B |
| cfgmem part | `mt25ql128-spi-x1_x2_x4` |
| 结果 | `Erase Operation successful.` / `Program/Verify Operation successful.` / `INFO: [Labtoolstcl 44-377] Flash programming completed successfully`，38 s |
| 复加载 | `boot_hw_device` → `Done pin status: HIGH`，`CONFIG_STATUS=0x401079FC` |
| 日志 | `_flash2_work/flash_pre_ibit.log`（首次成功）、`_flash2_work/full_flash.log`（打补丁后整脚本跑通） |

### 7.1 断电重上电验证（2026-10-30 17:26，用户手动断电）

**不接 Vivado、不开 Vivado，板子自己起来了。**

| 项 | 结果 |
|---|---|
| JTAG 回读（新进程，未下载任何位流） | `targets=localhost:3121/xilinx_tcf/Digilent/210512180081`，`dev=xc7a35t_0`，`CONFIG_STATUS=01000000000100000111100111111100`（`0x401079FC`，**DONE=1**），**`PROGRAM.FILE=` 为空** ⇒ 配置来自 Flash，不是 JTAG |
| UART 身份（`host/selftest_link.py --port COM9 --seconds 2`） | `0x05F0 → DEVICE_ID=0x0C / REV=0x10`；**`0x05F2 → RTL_BUILD = 0x000F` ＝ v67**；`0x0101 INTER0=0x0020`、`0x0109 OUTPUT=0x00C0` |
| 数据面 | 2.03 s 收 20,153 帧 = **9,919 帧/s、179,934 B/s**（板上 10 kHz × 18 B，2 Mbaud 链路 90% 占用）；`结论：自检通过 (PASS)` |
| 链路固有校验错 | 78 帧（0.386%）/ 重同步 1,428 B —— 与 2026-10-13 参照测量（212 帧 / 3,940 B @179,963 B/s）同一量级，属 90% 占用下的固有特性，非本次烧写引入 |

> 断电重上电后 CH340 的串口号从 **COM8 变成 COM9**（USB 重新枚举），
> `selftest_link.py` 不写 `--port` 时会自动挑 CH340，写死端口的话记得跟着改。

