# Wiring Guide

## Required Hardware

| Item | Notes |
|---|---|
| PYNQ-Z2 board | With SD card loaded with PYNQ 3.0 image |
| PMOD DA4 (AD5628-1) | 8-channel 12-bit SPI DAC |
| PMOD AD2 | XADC-compatible differential/single-ended ADC |
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

## PMOD AD2 Connections (JB Header)

The PMOD AD2 plugs into the **JB** header on the PYNQ-Z2.

| PMOD AD2 Pin | JB Header Pin | Signal Name | Direction |
|---|---|---|---|
| 1 (VIN+) | JB[0] | `adc_vin_p` | ADC → PL (XADC) |
| 2 (VIN−) | JB[1] | `adc_vin_n` | ADC → PL (XADC) |
| 3 (NC) | JB[2] | — | — |
| 4 (NC) | JB[3] | — | — |
| 5 (GND) | JB GND | GND | — |
| 6 (VCC) | JB VCC | 3.3 V | — |

---

## Loopback Wire

Connect the DAC Ch A analog output to the ADC input with a single jumper wire:

| From | To | Notes |
|---|---|---|
| PMOD DA4 VOUT (Ch A) | PMOD AD2 VIN+ | ECG analog signal, 0–2.5 V |
| PMOD DA4 GND | PMOD AD2 GND | Common ground reference |

**Voltage range note:** The AD5628-1 uses a 2.5 V internal reference; DAC output spans 0 V (code 0x000) to 2.5 V (code 0xFFF). The PMOD AD2 / XADC auxiliary input accepts 0–1.0 V differential or 0–3.3 V single-ended. Check the PMOD AD2 schematic — if no built-in attenuator is present, a 2:1 resistor divider (e.g., 10 kΩ + 10 kΩ) is required to scale the 2.5 V full-scale down to the 1.0 V XADC range.

---

## Photo Placeholder

![Wiring diagram](images/wiring.jpg)

---

_Last updated: Milestone 1 — Signal Generation_
