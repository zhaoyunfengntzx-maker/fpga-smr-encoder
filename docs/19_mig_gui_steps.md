# 19 · 在 Vivado 里用 GUI 生成 DDR3 MIG（一次性的 5 分钟操作）

> 为什么必须走 GUI：MIG 4.2 的 DDR3 参数在 Vivado 2026.1 里不通过 Tcl 暴露
> （`tools/mig_build.tcl` 的注释记录了 4 轮实测），只能在界面上选过 Memory Type
> 之后参数表才展开。做完这一次，导出的 `.xci` 就是纯文件，后面全部可以脚本化。
>
> 产物：`ip/mig_7series_0/`（整个目录，里面至少有 `mig_7series_0.xci`）。

---

## 0. 先准备两样东西

| 文件 | 用途 |
|---|---|
| `constr/ddr3_pins.ucf` | MIG 的 **Pin Selection → Import** 用（48 根 DDR3 引脚） |
| `constr/ddr3_pins.xdc` | 同一份引脚的 Vivado 版（如果 Import 不认 UCF，就照它手填） |

---

## 1. 打开 Vivado 并建一个空工程

1. 开始菜单搜 `Vivado 2026.1`，或命令行：
   ```powershell
   Start-Process 'D:\Vivado\2026.1\Vivado\bin\vivado.bat'
   ```
2. 欢迎页点 **Create Project** → Next。
3. Project name 随便填 `mig_scratch`，Location 选 `C:\Users\zhaoy\Desktop\FPGA\_mig_gui`（**不要**建在工程根目录，免得和正式工程混）。
4. Project Type 选 **RTL Project**，**不要**勾 "Do not specify sources at this time"（勾了也行）。
5. Add Sources / Add Constraints 两页直接 **Next**（什么都不加）。
6. Default Part 页：**Parts** 标签 → 搜索 `xc7a35tfgg484-2` → 选中 → Next → Finish。

> 检查点：左上角器件显示 `xc7a35tfgg484-2`。选错型号 MIG 会拒绝对话框里的速率等级。

---

## 2. 打开 MIG

1. 左侧 **Flow Navigator → IP Catalog**（或 `Window → IP Catalog`）。
2. 搜索框输入 `MIG`。
3. 双击 **Memory Interface Generator (7 Series)**（在 `Memory & Storage Elements → Memory Interface Generators` 下）。

弹出配置向导，下面按页填。

---

## 3. 第 1 页：Memory Selection

| 项 | 值 |
|---|---|
| Component Name | `mig_7series_0`（保持默认） |
| Memory Type | **DDR3 SDRAM** |
| Memory Part | **MT41K128M16XX-125**（书里用它代 NT5CC128M16JR-EK，容量/位宽一致） |
| Data Width | **16** |
| Data Mask | **勾上**（板上有 DM 脚） |
| ECC | 不勾 |
| Number of Bank Machines | **4** |
| Ordering | **Normal** |

---

## 4. 第 2 页：Controller Options

| 项 | 值 | 说明 |
|---|---|---|
| Memory Speed Grade / 时钟周期 | **2500 ps（=400 MHz）** | 书上就是选 2500 ps |
| PHY to Controller Clock Ratio | **4:1** | 400 MHz 只支持 4:1 |
| Input Clock Period | **5000 ps（=200 MHz）** | 由板上 50 MHz 经 MMCM 生成 |
| Read Data Pipeline | 勾上（默认） | |
| System Clock | **No Buffer** | 时钟从外部 MMCM 直接进 |
| Reference Clock | **Use System Clock** | 板上有 200 MHz 参考即可 |
| Internal Vref | **勾上（启用）** | 见下面 §4.1：BANK35 的 DDR3 占用了 VREF 脚，不启用会报 DRC |
| XADC | **不勾** | |

### 4.1 为什么必须启用 Internal Vref（2026-10-19 实测）

不启用时会报：

```
ERROR: The port ddr3_cke[0] is allocated in the bank 35 where the input ports
are allocated. Enable the Internal Vref to use the Vref as GPIO.
```

原因：DDR3 把 BANK35 塞满，其中 `ddr3_cke` 落在 VREF 引脚上；不启用内部 Vref 时，
MIG 认为该脚只能当参考输入，不能当普通输出。**勾上 Internal Vref** 即可（MIG 会内部
生成参考电压，不再占用 VREF 脚），代价是消耗一点逻辑，对时序没有影响。

> 这一页填完，"Pin Selection" 才会变成可编辑的 **Fixed Pin Out**。

---

## 5. 第 3 页：Pin Selection —— 关键一步

1. 选 **Fixed Pin Out**（不是 System Pin Out）。
2. 点 **Import**，选 `C:\Users\zhaoy\Desktop\FPGA\constr\ddr3_pins.ucf`。
3. 导入成功后，表格里 48 行的 **Pin** 列应全部有值，且与下面几个抽查一致：

   | 信号 | 引脚 |
   |---|---|
   | `ddr3_dq[0]` | C2 |
   | `ddr3_addr[0]` | M5 |
   | `ddr3_ck_p[0]` / `ddr3_ck_n[0]` | P5 / P4 |
   | `ddr3_reset_n` | F4 |

4. **如果 Import 报错**（比如不认 UCF 的注释行）：把 `constr/ddr3_pins.ucf` 用记事本打开，
   删掉开头 3 行 `#` 注释再导入；还不行就照表格逐行手填 Pin 列（48 行，10 分钟）。

> 检查点：表格里不要有红色/空白的 Pin。空白说明某根线没导入，MIG 会用自动引脚——那就白做了。

---

## 6. 第 4、5 页：直接 Next

Bank Selection 页（Fixed 模式下通常灰掉）和 Summary 页都不用改，点 **Next → Generate**。

生成时如果弹 **Generate Output Products**：
- Synthesis Options 选 **Global**；
- 勾 **Generate**（不要求综合完成，生成 IP 输出即可）。

---

## 7. 找到产物并拷回工程

生成完成后，`.xci` 在：

```
C:\Users\zhaoy\Desktop\FPGA\_mig_gui\mig_scratch.srcs\sources_1\ip\mig_7series_0\mig_7series_0.xci
```

把这个 **`mig_7series_0` 整个文件夹**复制到：

```
C:\Users\zhaoy\Desktop\FPGA\ip\mig_7series_0\
```

然后告诉我"好了"，我接着做：
- `rtl/ddr3/ddr3_ring.v`：AXI4 写引擎（ADC → 突发写）+ 读引擎（按绝对序号回放）；
- `rtl/ddr3/sample_mem.v`：BRAM / DDR3 两套实现的统一接口；
- 接进 `stream_tx`，并把 `constr/ddr3_pins.xdc` 加进实现脚本（MIG 自带的 pin xdc 用
  `used_in_synthesis` 排除，避免 LOC 冲突）。

---

## 8. 常见卡点

| 现象 | 原因 / 处理 |
|---|---|
| IP Catalog 里搜不到 MIG | 工程器件没选对（必须是 7 系列），或 IP Catalog 还在加载 |
| "Pin Selection" 是灰的 | 上一页 System Clock / Internal Vref 没按上表填 |
| Import 后表格仍空 | UCF 里有中文注释行；删注释重导，或手填 |
| Generate 报 `clk_ref` 相关错误 | 回第 2 页把 Reference Clock 改成 **Use System Clock** |
| 想撤销重来 | 右键 IP → **Reset Output Products**，再双击重新配置 |
