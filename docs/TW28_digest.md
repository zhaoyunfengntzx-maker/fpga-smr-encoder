# iC-TW28 Technical Digest

Source: `_refs/vendor/TW28_datasheet_D5en.pdf` (text extraction at `_tools/txt/TW28.txt`, 80 pages).
Document revision: **Rev D5, 2022-11-24** (revision history p.78). Copyright © 2015, 2022 iC-Haus.
This digest is a **third-party-derived** document (see `NOTICE`): it quotes values from a datasheet that is
itself distributed under iC-Haus terms, **not** under this repository's MIT licence. The datasheet PDF is
**not redistributed here** — `_refs/vendor/` is excluded from the repository, and the extraction under
`_tools/txt/` is likewise local-only.
All values below are quoted from that extraction. Where the extraction is ambiguous, incomplete, or the
figure text lost layout, this is marked **not determinable from text**.

---

## 1. Chip identity

| Item | Value |
|---|---|
| Full part name | **iC-TW28** — "10-BIT SIN/COS INTERPOLATOR WITH AUTO-CALIBRATION AND LINE DRIVER" |
| Manufacturer | **iC-Haus GmbH**, Am Kuemmerling 18, D-55294 Bodenheim, Germany — www.ichaus.com |
| Data sheet | Rev **D5**, 2022-11-24 |
| Package / order code | **QFN32, 5 mm × 5 mm × 0.9 mm**, RoHS compliant; order designation `iC-TW28 QFN32-5x5` |
| Supply | Single **3.3 V** (3.1 … 3.6 V), three pin pairs AVDD/AVSS, DVDD/DVSS, IOVDD/IOVSS |
| Device ID register | `DEVICE_ID` (0xE000) = **0x0C** |
| Revision registers | `REV1`/`REV0` (0xE003/0xE002): 0x11/0x14 = iC-TW28 X, 0x11/0x15 = iC-TW28 W and W1, 0x04/0x17 = iC-TW28 V1 |
| Evaluation kit | `iC-TW28 EVAL TW28_1D` PCB (≈68 mm × 102 mm) + free Windows GUI |

### Function (one paragraph)
The iC-TW28 is a general-purpose **10-bit application-specific interpolator** for sine/cosine sensor
signals. It accepts differential analog sin/cos signals (and an optional differential index/zero signal)
directly from magnetic or optical sensors, amplifies them with programmable-gain amplifiers, applies coarse
**analog** offset and gain correction, digitizes them with 10-bit ADCs (8-bit for the zero channel), then
applies **digital** offset/amplitude-balance/phase correction, computes the angle within one input cycle as
`arctan(Sin/Cos)` with a **CORDIC** algorithm at **10-bit resolution (1024 increments per input cycle)**,
filters the result in a configurable PI servo loop, scales it to a programmable **interpolation factor** and
emits industry-standard **ABZ incremental quadrature** and/or **UVW block-commutation** outputs through a
built-in **RS422-compatible differential line driver** (or as CMOS single-ended outputs). A 14-bit
multi-cycle counter plus a capture register provide part of an absolute-position path over the SPI port.
Configuration and calibration are held in an on-chip EEPROM and can be programmed by pins, by SPI, or in the
field through the two-wire **Encoder Link** interface.

### Target applications (as listed)
- Rotary and linear encoders
- Magnetic or optical sin/cos sensor interface
- Brushless motor commutation (**2 … 64 poles**; description text also says "1 to 32 pole-pair motors")
- Embedded motion control

### Key selling points / headline numbers

| Parameter | Value |
|---|---|
| Angle resolution | **10 bits = 1024 increments per input cycle** |
| Interpolation factor | **2 … 256** (serial configuration mode); **24 factors** in pin configuration mode (Table 2, groups I0/I1; includes 1 … 256) |
| Max sin/cos input frequency | **700 kHz** (elec. char. item 104); higher allowed in SPI-Only mode because the AB output limit then does not apply |
| AB output frequency | up to **12.5 MHz** (features + ABLIMIT formula); description text says "up to 12 MHz (20 ns edge spacing)" |
| Minimum AB edge spacing | **20 ns** nominal (`tMTD` = 1/f_osc at ABLIMIT = 0x00) |
| Latency | **typ. 1.5 µs** (`MAIN_CFG.noise = 0`), **1.9 µs** (`MAIN_CFG.noise = 1`) |
| INL / DNL | 0.7 ° / 0.35 ° (1 Vpp-diff input, compensated offset/gain/phase) |
| Multi-cycle counter | **14 bits**, up to **16,383 input cycles** |
| Position value | **24 bits** = 14-bit multi-cycle count + 10-bit angle |
| Internal oscillator | ~50 MHz (48…51 MHz @3.1 V, 49…52 MHz @3.6 V), TC 225 ppm/K |
| Auto functions | Auto-calibration (offset, gain/balance, phase, Z channel) and continuous **auto-adaption** |
| Outputs | Differential RS422 ABZ *or* UVW, **and** simultaneous single-ended ABZ + UVW (ABZUVW mode); SPI-Only mode |
| Configuration | Pin configuration (8 resistors) or serial (SPI or Encoder Link); EEPROM stored |
| Extras | LED intensity control PWM output, capture register for coded reference marks / touch-probe, fault/IRQ output, watchdog |

---

## 2. Pinout / interfaces

QFN32-5x5, top view. Backside paddle = TP2 (must be connected to a ground plane at AVSS potential; may also
be used to connect DVSS).

| Pin | Name | Type | Function / notes |
|---|---|---|---|
| 1 | SIN+ | Analog in | Differential sine input + |
| 2 | SIN– | Analog in | Differential sine input – |
| 3 | AVDD | Supply | Analog +3.1…3.6 V; tie to DVDD, IOVDD from a clean source |
| 4 | COS+ | Analog in | Differential cosine input + |
| 5 | COS– | Analog in | Differential cosine input – |
| 6 | AVSS | Ground | Analog ground, solid plane |
| 7 | ZERO+ | Analog in | Differential zero/index input + |
| 8 | ZERO– | Analog in | Differential zero/index input – |
| 9 | VREF | Analog out | ADC reference output. Decouple **100 nF** to AVSS. No noise injection |
| 10 | VC | Analog out | Bias output = **VDD/2**. Decouple **100 nF** to AVSS. Must **not** be used to bias external circuitry or single-ended sin/cos inputs |
| 11, 12, 13 | Reserved | Digital in | Must be tied to **ground** (iC-TW29 uses pin 13 as GPIO) |
| 14 | xRST | Digital in, active low | Reset; device held reset while low. RC 1 kΩ + 100 nF recommended |
| 15 | xCALIB | Digital in, active low | Auto-calibration on falling edge; tie high if unused |
| 16 | xIRQ | Digital out, active low | Interrupt / fault output; push-pull or open-drain. Can drive a fault LED |
| 17 | Z– | Digital / RS422 out | ABZ mode: Z–. UVW mode: W– |
| 18 | Z+ | Digital / RS422 out | ABZ mode: Z+. UVW mode: W+ |
| 19 | IOVSS | Ground | I/O ground |
| 20 | B– | Digital / RS422 out | ABZ mode: B–. UVW mode: V–. Z-calib mode: Z gating window (inverted) |
| 21 | B+ | Digital / RS422 out | ABZ mode: B+. UVW mode: V+. Z-calib mode: Z gating window |
| 22 | IOVDD | Supply | Output driver supply (incl. RS422 and LED); must equal DVDD; can draw up to 100 mA |
| 23 | A– | Digital / RS422 out | ABZ mode: A–. UVW mode: U–. Z-calib mode: un-gated Z (1/input period). Encoder Link: **ELIN input / ELOUT output** |
| 24 | A+ | Digital / RS422 out | ABZ mode: A+. UVW mode: U+. Z-calib mode: un-gated Z. Encoder Link: **ELCLK input** |
| 25 | DVDD | Supply | Digital +3.1…3.6 V |
| 26 | LED | Digital out | LED PWM / intensity-control output; push-pull or open-drain |
| 27 | DVSS | Ground | Digital ground |
| 28 | SO/C3 | Digital out / analog in | SPI slave output (to master MI) or pin-config input **C3** |
| 29 | SI/C2 | Digital in / analog in | SPI slave input (from master MO) or pin-config input **C2** |
| 30 | SCLK/C1 | Digital in / analog in | SPI clock input or pin-config input **C1** |
| 31 | xSS/C0 | Digital in / analog in | SPI slave select (active low) or pin-config input **C0** |
| 32 | PINCFG | Digital in | **DVDD = pin configuration mode**, **DVSS = serial (SPI) configuration mode** |

Unused-pin rules (datasheet footnotes): differential/SPI pins → 10 kΩ to ground (SIN/COS/ZERO/SPI); xRST,
xCALIB, xIRQ, LED → 3.3 V via 10 kΩ; PINCFG must be tied high or low, never float; reserved pins to ground.

### Signal-type / level summary
- **Analog differential**: SIN±, COS±, ZERO± (see §3 for amplitudes and common mode).
- **RS422 differential outputs** (when `MAIN_CFG.rs422 = 1`): A±/U±, B±/V±, Z±/W±, nominal 18…27 mA into a
  120 Ω terminated pair; short-circuit currents –55 mA / +35 mA (spec items 902/903; note release W may exceed
  these at temperature extremes).
- **CMOS digital outputs** (when `MAIN_CFG.rs422 = 0`): same pins, ±10 mA per pin, V_OL / V_OH ≈ 0.7 V at
  ±4 mA, t_r/t_f = 20 ns into 50 pF.
- **CMOS digital inputs**: V_t(hi) = 1.9 V, V_t(lo) = 0.8 V at DVDD = 3.3 V; leakage ±50 nA.
- **xIRQ / LED**: configurable push-pull or open-drain; LED up to ±15 mA continuous.
- **Encoder Link** (only in serial configuration mode) reuses A+/A– as a 2-wire SPI-like interface.

---

## 3. Analog input front end

### Signal levels (elec. char. items 101–111, 201–206; Tables 114, 115)

| Input range | Differential amplitude (peak, `max(SIN+−SIN−)`) | Per-input peak | Permissible absolute input voltage | Sensing-input differential R |
|---|---|---|---|---|
| **Low** (`MAIN_CFG.input = 0`; C3 level 0/3/6/9) | **20 … 700 mV** | 10 … 350 mV | 0.35 V … AVDD − 1.1 V | 10 MΩ … 1000 MΩ |
| **Low with loss detect** (`MAIN_CFG.input = 1`) | 20 … 700 mV | 10 … 350 mV | as above | **0.240 MΩ** (spec item 111) / **220 kΩ** (Table 114) — the two sources disagree |
| **High** (`MAIN_CFG.input = 2`; C3 level 1/4/7/10) | **65 mV … 2000 mV** | 32.5 mV … 1.0 V | 0 V … AVDD | **0.670 MΩ** (item 111) / **620 kΩ** (Table 114) |

- **Common mode** `(SIN+ + SIN−)/2`, likewise for COS:
  minimum gain: **0.7 V … AVDD − 1.45 V**; maximum gain: **0.35 V … AVDD − 1.1 V**.
- Datasheet warning: "1 Vpp signals with 2.5 V common mode cannot be connected directly to the iC-TW28 as the
  common mode voltage is too high."
- Amplifier input offset voltage: **±20 mV** (summed with sensor offset for correction). Input leakage ±50 nA.
- ZERO inputs: permissible input 0 … AVDD, common mode as above, V_os ±20 mV, R_in(diff) 10 MΩ … 1000 MΩ.

### Internal signal conditioning (in order)
1. **Three programmable gain amplifiers (PGAs)** — one each for sin, cos and zero.
   The sin/cos PGAs additionally provide a configurable **9 dB attenuation** so rail-to-rail sensor inputs
   (GMR/TMR, optical) can be used. High input range is implemented with a **resistive attenuator before the PGA**,
   which is why the input impedance differs between the two ranges.
2. **Noise filter after each PGA** — reduces HF noise from the sin/cos inputs; **two settings** in serial mode.
3. **Analog error correction** — coarse analog offset and **gain correction range 6 … 40.5 dB in 1.5 dB steps**
   applied *before* A/D conversion.
4. **ADCs** — **10-bit** for sin and cos, **8-bit** for the zero channel. "The remainder of the signal path is
   completely digital."
   *Extraction quirk:* the `S_ADC` (0x021A) and `C_ADC` (0x021C) register descriptions say each "contains the
   MSB of the **12-bit** sin/cos channel ADC value", while the block-diagram text says 10-bit ADCs. The
   SPI-read *corrected* sin/cos values are given as signed 10-bit; the internal ADC width beyond 10 bits is
   **not determinable from text**.
5. **Zero channel**: 8-bit ADC + configurable comparator generate the Z gating window (see §4/§6).

### External component recommendations (from the electrical-connection figures)
| Item | Value |
|---|---|
| VREF decoupling | 100 nF to AVSS (dedicated) |
| VC decoupling | 100 nF to AVSS (dedicated) |
| Each supply pin (AVDD, DVDD, IOVDD) | 1 µF decoupling close to the device |
| RS422 line termination | **120 Ω at the far (receiving) end** of each of the three pairs; do **not** fit termination when the line driver is disabled |
| xRST network (optional, recommended) | 1 kΩ + 100 nF → ≈**100 µs** delay; larger R gives proportionally longer delay |
| Pin-configuration resistors | 8 resistors (Rx1/Rx2 divider per config pin) to VDD; E48 2 % or E96 1 %; **no decoupling capacitors**; place close to the pins |
| SPI pull-ups/downs | Required if the host can be disconnected (PINCFG = DVSS) |
| Single-ended sensor bias | Biased divider to the sensor zero level (typically half sensor supply). Datasheet: do **not** use VC for this purpose because the input attenuator draws too much current |
| Digital index sensor with open-drain active-low output | Connect to ZERO–, tie ZERO+ to VC (reverse for active-high/open-source) |
| 1 Z pulse per input cycle without index sensor | ZERO+ = 3.3 V, ZERO– = ground (gate window then always high, 360°) |
| No Z output required | ZERO+ = ground, ZERO– = 3.3 V |
| Sensor loss detection | Internal high-value resistors bridge the + and – inputs (selected by `MAIN_CFG.input = 1` / `= 2`); floating inputs collapse the amplitude → `STAT_VAL.scamp` |

No external signal conditioning is required in most applications ("The iC-TW28 requires no external components
for operation" — EEPROM and RS422 drivers are on-chip).

---

## 4. Full signal-processing chain (in order)

```
SIN± / COS± ─► PGA (+optional 9 dB atten) ─► noise filter ─► analog offset+gain corr (6…40.5 dB, 1.5 dB steps)
            ─► 10-bit ADC ─► digital correction (offset, balance/gain, phase)
            ─► arctan(Sin/Cos) CORDIC, 10-bit ─► PI filter (kp/ki, optional 640 ns feedback delay)
            ─► hysteresis ─► interpolation scaling (INTER) ─► post-AB divider (1…8)
            ─► ABZ generator (+Z gating path) ─► RS422 / CMOS outputs
ZERO± ─► PGA ─► analog offset/gain corr ─► 8-bit ADC ─► comparator (ZERO0.threshold) ─► Z gating window ─► Z out
```

### 4.1 Offset / gain / phase correction and how it is calibrated

| Correction | Register(s) | Range / step (datasheet) |
|---|---|---|
| Sin analog offset | `S_OFSA_COR` 0x4013 | ±31 (analog), part of the 6 … 40.5 dB analog gain/offset block |
| Cos analog offset | `C_OFSA_COR` 0x4015 | ±31 |
| Sin digital offset | `S_OFS_COR` 0x4012 | ±127 |
| Cos digital offset | `C_OFS_COR` 0x4014 | ±127 |
| S/C amplitude balance | `SC_BAL_COR` 0x4016 | ±127; correctable mismatch **±25 %, step 0.2 %** |
| S/C digital gain | `SC_GN_COR` 0x4017 | 0…255 |
| S/C analog gain | `SC_GNA_COR` 0x4018 | 0…23 (6 … 40.5 dB in 1.5 dB steps) |
| S/C phase (quadrature) | `SC_PH_COR` 0x4019 | ±127; correctable phase error **±26 °, step 0.22 °** |
| Z analog offset | `Z_OFSA_COR` 0x401A | ±31 |
| Z analog gain | `Z_GNA_COR` 0x401B | 0…23 |
| Correctable total input offset | (auto cal) | **±100 %** of input signal amplitude, step **3.9 mV / gain** |
| Base values (for adaption limit check) | `S_OFS_BASE` 0x4007, `C_OFS_BASE` 0x4008, `SC_BAL_BASE` 0x400B, `SC_PH_BASE` 0x400E | signed 2's complement |
| Adaption limits | `SC_OFS_LIM` 0x4009, `SC_BAL_LIM` 0x400C, `SC_PH_LIM` 0x400F | 0…127 |
| Residue thresholds | `SC_OFS_TH` 0x400A, `SC_BAL_TH` 0x400D, `SC_PH_TH` 0x4010, `Z_PH_TH` 0x4011 | 0…127 |
| Residues (read-only) | `S_OFS_RES` 0x4023, `C_OFS_RES` 0x4024, `SC_BAL_RES` 0x4025, `SC_PH_RES` 0x4026, `Z_PH_RES` 0x4028 | signed ±127 |

**Calibration scheme**
- `SC_AMP_TARG` (0x4004) sets the target `√(sin²+cos²)` after A/D — **recommended 150**, allowed 0…180
  (180 avoids ADC overload; reported as 100 % in the GUI). During auto calibration the chip adjusts analog and
  digital gain to hit this level.
- **Hardware auto-calibration**: pull `xCALIB` low → supply sensor motion (a few hundred sin/cos cycles;
  frequency need not be constant and direction may reverse) → release `xCALIB`. In pin configuration mode
  release stores the values to EEPROM. In serial mode storage on release is controlled by
  `ADAPT_CFG1.xcalee`; if `xcalee = 0`, issue COMMAND 0x12 (copy COR → BASE) then 0x11 (write to EEPROM).
- **Software auto-calibration** (serial mode only): COMMAND **0x23** (all parameters), **0x21** (sin/cos only),
  **0x22** (Z channel only); terminate with **0x20**; then 0x12 then 0x11.
- In pin configuration mode `xCALIB` can be tied permanently to ground → the device self-calibrates at **every
  startup** (no production calibration step).
- **Auto-adaption** runs during operation, controlled per-channel by `ADAPT_CFG0` bits
  (`scofs`, `scbal`, `scph`, `scofsa`, `scgain`, `zofs`, `zgain`, `zphase`; recommended `ADAPT_CFG0 ≤ 7` so that
  analog offset/gain and all Z adaption are used for initial calibration only) and by `ADAPT_CFG1.p`
  (adaption rate: 1/32, 1/16, 1/8, 1/4, 1/2, or 1 COR increment per sin/cos input period), `.stop`
  (stop adaption when `STAT_VAL.scamp = 1`), `.zcal`, `.xcalee`.
- Calibration target for the Z channel: the ZERO signal is tuned to span **75 % of the 8-bit Z ADC range**,
  i.e. digitized amplitude **96**; `zphase` is tuned so the Z pulse is **centred** in the gating window
  (t1 = t2).
- Application hint: with no cyclic input, auto calibration only roughly sets gain/offset to avoid ADC overload.
- After auto calibration all RES registers should read zero/near zero; if not, repeat calibration.

### 4.2 Interpolation core
- Algorithm: **`arctan(Sin/Cos)` using a CORDIC algorithm**, resolution **10 bits** (0…1023 per input cycle).
- No arctan lookup table is mentioned; no CORDIC iteration count / pipeline depth is given →
  **not determinable from text**.
- The 10-bit angle value is scaled to the required output resolution by the interpolation register:
  - `INTER0.interlsb` (0x0101) = INTER[7:0], `INTER1.msbs` (0x0102 bits 1:0) = INTER[9:8]
  - **`INTER = 256 × INTER1.msbs + INTER0.interlsb`**
  - INTER = 0 → **inter = 256**; INTER = 1…7 reserved; INTER = 8…1023 → **inter = INTER/4**
  - `inter` = interpolation factor in **AB output cycles per sin/cos input cycle**.
- Output update rate / latency: filter+path latency **1.5 µs** (`MAIN_CFG.noise = 0`) or **1.9 µs**
  (`MAIN_CFG.noise = 1`). Internal angle/ADC update intervals are 320 ns (see §5). The feature list gives
  "Low latency (typ. 1.5 µs)".
- Application hint: the chip **must be restarted** after changing `inter` to guarantee proper Z alignment.

### 4.3 Filter (digital path)
- Configurable **PI servo loop** with optional **640 ns feedback-path delay** (Figure 39).
- `FILT_K.kp` 0…6 (P gain — larger value = more filtering, less noise/jitter); `FILT_K.ki` 0…3
  (I gain, **recommended 3**; non-zero ki gives zero lag at constant velocity, smaller ki = less lag under
  acceleration but possible overshoot on deceleration); `FILT_CFG.fb` 0/1 (640 ns delay; reduces constant-velocity
  lag by **40 %** with `MAIN_CFG.noise = 0` and **22 %** with `= 1`; requires `FILT_K.kp ≥ 3` for stability);
  `FILT_CFG.auto` 0/1 (static vs dynamic kp); `FILT_CFG.kpmax` 3…6; `FILT_LAG.threshold` 1…31.
- Instability constraints stated: `FILT_K.kp = 0` with `FILT_K.ki = 1` is unstable; if `FILT_K.ki = 0` then
  `FILT_K.kp` must also be 0.
- Recommended presets: fastest = kp 0 / ki 3 / fb 0 / auto 0; light = kp 2, medium = kp 4, heavy = kp 6
  (all ki 3, fb 0, auto 0).
- Pin mode selects light/medium/heavy filtering through input C1.

### 4.4 Hysteresis
- `AB.hyst` (0x0103 bits 4:0) 0…31 and `UVW.hyst` (0x0104 bits 4:0) 0…31:
  **hyst[°] = ± hyst_code × 360° / 2048**. Serial mode = 32 settings; pin mode = 4 settings per path
  (±0.35°, ±0.7°, ±1.4°, ±2.8°).

### 4.5 Error / limit monitoring and fault logic
Eight monitored conditions, each available in `STAT_VAL` (live), `STAT_LATCH` (latched, write-0-to-clear),
selectable into an interrupt through `STAT_SEL` + `STAT_IE`, and independently able to force the ABZ/UVW outputs
to Hi-Z through `STAT_HIZ`:

| Bit | Name | Condition |
|---|---|---|
| 0 | `oflow` | Signal path overflow / saturation (likely ADC overflow) — not fatal, degrades accuracy |
| 1 | `falarm` | Input frequency above the `FALARM` level; **`f_input[MHz] = 1.56 × FALARM / 256`**, FALARM = 1…128 legal (0 and 129…255 reserved); intended as a high-frequency alarm, not accurate measurement |
| 2 | `laglim` | AB outputs lag the input by more than **45 °** of an input cycle (filter is disabled, outputs still valid) |
| 3 | `inclim` | AB output frequency is being limited by `ABLIMIT`, **or** the UVW output frequency > **8.33 MHz**; not fatal, outputs still valid |
| 4 | `lagfatl` | **Fatal** lag: lag reached **180 °** (half an input cycle), outputs invalid (unexpected direction reversal) |
| 5 | `scamp` | `√(sin²+cos²)` outside `SC_AMP_LOW` … `SC_AMP_HIGH`. Pin mode: **< 60 % or > 120 %** of the calibrated value |
| 6 | `adapt` | A COR value deviated from its BASE value by more than the corresponding LIM value |
| 7 | `res` | A residue exceeded its threshold: `|S_OFS_RES|>SC_OFS_TH`, `|C_OFS_RES|>SC_OFS_TH`, `|SC_BAL_RES|>SC_BAL_TH`, `|SC_PH_RES|>SC_PH_TH`, `|Z_PH_RES|>Z_PH_TH` |

- `STAT_CFG.filter` (0…4): condition must persist 0 / 10 µs / 150 µs / 2.5 ms / 40 ms before `STAT_VAL` sets.
- `STAT_CFG.long`: xIRQ prolonged by 40 ms (useful for fault LEDs). `STAT_CFG.enc` = IRQ on multi-cycle-counter
  overflow; `STAT_CFG.enz` = IRQ on position capture.
- `STAT_FATAL` (read-only): bit0 `eechk` EEPROM checksum error, bit1 `ee2bit` EEPROM double-bit error,
  bit2 `interr` internal error. Any of these **inhibit startup or stop the device, disable ABZ/UVW, assert xIRQ**,
  and require a power cycle (or xRST / restart command in hosted systems).
- Pin-configuration-mode fault logic: `STAT_SEL = 0x00` (STAT_VAL used), faults enabled for `scamp`, `lagfatl`,
  `laglim`; `STAT_HIZ = 0x00`, so only a fatal condition disables the outputs.
- AB output frequency limiter: guarantees a minimum separation between AB edges; **6 choices in pin mode,
  256 choices in serial mode**. When limiting, AB lags the input; if transient it catches up, if persistent it
  eventually becomes a fatal lag fault and the device stops.
- Watchdog: `WATCHDOG` (0x401C) — write 0, wait ≥ 1 ms, should read **31 (0x1F)**; any other value indicates
  internal malfunction.

---

## 5. Measured angle / position data path

| Item | Value |
|---|---|
| Fine (angle) resolution | **10 bits**, value 0…1023 (0…360 ° of one sin/cos input cycle) |
| Coarse (multi-turn) resolution | **14 bits** multi-cycle counter, 0…**16,383** input cycles |
| Combined position | **24 bits** = 14-bit multi-cycle count + 10-bit angle, always read together |
| Data format | Unsigned binary, MSB first on the wire |
| Internal update rate | **320 ns** when ABZ outputs are enabled (`OUTPUT.abzen = 1`); **20 ns** when ABZ outputs are disabled (`abzen = 0`, i.e. SPI-Only mode) — the 20 ns value is only *correct* if `INTER = 0` (inter = 256) |
| Latency | Path latency typ. **1.5 µs** (noise filter setting 0), 1.9 µs (setting 1) |
| SPI read latency | Overlapped packets: the response to command *n* is sampled on the falling edge of xSS at the start of command *n+1* → **communication latency = one 32-bit SPI command**, not two. At maximum SPI clock a new position can be read **every 2 µs** |
| Angle always full resolution | "Position (angle) is always returned at the full 10-bit resolution …, regardless of the interpolation value (INTER)" |
| Captured position | Captured on the **rising edge of the Z output** or on the **Z gating window**, selected by `ZERO0.mode`. Captured values are only valid if `INTER = 0` |
| ADC read bank | Corrected sin/cos/zero ADC values, updated every **320 ns** |

### How coarse + fine information is formed
- The 10-bit arctan angle gives the **fine** position inside one input cycle; wrap-around of this angle
  increments/decrements the **14-bit multi-cycle counter** (the coarse/turn count). Each input cycle = one
  sin/cos period, so 24-bit position = turns × 1024 + angle.
- The counter can be **cleared on the Z output** (`ZERO0.clr = 1`) or never cleared (`= 0`); it can be
  **preset over SPI** (Multi-Cycle Counter Write, wm = 1, or atomic read/write, wm = 2) to align with an
  external absolute system.
- **`mcs` synchronization bit**: states the expected half-period sector of the sensor angle when the counter is
  preset (0 = 0…180 °/0…511, 1 = 180…360 °/512…1023). If the actual sector has moved, the counter is preset to
  command ± 1 (specifically −1 if mcs = 0 and 270 ° (768) ≤ angle < 360 ° (1023); +1 if mcs = 1 and
  0 ° ≤ angle ≤ 90 ° (256)). This tolerates up to ±90 ° of misalignment or movement during presetting.
- **Rollover flags**: `mcr` is set when the counter passes a multiple of **4,096** cycles (4,096 / 8,192 /
  12,288 / 0), with 4,096-cycle hysteresis to avoid repeats on direction reversal; `mcrl` if a second rollover
  happens before the position is read. Both reset when the position is read. `STAT_CFG.enc` can turn rollover
  into an xIRQ so a host can extend the counter to any length.
- UVW commutation is derived from the same angle path with its own pole-pair setting and phase shift (§6.2).

---

## 6. Output interfaces in detail

Output mode selection (`OUTPUT.uvwen`, `OUTPUT.abzen`, `MAIN_CFG.rs422`):

| uvwen | abzen | rs422 | Mode | Format | Driver |
|---|---|---|---|---|---|
| 0 | 0 | X | SPI Only | — | Hi-Z |
| 0 | 1 | 0 | ABZ | Differential | CMOS |
| 0 | 1 | 1 | ABZLD | Differential | RS422 |
| 1 | 0 | 0 | UVW | Differential | CMOS |
| 1 | 0 | 1 | UVWLD | Differential | RS422 |
| 1 | 1 | X | ABZUVW | Single-ended (ABZ + UVW) | CMOS |

### 6.1 ABZ incremental output
- **Max output frequency: 12.5 MHz**; **minimum AB edge separation 20 ns** nominal (`tMTD` = 1/f_osc with
  `ABLIMIT = 0x00`).
  `fab[MHz] = 12.5 MHz / ((ABLIMIT + 1) × div)` and `t_edge[ns] = 20 × (ABLIMIT + 1) × div`.
  `ABLIMIT` (0x0106) = 0…255 → max to min output frequency limit (serial mode 256 choices, pin mode 6).
  The limiter applies to the AB frequency **before** the post-AB divider.
  Datasheet note: 12.5 MHz AB frequency with 4 edges per cycle ⇒ 20 ns per edge.
- **Pin-configuration-mode frequency limit choices** (C2, Table 4): 195 kHz / 1.28 µs, 390 kHz / 640 ns,
  781 kHz / 320 ns, 1.56 MHz / 160 ns, 3.12 MHz / 80 ns, **6.25 MHz / 40 ns** (this is the highest in pin mode),
  with auto-adaption either enabled (levels 11…6) or disabled (levels 5…0).
- **Programmable resolution / divider**
  - `INTER` (10-bit, 0x0101 + 0x0102 bits 1:0): inter = 256 when INTER = 0, else inter = INTER/4 (2…255.75).
  - **Post-AB divider** `INTER1.div` (0x0102 bits 4:2): `div = INTER1.div + 1` → **1…8**;
    `inter_eff = inter / div`. Gives fractional/non-integer output resolutions
    (e.g. Table 122: inter_eff 0.25 / 0.50 / 0.75 / 1.00 / 1.25 / 1.50 / 1.75 by combinations of inter and div;
    worked example: 24 sin/cos cycles/rev → 1024 CPR needs inter = 128 with div = 3 ⇒ 512 CPR).
  - **Pin-configuration interpolation factors** (C0/C3, Table 2, "AB output cycles per sin/cos input cycle";
    there are 4× as many AB edges):
    group **I0**: 256, 128, 64, 32, 16, 12, 8, 6, 4, 3, 2, 1;
    group **I1**: 250, 200, 180, 125, 100, 80, 50, 40, 25, 20, 10, 5.
- **Phase / symmetry specs**: output phase A vs B = **25 %** (item 904, Figure 3 definition), duty cycle at A/B
  = **50 %** (item 905). Relative angle accuracy `AArel` (ideal 1 kHz waveform, `FILT_K.kp = 6`):
  **±5 % for INTER < x50, ±10 % for x50…x100, ±15 % for > x100** of the output period.
- **Index (Z) generation rules**
  - Z comes from the ZERO channel: 8-bit ADC + comparator; the internal gating window is active while the
    conditioned ZERO input exceeds **`zthreshold = 4 × ZERO0.threshold`**; threshold in percent of ZERO
    amplitude = `4 × ZERO0.threshold / 96 × 100 %`. Starting values `ZERO0.threshold = 10`, `ZERO1.zwidth = 0`
    give zthreshold = 40 → **42 %** of the ZERO signal (these are the fixed pin-mode values).
  - Z pulse width: `zwidth[edges] = (ZERO1.zwidth + 1) / div`; `ZERO1.zwidth` (0x0108 bits 3:0) = 0…15 and
    **must be less than INTER**.
  - Window width rule to guarantee exactly one Z per revolution:
    `zwidth[°] < gatewidth[°] < 720° − zwidth[°]`, with `zwidth[°] = 90° / inter × zwidth[edges]`.
  - Z phase: `ZPH = 4 × ZPHASE.msb + PHASE_LSB.z`, `zphase[°] = ZPH × 360° / 1024`. Auto Z calibration centres
    the pulse in the window (t1 = t2). Manual setting is needed when no index sensor is used (ZERO+ = 3.3 V,
    ZERO– = GND, gatewidth = 360°).
  - The Z output **bypasses the post-AB divider**, so Z-to-AB synchronization may be lost when div ≠ 1.
  - Z test mode (`TEST.z = 1`, requires `OUTPUT.abzen = 1`): A outputs = un-gated Z (once per input period),
    B outputs = internal Z gating window, Z outputs = gated Z pulse.
  - `ZERO0.mode` (0x0107 bit 7): 0 = position captured on Z output, 1 = captured on Z gating window.
  - `ZERO0.clr` (0x0107 bit 6): 1 = clear the multi-cycle counter on the Z output.
- **Polarity / inversion options**
  - `OUTPUT.apol` (bit 0), `.bpol` (bit 1): normal/inverted A and B; these also define the A/B state while Z is
    active. Setting exactly one of apol/bpol reverses the AB counting direction — then use `abzdir` to restore it.
    Setting both does not change direction.
  - `OUTPUT.zpol` (bit 2): 0 = Z active high, 1 = Z active low.
  - `OUTPUT.abzdir` (bit 3): normal/reversed AB counting direction.
  - `OUTPUT.abzen` (bit 6): ABZ outputs enable; also selects the 320 ns vs 20 ns internal position update rate.
  - Restart required after changing `.apol`/`.bpol` for correct Z alignment.
- **Required external line driver: none.** A **built-in RS422-compatible differential line driver** drives 120 Ω
  terminated cables (18…27 mA nominal; three pairs must be terminated with 120 Ω at the far end). In serial mode
  the driver can be bypassed (`MAIN_CFG.rs422 = 0`) for short/local runs — then the outputs are standard CMOS and
  termination resistors should not be used. App hint: unterminated RS422 drivers cannot handle pull-ups/pull-downs
  and give varying edge shapes.
  The **only** place an external high-current driver is needed is Encoder Link activation, where external drivers
  must overcome the chip's outputs: source/sink **≥ 40 mA** and drive A+/A– to **< 0.8 V and > 2.4 V**.
- **UVW/LED sharing note**: in the ABZUVW mode the three pairs are split into single-ended A+/B+/Z+ and
  U–/V–/W– (UVW appears inverted; set `uvwpol` for normal polarity).

### 6.2 UVW commutation output
- **Pole pairs supported: 1 … 32 pole pairs (= 2 … 64 poles).** `UVW_CFG.pairs` (0x0100 bits 4:0):
  value **0 = 32 UVW cycles per input cycle**, values 1…31 = that many UVW cycles per input cycle.
  The features/description text phrase this as "2...64 poles", "1 to 32 pole-pair motors", "up to 64 poles
  (32 pole pairs)".
- **Commutation type: block (3-phase square-wave) UVW signals**, "for commutating brushless motors".
  A sine-commutation output is **not** provided (not mentioned anywhere in the text). `OUTPUT.uvwen` (bit 7)
  enables the UVW outputs.
- **UVW position resolution / phase programming**
  - UVW phase shift relative to the sin/cos input cycle: `UVWPS = 4 × UVWPH.msb + PHASE_LSB.uvw`,
    `uvwph[°] = UVWPS × 360° / 1024` — i.e. **10-bit phase resolution across the input cycle**
    (`UVWPH` 0x010B = UVWPH[9:2], `PHASE_LSB.uvw` 0x010C bits 3:2 = UVWPH[1:0]).
  - `OUTPUT.uvwpol` (bit 4) inverts the UVW polarity and **shifts UVW phase by 180 °**.
  - `OUTPUT.uvwdir` (bit 5) reverses the phase sequence (rotation direction).
  - `UVW.hyst` 0…31 for standstill jitter reduction (`uvwhyst = ± code × 360°/2048`).
  - UVW frequency limit flag: `STAT_VAL.inclim` also indicates UVW output frequency > **8.33 MHz**.
- **Timing/alignment rules**: programmable UVW phase correction aligns UVW to the motor/input cycle; the exact
  electrical sector boundaries per UVW cycle are **not determinable from text** (Figures show 2-pole UVW, but
  sector widths are not stated numerically).
- **How it is programmed**: `UVW_CFG.pairs`, `UVWPH`, `PHASE_LSB.uvw`, `UVW`, `OUTPUT.uvwen/uvwpol/uvwdir`,
  all EEPROM-stored (E type). Pin configuration mode cannot produce UVW (`UVW_CFG = 0`, "UVW disabled").


### 6.4 Other serial interfaces

**SPI (slave, 4-wire)** — available in serial configuration mode only (PINCFG = DVSS).
- Mode **CPOL = 0, CPHA = 0** only: SCLK rests low, SI sampled on SCLK rising edge, SO changes on the falling edge.
- Max SCLK **20 MHz** (`f(SCLK)` item 704; note that condition is "PINCFG connected to DVSS"), min cycle time
  `tC1` = 50 ns.
- All packets **32 bits, MSB first**; **overlapped** structure: the response to command *n* is returned while
  command *n+1* is shifted in. The very first response (to packet 1) is undefined.
- xSS must be high when xRST is released. xSS must not be pulsed without exactly 32 SCLK edges.
- **Command packet** bits 31:24 = SPI control byte: bit31 `st` (must be 1), bits30:29 `rm` (read mode),
  bits28:27 `wm` (write mode), bits26:24 reserved (0).
  - Write modes `wm`: 0 = Null write (read only), 1 = Multi-Cycle Counter Write, 2 = Multi-Cycle Counter Atomic
    Read/Write, 3 = Register Write (bits 23:8 = address, bits 7:0 = data).
  - Read modes `rm`: 0 = Position and Status Read (20 ns or 320 ns update), 1 = Captured Position and Status Read,
    2 = Sin/Cos/Zero ADC Read (320 ns), 3 = Register Data and Position Read (bits 23:8 = register address, wm must be 0).
- **Response packets**
  - `rm = 0`: bits 31:24 SPI status byte (`fflt` fatal fault, `irq` interrupt active, `zcl` zero capture lost,
    `zc` zero capture occurred, `mcrl` counter rollover lost, `mcr` counter rollover occurred), bits 23:10
    multi-cycle counter (0…16,383), bits 9:0 angle (0…1023).
  - `rm = 1`: status byte, bits 23:10 captured multi-cycle counter, bits 9:0 captured angle.
  - `rm = 2`: bits 31:28 reserved, 27:18 corrected Sin ADC (signed 10-bit), 17:8 corrected Cos ADC (signed
    10-bit), 7:0 corrected Zero ADC (signed 8-bit).
  - `rm = 3`: bits 31:24 register data, 23:10 counter, 9:0 angle.
- **Timing** (items I001–I011): tC1 ≥ 50 ns; clock low ≥ 15 ns; clock high ≥ 15 ns; tS1 (xSS low before SCLK rise)
  ≥ 80 ns; tH1 ≥ 50 ns; tW1 (between xSS high→low) ≥ 200 ns (≥ 600 ns if the preceding command was an ADC read);
  tS2 (SI stable before SCLK rise) ≥ 5 ns; tH2 ≥ 10 ns; tP1 (SO valid after xSS low) ≤ 60 ns;
  tP2 (SO Hi-Z after xSS high) ≤ 25 ns; tP3 (SO valid after SCLK fall) ≤ 20 ns.
- Bussing: shared SCLK/SI/SO, individual xSS, push-pull xIRQ recommended.
- Chaining: shared SCLK/xSS, SI→SO daisy chain, 3 × 32 = 96 bits for three devices, commands execute together
  when xSS goes high; xIRQ must be open-drain and wire-OR'd with a pull-up.

**Encoder Link (2-wire, SPI-like)** — serial configuration mode only; uses **A+ (clock input) and A– (data in/out)**
- Enables field reconfiguration/diagnostics; **cannot** read angle, multi-cycle counter or captured position.
- Activation sequence (Figure 24): external drivers over-power A+ and A– (both high for t1 = 0.25…2 ms, then
  the sequence t2/t3/t4 each = t1 ±10 %); total activation 1…8 ms; afterwards A+/A– are both low and the
  interface is active.
- Timing (items I105–I110): ELink clock **max 1000 kHz** (must be ≤ 500 kHz for operation above 85 °C);
  clock high ≥ 200 ns; clock low ≥ 200 ns; input setup ≥ 200 ns; input hold ≥ 200 ns; output propagation ≤ 200 ns.
- Write command = **32 bits**: ELink control byte (bit31 `st` = 1, bit30 `wr` = 1, bits 29:24 reserved), bits
  23:8 register address, bits 7:0 data. Read command = **40 bits**: command 32 bits + 8-bit wait byte, during
  which the host releases A– and the iC-TW28 drives the addressed register byte back (sampled on the A+ rising edge).
- Deactivation: power cycle or xRST toggle. Can be disabled with `MAIN_CFG.elinkoff = 1` (recommended in
  SPI-Only and ABZUVW modes to avoid accidental activation).

**PWM / other outputs**
- **LED PWM output** (pin 26): delta-sigma modulated, `LED_CFG.freq` selects DSM 3.125 / 6.25 / 12.5 / 25 MHz
  ⇒ PWM 12.2 / 24.4 / 48.8 / **97.6 kHz**; 8-bit duty (`LED_START` 0…255 initial, `LED_PWM` 0x0010 actual);
  polarity, open-drain/push-pull, loop buffer 8/16/24/32; intensity control moves the PWM value ±1 at 500 Hz.
- **xIRQ** digital fault/interrupt output (push-pull or open-drain).
- **No I²C, no SSI, no analog output, no sine output** are present in the datasheet.

---

## 7. Register map

Legend (Type column in the datasheet): **E** = stored in EEPROM and restored at startup/restart;
**D** = dynamic, may be modified by the chip (user may also write it); **R** = dynamic, read-only.
Registers without a code are user read/write. Registers not listed are reserved.

### 7.1 Full register map (addresses and bit fields)

| Address | Name | Bit 7 | Bit 6 | Bit 5 | Bit 4 | Bit 3 | Bit 2 | Bit 1 | Bit 0 | Type |
|---|---|---|---|---|---|---|---|---|---|---|
| 0x0000 | `MAIN_CFG` | 0 | 0 | elinkoff | irqpp | rs422 | noise | input[1:0] | | E |
| 0x0001 | `LED_CFG` | buffer[1:0] (b7:6) | | freq[1:0] (b5:4) | | auto | odrain | pol | en | E |
| 0x0002 | `LED_START` | Initial (starting) LED PWM value (0…255) | | | | | | | | E |
| 0x000B | `TEST` | 0 | 0 | 0 | 0 | 0 | z | 0 | we | — |
| 0x0010 | `LED_PWM` | Actual LED PWM value | | | | | | | | R |
| 0x0100 | `UVW_CFG` | 0 | 0 | 0 | pairs[4:0] | | | | | E |
| 0x0101 | `INTER0` | interlsb (INTER[7:0]) | | | | | | | | E |
| 0x0102 | `INTER1` | 0 | 0 | 0 | div[2:0] | | | intermsbs[1:0] | | E |
| 0x0103 | `AB` | 0 | 0 | 0 | hyst[4:0] | | | | | E |
| 0x0104 | `UVW` | 0 | 0 | 0 | hyst[4:0] | | | | | E |
| 0x0105 | `FALARM` | input frequency alarm level (1…128) | | | | | | | | E |
| 0x0106 | `ABLIMIT` | AB frequency limit (0…255) | | | | | | | | E |
| 0x0107 | `ZERO0` | mode | clr | threshold[5:0] | | | | | | E |
| 0x0108 | `ZERO1` | 0 | 0 | 0 | 0 | zwidth[3:0] | | | | E |
| 0x0109 | `OUTPUT` | uvwen | abzen | uvwdir | uvwpol | abzdir | zpol | bpol | apol | E |
| 0x010A | `ZPHASE` | ZPHASE[9:2] (msb) | | | | | | | | E, D |
| 0x010B | `UVWPH` | UVWPH[9:2] (msb) | | | | | | | | E |
| 0x010C | `PHASE_LSB` | 0 | 0 | 0 | 0 | uvw[1:0] | | z[1:0] | | E, D |
| 0x020C | `Z_ADC` | Zero ADC value (8-bit) | | | | | | | | D |
| 0x021A | `S_ADC` | Sine ADC MSB | | | | | | | | D |
| 0x021C | `C_ADC` | Cosine ADC MSB | | | | | | | | D |
| 0x0300 | `FILT_CFG` | 0 | 0 | 0 | kpmax[2:0] | | | fb | auto | E |
| 0x0301 | `FILT_LAG` | 0 | 0 | 0 | threshold[4:0] | | | | | E |
| 0x0302 | `FILT_K` | 0 | 0 | ki[1:0] | | kp[2:0] | | | | E, D |
| 0x0400 | `STAT_CFG` | 0 | 0 | enz | enc | long | filter[2:0] | | | E |
| 0x0401 | `STAT_SEL` | res | adapt | scamp | lagfatl | inclim | laglim | falarm | oflow | E |
| 0x0402 | `STAT_IE` | res | adapt | scamp | lagfatl | inclim | laglim | falarm | oflow | E |
| 0x0403 | `STAT_HIZ` | res | adapt | scamp | lagfatl | inclim | laglim | falarm | oflow | E |
| 0x0404 | `STAT_VAL` | res | adapt | scamp | lagfatl | inclim | laglim | falarm | oflow | D |
| 0x0405 | `STAT_LATCH` | res | adapt | scamp | lagfatl | inclim | laglim | falarm | oflow | D |
| 0x0406 | `STAT_FATAL` | 0 | 0 | 0 | 0 | 0 | interr | ee2bit | eechk | D |
| 0x0601 | `EE_ADDR` | EEPROM address to read or write | | | | | | | | — |
| 0x0602 | `EE_DATA` | EEPROM data | | | | | | | | D |
| 0x0603 | `EE_STAT` | Validity of read EEPROM data | | | | | | | | D |
| 0x4000 | `COMMAND` | Command register (see 7.3) | | | | | | | | D |
| 0x4001 | `START` | 0 | 0 | nostart | mode[1:0] | | wait[2:0] | | | E |
| 0x4002 | `ADAPT_CFG0` | zphase | zgain | zofs | scgain | scofsa | scph | scbal | scofs | E |
| 0x4003 | `ADAPT_CFG1` | 0 | 0 | xcalee | zcal | stop | p[2:0] | | | E |
| 0x4004 | `SC_AMP_TARG` | Sin/Cos amplitude monitor target (**recommended 150**, 0…180) | | | | | | | | E |
| 0x4005 | `SC_AMP_LOW` | Amplitude monitor low limit (0…SC_AMP_TARG) | | | | | | | | E |
| 0x4006 | `SC_AMP_HIGH` | Amplitude monitor high limit (SC_AMP_TARG…180) | | | | | | | | E |
| 0x4007 | `S_OFS_BASE` | Sin channel digital offset base (±127) | | | | | | | | E |
| 0x4008 | `C_OFS_BASE` | Cos channel digital offset base (±127) | | | | | | | | E |
| 0x4009 | `SC_OFS_LIM` | S/C digital offset limit (0…127) | | | | | | | | E |
| 0x400A | `SC_OFS_TH` | S/C offset residue threshold (0…127) | | | | | | | | E |
| 0x400B | `SC_BAL_BASE` | Sin/Cos balance base (±127) | | | | | | | | E |
| 0x400C | `SC_BAL_LIM` | Sin/Cos balance limit (0…127) | | | | | | | | E |
| 0x400D | `SC_BAL_TH` | Sin/Cos balance residue threshold (0…127) | | | | | | | | E |
| 0x400E | `SC_PH_BASE` | Sin/Cos phase base (±127) | | | | | | | | E |
| 0x400F | `SC_PH_LIM` | Sin/Cos phase limit (0…127) | | | | | | | | E |
| 0x4010 | `SC_PH_TH` | Sin/Cos phase residue (0…127) | | | | | | | | E |
| 0x4011 | `Z_PH_TH` | Z channel phase residue (0…127) | | | | | | | | E |
| 0x4012 | `S_OFS_COR` | Sin digital offset correction (±127) | | | | | | | | E, D |
| 0x4013 | `S_OFSA_COR` | Sin analog offset correction (±31) | | | | | | | | E, D |
| 0x4014 | `C_OFS_COR` | Cos digital offset correction (±127) | | | | | | | | E, D |
| 0x4015 | `C_OFSA_COR` | Cos analog offset correction (±31) | | | | | | | | E, D |
| 0x4016 | `SC_BAL_COR` | Sin/Cos balance correction (±127) | | | | | | | | E, D |
| 0x4017 | `SC_GN_COR` | Sin/Cos digital gain correction (0…255) | | | | | | | | E, D |
| 0x4018 | `SC_GNA_COR` | Sin/Cos analog gain correction (0…23) | | | | | | | | E, D |
| 0x4019 | `SC_PH_COR` | Sin/Cos phase correction (±127) | | | | | | | | E, D |
| 0x401A | `Z_OFSA_COR` | Z analog offset correction (±31) | | | | | | | | E, D |
| 0x401B | `Z_GNA_COR` | Z analog gain correction (0…23) | | | | | | | | E, D |
| 0x401C | `WATCHDOG` | Watchdog: should read 31 (0x1F) when OK | | | | | | | | D |
| 0x4020 | `SC_AMP` | Sin/Cos amplitude √(sin²+cos²) (0…255), updated every 500 µs | | | | | | | | R |
| 0x4021 | `S_AMP` | Sin channel amplitude (0…255), updated once per input cycle or less | | | | | | | | R |
| 0x4022 | `C_AMP` | Cos channel amplitude (0…255) | | | | | | | | R |
| 0x4023 | `S_OFS_RES` | Sin offset residue (±127) | | | | | | | | R |
| 0x4024 | `C_OFS_RES` | Cos offset residue (±127) | | | | | | | | R |
| 0x4025 | `SC_BAL_RES` | Sin/Cos balance residue (±127) | | | | | | | | R |
| 0x4026 | `SC_PH_RES` | Sin/Cos phase residue (±127) | | | | | | | | R |
| 0x4028 | `Z_PH_RES` | Z phase residue (±127) | | | | | | | | R |
| 0xE000 | `DEVICE_ID` | 0x0C | | | | | | | | R |
| 0xE002 | `REV0` | Revision LSB | | | | | | | | R |
| 0xE003 | `REV1` | Revision MSB | | | | | | | | R |

**Reset/default values**: the datasheet does not print a numeric power-on default column for the register map;
the only documented "defaults" are (a) the **pin-configuration-mode values** (Tables 6 and 7, below) and
(b) the factory default noted for `START.wait = 3`. `TEST` (0x000B) is explicitly stated to be 0 at every
startup. **Per-register power-on defaults for serial mode: not determinable from text.**

### 7.2 Pin-configuration-mode register values (Tables 6 and 7 — these are also useful as a safe starting set)
Note: pin-configured register values are **not** stored in EEPROM.

| Register.bit | Value | Meaning |
|---|---|---|
| `MAIN_CFG.input` | from C3 | input range |
| `MAIN_CFG.filter` (noise) | 0 | 500 kHz max input freq., 1.5 µs latency |
| `MAIN_CFG.rs422` | 1 | RS422 ABZ outputs |
| `MAIN_CFG.irqpp` | 0 | open-drain xIRQ |
| `MAIN_CFG.elinkoff` | 1 | Encoder Link not available |
| `LED_CFG` | 0 | LED PWM disabled |
| `UVW_CFG` | 0 | UVW disabled |
| `INTER` | from C0/C3 | interpolation |
| `INTER1.div` | 0 | no post-AB divider |
| `AB.hyst` | from C1 | AB hysteresis/filtering |
| `UVW.hyst` | 0 | 0 ° UVW hysteresis |
| `FALARM` | 0 | no input frequency alarm |
| `ABLIMIT` | from C2 | AB frequency limit |
| `ZERO0.threshold` | 10 | 42 % of signal amplitude |
| `ZERO0.mode` | 0 | position capture on Z |
| `ZERO0.clr` | 0 | never clear multi-cycle counter |
| `ZERO1.zwidth` | 0 | 1 AB edge (quadrature state) |
| `OUTPUT.apol/.bpol` | 0 | normal polarity |
| `OUTPUT.zpol` | 0 | Z active high |
| `OUTPUT.abzdir/.uvwpol/.uvwdir` | 0 | normal direction/polarity/rotation |
| `OUTPUT.abzen` | 1 | ABZ outputs |
| `OUTPUT.uvwen` | 0 | no UVW outputs |
| `ZPHASE` | 0 | affected by C3 |
| `UVWPH` | 0 | no UVW phase shift |
| `FILT_CFG.auto/.fb` | 0 / 0 | static kp, no feedback delay |
| `FILT_CFG.kpmax` | 6 | max. dynamic kp limit |
| `FILT_LAG.threshold` | 12 | filter lag threshold |
| `FILT_K.kp` | from C1 | filter P coefficient |
| `FILT_K.ki` | 3 | maximum ki (recommended) |
| `STAT_CFG.filter` | 3 | 2.5 ms status filter |
| `STAT_CFG.long` | 1 | IRQ extended by 40 ms |
| `STAT_CFG.enc/.enz` | 0 / 0 | no IRQ on counter overflow / position capture |
| `STAT_SEL` | 0 | STAT_VAL used for IRQ |
| `STAT_IE.oflow/.falarm/.laglim/.adapt/.res` | 0 | no IRQ |
| `STAT_IE.inclim/.lagfatl/.scamp` | 1 | IRQ on AB/UVW limit, fatal lag, amplitude lo/hi |
| `STAT_HIZ` | 0 | outputs always enabled |
| `START.wait` | 3 | 10 ms startup wait (factory default) |
| `START.mode` | 1 | same-phase startup (always used in pin mode) |
| `START.nostart` | 0 | automatic startup |
| `ADAPT_CFG0` | from C2 | adaption channels |
| `ADAPT_CFG1.p` | 1 | slow auto-adaption rate (1/16) |
| `ADAPT_CFG1.stop` | 1 | stop auto-adaption on SCAMP |
| `ADAPT_CFG1.zcal` | from C3 | Z calibration with xCALIB |
| `ADAPT_CFG1.xcalee` | 1 | store to EEPROM when xCALIB de-activates |
| `SC_AMP_TARG` | 150 | sin/cos amplitude target |
| `SC_AMP_LOW` | 90 | −40 % of target |
| `SC_AMP_HIGH` | 180 | +20 % of target |
| `S_OFS_BASE`, `C_OFS_BASE`, `SC_OFS_LIM`, `SC_OFS_TH`, `SC_BAL_BASE`, `SC_BAL_LIM`, `SC_BAL_TH`, `SC_PH_BASE`, `SC_PH_LIM`, `SC_PH_TH`, `Z_PH_TH` | 0 / 127 as listed | not used in pin mode |
| `Z_GNA_COR` | 8 | affected by C3 |

### 7.3 COMMAND register (0x4000)
The register auto-clears to 0x00 when the command has executed.

| Value | Command |
|---|---|
| 0x00 | Ready/idle |
| 0x01 | Start/restart interpolation (with currently loaded values) |
| 0x02 | Stop interpolation (ABZ/UVW → Hi-Z, LED deactivated, xIRQ still active) |
| 0x10 | Load configuration and COR registers from EEPROM (does not start) |
| 0x11 | Write configuration + COR + LED values to EEPROM (may take up to **1 s**) |
| 0x12 | Copy COR values to BASE registers (S/C offset, balance, phase) |
| 0x13 | Read EEPROM address (needs ≥ **1 ms**; result in EE_DATA, validity in EE_STAT) |
| 0x14 | Write EEPROM address (needs ≥ **20 ms**) |
| 0x16 | Load configuration and COR registers from EEPROM **and start** interpolation |
| 0x17 | Write COR register values to EEPROM |
| 0x20 | Stop auto calibration |
| 0x21 | Auto calibrate sin and cos parameters |
| 0x22 | Auto calibrate Z channel parameters |
| 0x23 | Auto calibrate all parameters |
| others | Reserved |

Commands marked with * in the datasheet (0x11, 0x14, 0x17) do nothing while the EEPROM is locked
(`TEST.we = 0`). EEPROM map: 0x00–0x03 device serial number (read-only, factory), 0x04–0x3B reserved,
**0x3C–0x3F four user data bytes**, 0x40–0xFF reserved. `EE_STAT`: 0 = valid, 1 = single-bit error corrected
(data valid), 2 = double-bit error (data invalid).

### 7.4 Pin-configuration-mode tables (hardware-only configuration)

**C0 — interpolation factor** (C3 selects group I0/I1)

| C0 level | Group I0 | Group I1 |
|---|---|---|
| 11 | 256 | 250 |
| 10 | 128 | 200 |
| 9 | 64 | 180 |
| 8 | 32 | 125 |
| 7 | 16 | 100 |
| 6 | 12 | 80 |
| 5 | 8 | 50 |
| 4 | 6 | 40 |
| 3 | 4 | 25 |
| 2 | 3 | 20 |
| 1 | 2 | 10 |
| 0 | 1 | 5 |

**C1 — hysteresis / filtering**: levels 11–8 = ±2.8 / ±1.4 / ±0.7 / ±0.35 ° with **heavy** filtering;
7–4 = same four values with **medium**; 3–0 = same four values with **light**.

**C2 — AB frequency limit & auto-adaption**: levels 11–6 = 195 kHz/1.28 µs, 390 kHz/640 ns, 781 kHz/320 ns,
1.56 MHz/160 ns, 3.12 MHz/80 ns, 6.25 MHz/40 ns with adaption **on**; levels 5–0 = same frequencies with
adaption **off**.

**C3 — input range, interpolation group, auto Z calibration**: levels 10/9 = I1 with High/Low range, auto Z yes;
7/6 = I0 High/Low, auto Z yes; 4/3 = I1 High/Low, auto Z no; 1/0 = I0 High/Low, auto Z no; 11, 8, 5, 2 reserved.

**Configuration resistor table (Table 1)** — nominal level → Rx1/Rx2 (kΩ): 11 → 3.30 V (0.00 / ∞);
10 → 3.00 (10.0 / 100); 9 → 2.70 (11.5 / 51.1); 8 → 2.40 (11.5 / 30.1); 7 → 2.10 (16.2 / 28.7); 6 → 1.80 (9.53 / 11.5);
5 → 1.50 (11.5 / 9.53); 4 → 1.20 (28.7 / 16.2); 3 → 0.90 (30.1 / 11.5); 2 → 0.60 (51.1 / 11.5); 1 → 0.30 (100 / 10.0);
0 → 0.00 (∞ / 0.00).

---

## 8. Timing, reset, power-on behaviour

| Item | Value |
|---|---|
| POR turn-on threshold (DVDD rising, xRST tied to DVDD) | **2.5 / 2.7 / 3.0 V** (min/typ/max) |
| Undervoltage reset threshold (DVDD falling) | 2.2 / 2.4 V |
| Startup time to AB output function | **4.5 ms** with `START.wait = 0`; **14.5 ms** with `START.wait = 3` (factory default) |
| Startup wait times | 0 / 1 / 3 / 10 / 30 / 100 / 300 ms (`START.wait`; serial-configurable total wait 0…514 ms) |
| xRST RC recommendation | 1 kΩ + 100 nF ≈ **100 µs** delay; larger R → proportionally longer |
| VDD rise time if xRST is tied directly to VDD | **≥ 40 µs** from 0 V to 3.3 V (release W/W1 notes) |
| xCALIB at power-on | xCALIB must rise **with** the supply — must not be held low by a capacitor |
| Startup sequence | POR monitors supply until 2.7…2.9 V → (pin mode) wait 10 ms → read configuration from EEPROM → start ABZ/UVW generation; (serial mode) programmable wait, and startup may be inhibited (`START.nostart`) |
| On error at startup | Outputs are not enabled; device goes to an idle state with xIRQ asserted |
| Startup modes (`START.mode`) | 0 = relative (A/B state identical after every startup), 1 = same phase (A/B state a function of sensor angle), 2 = absolute burst (angle counted out on A/B at startup, max **2 × inter** edges ±180 ° at the ABLIMIT rate), 3 reserved. Pin mode always uses same-phase. Before startup the AB outputs are Hi-Z |
| Same-phase caveat | Only use if `INTER1.div` ∈ {0,1,3,7} (divider off or power of 2) and inter is an integer |
| Latency | 1.5 µs (`MAIN_CFG.noise = 0`) / 1.9 µs (`MAIN_CFG.noise = 1`) from input change to AB/UVW output |
| Angle/MCC internal update | 320 ns with ABZ enabled; 20 ns with ABZ disabled (valid only for INTER = 0) |
| ADC sample/update | corrected sin/cos/zero values updated every **320 ns**; `S_ADC`/`C_ADC`/`Z_ADC` registers update irregularly at ≈50 µs |
| `SC_AMP` update | every 500 µs |
| `S_AMP` / `C_AMP` update | once per input cycle, or less at high speed |
| AB minimum transition distance `tMTD` | 1/f_osc ≈ 20 ns at `ABLIMIT = 0x00` |
| RS422 timing specs | `tAB` (phase A vs B) = 25 %, `twhi` (duty at A/B) = 50 % |
| Digital output edges | t_r / t_f = 20 ns (DVDD = 3.3 V, C_L = 50 pF, 10–90 %) |
| SPI timing | see §6.4 |
| Encoder Link timing | see §6.4 |
| Jitter example (SPI-Only, 500 kHz input, 2 µs SPI period) | position uncertainty from the 20 ns update = **0.01 input cycles = 3.6 ° = 1 %**; for the ADC read bank the 320 ns update gives 0.16 cycles = 57.6 ° = 16 % |
| Oscillator | 48…51 MHz at 3.1 V, 49…52 MHz at 3.6 V (typ. 50 MHz), tempco 225 ppm/K |
| Frequency formula (pin mode example) | `f_input = AB_frequency / interpolation`; e.g. 1.56 MHz / 250 = 6.24 kHz |
| Lag/lag-fault behaviour | lag > 45 ° → `laglim` (filter disabled, outputs valid); lag ≥ 180 ° → `lagfatl` (fatal, outputs invalid) |

---

## 9. Electrical characteristics

### Absolute maximum ratings
| Item | Value |
|---|---|
| VDD at DVDD/AVDD/IOVDD (to their grounds) | −0.3 … **4.1 V** |
| Pin voltage at any pin | −0.3 … AVDD + 0.3 V |
| Input current into any pin | −2 … +2 mA |
| ESD susceptibility | **HBM 4 kV** (100 pF through 1.5 kΩ) |
| Junction temperature | −40 … 150 °C |
| Storage temperature | −40 … 150 °C |
| Latch-up rating | **not determinable from text** (no latch-up specification is given) |

### Thermal / operating
| Item | Value |
|---|---|
| Operating ambient temperature T_a | **−40 … +125 °C** |
| Thermal resistance R_thja (QFN32 on JEDEC 51 PCB) | **40 K/W** |
| Operating supply | AVDD = DVDD = IOVDD = **3.1 … 3.6 V** |

### Current consumption (3.3 V, f_in = 1 kHz, inter = ×256, ABZ and UVW active)
| Rail | Current |
|---|---|
| I_AVDD | **15 mA** |
| I_DVDD | **22 mA** |
| I_IOVDD | **85 mA** with RS422 drivers enabled and 120 Ω-terminated quadrature outputs; **2.5 mA** with outputs open |
| IOVDD loading note | "IOVDD can require up to 100 mA depending on loads" |

### Other key limits
- RS422 drivers: nominal **18 / 27 mA** into 120 Ω (item 901, D3 revision set a min limit); short-circuit high
  ≤ −55 mA, low ≥ 35 mA (release W note: these limits can be exceeded at low/high temperatures).
- Digital outputs: ±10 mA per pin indefinite; V_s(hi) / V_s(lo) ≈ 0.7 V at ∓4 mA; short-circuit −30/−16 mA and 16/30 mA.
- LED output: ±15 mA continuous; V_out(hi) 2.7 V at −10 mA; V_s(hi) 1 V at −10 mA; V_s(lo) 1 V at 10 mA;
  short-circuit −40 / +40 mA.
- Bias outputs: **VC = 50 % AVDD**; **VREF = VC − 1.0 V** (dVREF −1.1 / −1.0 / −0.9 V).
- Internal EEPROM: write cycles **7 / 50** for chip releases W and W1 and **1000** for release V1
  (columns min/typ/max in the extraction); design-review note for **W1 limits the number of write cycles to 16**.
  Write temperature range −40…+85 °C; read temperature range −40…+125 °C; raw data retention **10 years**.
- EEPROM error protection: checksum plus single-bit error correction and double-bit error detection.

---

## 10. What an FPGA must reproduce

Checklist of every iC-TW28 function a designer would have to re-implement to build a functionally equivalent
sin/cos interpolating encoder. **D** = digital-friendly (fits in FPGA fabric); **A** = analog, must be done with
external components (ADC front end, PGA, references, line drivers, EEPROM); **H** = hybrid (digital core with an
analog or mixed-signal support requirement).

| # | Function (datasheet basis) | D/A/H | Notes for FPGA implementation |
|---|---|---|---|
| 1 | Differential sin/cos input amplification, 20 mV…700 mV (low) or 65 mV…2 V (high) peak | **A** | External instrumentation/PGA stage or external ADC with adequate range; the chip's 6…40.5 dB / 1.5 dB-step analog gain block has no digital equivalent |
| 2 | Configurable 9 dB input attenuation for rail-to-rail (GMR/TMR/optical) sensors | **A** | Resistive attenuator + PGA |
| 3 | Input noise filter after PGA (2 settings) | **A** (or H) | Analog anti-alias filter; a digital decimation filter is an alternative but changes latency |
| 4 | Analog offset/gain correction (coarse, pre-ADC) | **A** | 6…40.5 dB in 1.5 dB steps; offset DAC into the PGA. In an all-digital design this must be an analog trim or a higher-resolution ADC with digital trim |
| 5 | 10-bit sin/cos ADCs (up to ~700 kHz input ⇒ ≥ several MS/s each) | **A** | External dual ADC; note the chip's ADC "sample rate" is **not stated** in the datasheet — equivalent update observable is the 320 ns corrected-ADC update |
| 6 | 8-bit zero/index ADC + comparator | **A** (+D) | Analog ADC + digital comparator with programmable threshold (see #19) |
| 7 | Digital offset correction per channel (`S_OFS_COR`, `C_OFS_COR`, ±127; step 3.9 mV/gain) | **D** | Simple adder with signed coefficient; auto-calibration loop is a digital accumulator |
| 8 | Digital amplitude-balance / gain equalisation (`SC_BAL_COR` ±127, `SC_GN_COR` 0…255; step 0.2 %) | **D** | Multiplier by (1 ± β/2) with β from the coefficient |
| 9 | Digital quadrature/phase correction (`SC_PH_COR` ±127; ±26 °, step 0.22 °) | **D** | Cross-coupling matrix (sin' = sin + k·cos) or CORDIC pre-rotation |
| 10 | Auto-calibration: offset, gain, balance, phase (+Z channel), driven by `xCALIB` or SPI commands 0x21/0x22/0x23, terminated/stored by 0x20/0x11/0x12/0x17 | **D** | Least-squares / servo estimator over a few hundred input cycles; the chip's exact estimator algorithm and convergence time are **not determinable from text** |
| 11 | Auto-adaption during operation, per-channel enables (`ADAPT_CFG0`), rate `ADAPT_CFG1.p` (1/32, 1/16, 1/8, 1/4, 1/2, or 1 COR step per input period), stop-on-`scamp`, Z-cal and store-on-xCALIB flags | **D** | Per-coefficient up/down counters/accumulators clocked once per input cycle |
| 12 | Residual calculation (offset, balance, phase; RES registers) and thresholds (`SC_*_TH`, `Z_PH_TH`) | **D** | Accumulate residual error per cycle, compare with threshold, set status bit |
| 13 | Adaption deviation detection (COR vs BASE vs LIM) | **D** | Absolute difference comparators against EEPROM-stored base/limit pairs |
| 14 | `arctan(Sin/Cos)` **CORDIC**, 10-bit output, one angle per input cycle | **D** | Classic pipelined/iterative CORDIC; 10-bit output = 1024 increments/cycle. Iteration count / pipeline depth of the original is not stated |
| 15 | Interpolation scaling: `INTER = 256·INTER1.msbs + INTER0.lsb`; inter = 256 for INTER = 0, else inter = INTER/4 (2…256 + fractional values) | **D** | Phase accumulator / angle scaler; carry-in/out increments the multi-cycle counter |
| 16 | Optional **post-AB divider** div = `INTER1.div` + 1 = 1…8 after the ABZ generator, with Z bypassing the divider | **D** | Counter-based divider; remember Z is not divided and Z-to-AB sync may be lost |
| 17 | Digital filter: PI servo loop (kp 0…6, ki 0…3, static/dynamic kp, `FILT_CFG.kpmax` 3…6, lag threshold 1…31, optional **640 ns** feedback delay) | **D** | A 640 ns delay at 50 MHz is 32 cycles — the datasheet's delay is stated as an analog-ish figure; implementable as a delay line. Instability rules must be honoured (kp = 0 with ki = 1 is unstable; ki = 0 ⇒ kp = 0; fb = 1 ⇒ kp ≥ 3) |
| 18 | Hysteresis in the AB and UVW paths (`AB.hyst`, `UVW.hyst` 0…31; ±code × 360°/2048) | **D** | Digital window comparator on the position value |
| 19 | Z/index channel: comparator threshold `ZERO0.threshold` (±31), gating window = input > 4×threshold, Z pulse width `ZERO1.zwidth` (0…15, `(zwidth+1)/div` AB edges, must be < INTER), Z phase `ZPH = 4·ZPHASE.msb + PHASE_LSB.z` (`×360°/1024`), pulse centred in the window by auto calibration, gate-width rule `zwidth° < gatewidth° < 720° − zwidth°` | **D** (+A for the zero sensor) | Digital comparator on the (externally) digitized index signal; Z pulse generation must be synchronous to the AB outputs |
| 20 | Z test mode (`TEST.z`) for observing the gating window on B outputs | **D** | Diagnostic mux — useful for bring-up |
| 21 | ABZ output generation: quadrature A/B, 4 edges per output cycle, programmable polarity (`apol`,`bpol`), direction (`abzdir`), Z polarity (`zpol`), 25 % A-to-B phase relationship, 50 % duty | **D** | Straightforward quadrature state machine |
| 22 | AB output frequency limiter: `fab = 12.5 MHz/((ABLIMIT+1)·div)`, `t_edge = 20·(ABLIMIT+1)·div` ns, 0…255 settings, applies before the divider; lag catch-up then fatal-lag behaviour | **D** | Programmable edge-spacing timer + lag accumulator + fatal fault at 180 ° |
| 23 | UVW block commutation: `UVW_CFG.pairs` 1…32 pole pairs (0 = 32), 10-bit phase shift `UVWPS = 4·UVWPH.msb + PHASE_LSB.uvw` (`×360°/1024`), `uvwpol` (180 ° shift), `uvwdir`, `UVW.hyst` 0…31, UVW > 8.33 MHz flag | **D** | 3-phase sector/block generator from the angle accumulator and pole-pair setting; sine commutation is **not** part of the original |
| 24 | SPI slave: 4-wire, **CPOL 0 / CPHA 0**, ≤ 20 MHz, 32-bit MSB-first packets, **overlapped** (response to command n returned during command n+1), control byte (st/rm/wm), read modes 0–3, write modes 0–3, status byte, register/address access | **D** | Must reproduce the overlapped packet timing exactly to be command-compatible; xSS must always be accompanied by exactly 32 clocks |
| 25 | Multi-cycle counter: 14-bit, 0…16,383; clear-on-Z option (`ZERO0.clr`); preset via SPI (wm = 1 / wm = 2); `mcs` sector-synchronization bit with ±1 correction rule; rollover flags at multiples of **4,096** with 4,096-cycle hysteresis (`mcr`, `mcrl`) | **D** | Sign/magnitude tracking from angle wrap-around; must handle direction reversal identically |
| 26 | Position capture register: 24-bit (14-bit MCC + 10-bit angle) on Z output rising edge or Z gating window (`ZERO0.mode`), `zc`/`zcl` status bits, capture IRQ via `STAT_CFG.enz` | **D** | Simple shadow register with overrun flag |
| 27 | Status & fault logic: 8 conditions (`oflow`, `falarm`, `laglim`, `inclim`, `lagfatl`, `scamp`, `adapt`, `res`), live `STAT_VAL`, latched `STAT_LATCH` (write-0-to-clear), `STAT_SEL` source select, `STAT_IE` IRQ enables, `STAT_HIZ` output disable, `STAT_FATAL` (eechk, ee2bit, interr) → fatal shutdown | **D** | Table-driven flag logic; honour the 0/10 µs/150 µs/2.5 ms/40 ms `STAT_CFG.filter` and the 40 ms IRQ extension |
| 28 | Amplitude monitor `√(sin²+cos²)`: `SC_AMP`, `SC_AMP_TARG` (recommended 150, max 180), `SC_AMP_LOW`/`SC_AMP_HIGH`, `SC_AMP` updated every 500 µs, `S_AMP`/`C_AMP` once per input cycle | **D** | Cordic/multiplier or |sin|+|cos| approximation; thresholds are 8-bit codes, not volts |
| 29 | Input frequency alarm: `f[MHz] = 1.56·FALARM/256`, FALARM 1…128 | **D** | Period counter on the angle wrap |
| 30 | LED intensity control: 8-bit DSM/PWM at 12.2/24.4/48.8/97.6 kHz, ±1 step at 500 Hz, buffer 8/16/24/32, polarity and open-drain/push-pull, formula `LED_START = INT(I_nom/I_max · 256)` | **H** | Digital PWM/DSM is FPGA-friendly; the LED current stage (open-drain or external FET, R/C filter sizing) is external |
| 31 | Startup behaviour: `START.wait` (0/1/3/10/30/100/300 ms), `START.nostart`, three startup modes (relative / same phase / absolute burst with up to 2·inter edges), same-phase restrictions on `INTER1.div`, Hi-Z outputs before start | **D** | Needs an equivalent power-on state machine, plus EEPROM load before output enable |
| 32 | Reset / power-on: POR at 2.5…3.0 V, undervoltage at 2.2…2.4 V, external xRST, start-up in 4.5 ms (wait 0) or 14.5 ms (wait 3) | **H** | External supervisor/POR IC + FPGA reset sequencer |
| 33 | Internal 50 MHz oscillator (48…52 MHz, 225 ppm/K) usable as the timing reference | **A** | External crystal/oscillator; the FPGA should not rely on internal RC accuracy |
| 34 | EEPROM for configuration + calibration, with checksum, single-bit correction, double-bit detection, write cycle limit (≈16 for W1), 4 user bytes, device serial number | **A** | External I²C/SPI EEPROM or FPGA configuration flash; must implement the same protection class |
| 35 | RS422 differential ABZ/UVW line driver (18…27 mA, 120 Ω terminated, or bypassed to CMOS) | **A** | External RS422 transceiver(s) — the chip integrates this, an FPGA cannot |
| 36 | Encoder Link 2-wire field-reconfiguration interface (A+/A–, ≤ 1 MHz, activation by over-driving the outputs with ≥ 40 mA drivers, 32-bit write / 40-bit read frames) | **D** (+A driver) | Digital protocol is reproducible; the external over-drive drivers are analog/drive-strength work. Note that on the original, Encoder Link cannot read position |
| 37 | Watchdog register (must read 31 = 0x1F within ≥ 1 ms of being cleared) | **D** | Trivial |
| 38 | Electrical envelope: 3.1…3.6 V, ~15/22/85 mA rails, −40…+125 °C ambient, 40 K/W, 4 kV HBM ESD | **A** | Board-level/analog responsibility |

**Minimum viable FPGA partition (summary)**: items **7–30, 31, 32 (digital part), 33 (as an input clock), 36, 37**
are the digital core that must be reproduced for functional equivalence. Items **1–6, 30 (LED drive), 33
(oscillator), 34 (EEPROM), 35 (RS422), 38** are analog/board-level and must come from external devices — in
particular the interpolator cannot function without an external dual ADC that meets or exceeds the original
10-bit sin/cos and 8-bit zero conversion, and without an external RS422 line driver if differential ABZ/UVW
outputs are required.

---

### Extraction caveats encountered (do not treat as datasheet facts)
1. The features list says "AB output frequency of up to 12.5 MHz" while the description says "up to 12 MHz
   (20 ns edge spacing)". The ABLIMIT formula uses **12.5 MHz**, consistent with a 20 ns minimum edge spacing at
   4 edges/cycle.
2. Sin/cos ADC resolution: block-diagram text says 10-bit; the `S_ADC`/`C_ADC` register text says "MSB of the
   12-bit sin channel ADC value". The two are not reconciled in the text.
3. Input impedance of the loss-detect and high ranges: elec. char. items 111 give 0.240 MΩ / 0.670 MΩ while
   Table 114 gives 220 kΩ / 620 kΩ.
4. EEPROM write-cycle limit: elec. char. item 501 gives 7 / 50 for releases W and W1 and 1000 for V1, while the
   W1 design-review note limits W1 to **16** cycles.
5. No power-on default column exists in the register map for serial configuration mode; only the pin-mode values
   (Tables 6/7) and `START.wait = 3` (factory default) are stated.
6. `START.mode = 1` (same phase) is described as "always used in pin configuration mode", and Table 6 lists
   `START.mode = 1` for pin mode.
7. The `UVWPH` phase formula is printed in the extraction as `uvwph[°] = uvwph × 360° / 1024`, which is
   self-referential; the variable computed by `UVWPS = 4 × UVWPH.msb + PHASE_LSB.uvw` is evidently the intended
   operand.
