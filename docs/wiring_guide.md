# Wiring Guide

## Required Hardware

| Item | Notes |
|---|---|
| PYNQ-Z2 board | With SD card loaded with PYNQ 3.0 image |
| PMOD DA4 (AD5628-1) | 8-channel 12-bit SPI DAC |
| PMOD AD2 (AD7991-0) | I²C 12-bit ADC, 4-channel single-ended, 0–VCC range |
| 1× jumper wire | DAC VOUT (Ch A) to ADC VIN loopback |

---

## PMOD DA4 Connections (JA Header)

The PMOD DA4 plugs into the **JA** header on the PYNQ-Z2.

| PMOD DA4 Pin | JA Header Pin | Signal Name | Direction |
|---|---|---|---|
| 1 (CS) | JA[0] | `dac_cs_n` | PL → DAC |
| 2 (DIN) | JA[1] | `dac_din` | PL → DAC |
| 3 (NC) | JA[2] | — | — |
| 4 (SCLK) | JA[3] | `dac_sclk` | PL → DAC |
| 5 (GND) | JA GND | GND | — |
| 6 (VCC) | JA VCC | 3.3 V | — |

> SPI mode: CPOL=1, CPHA=0 — SCLK idles HIGH, AD5628-1 samples on the falling edge.

---

## PMOD AD2 Connections (JB Header — right half)

The PMOD AD2 plugs into the **right half of JB** (physical pins JB3/JB4).
This aligns the module's GND/VCC to the host power rails with no jumper wires.

> **PMOD AD2 (AD7991-0) uses I²C — not XADC.**
> Digilent I²C PMOD standard: Pin 1 = SCL, Pin 2 = SDA.

| PMOD AD2 Pin | JB Header Pin | FPGA Pin | Signal Name | Direction |
|---|---|---|---|---|
| 1 (SCL) | JB[2] / JB3 | V10 | `adc_scl` | PL → ADC |
| 2 (SDA) | JB[3] / JB4 | W10 | `adc_sda` | Bidirectional (open-drain) |
| 3 (NC) | — | — | — | — |
| 4 (NC) | — | — | — | — |
| 5 (GND) | JB GND | — | GND | — |
| 6 (VCC) | JB VCC | — | 3.3 V | — |

> JB[0] and JB[1] (left half, pins JB1/JB2) are **not used** for the ADC.

---

## Loopback Wire

Connect the DAC Ch A analog output to the ADC input with a single jumper wire:

| From | To | Notes |
|---|---|---|
| PMOD DA4 VOUT (Ch A) | PMOD AD2 CH0 (VIN) | ECG analog signal, 0–2.5 V |
| PMOD DA4 GND | PMOD AD2 GND | Common ground reference |

**Voltage range note:** The AD5628-1 DAC output spans 0–2.5 V (2.5 V internal Vref).
The AD7991-0 ADC on PMOD AD2 accepts 0–VCC (0–3.3 V) single-ended per channel.
No voltage divider is needed — 2.5 V is within the 3.3 V ADC range.

---

## Photo Placeholder

![Wiring diagram](images/wiring.jpg)

---

_Last updated: post-M6 fix — JB pin reassignment (SCL→V10/JB[2], SDA→W10/JB[3])_
