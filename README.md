PYNQ-Z2 ECG Demo

A full-stack ECG signal demonstration on the PYNQ-Z2 FPGA board. The programmable logic generates a synthetic ECG waveform from real MIT-BIH sample data, drives it to a DAC over SPI, reads it back through an ADC, filters it in hardware, and detects R-peaks in real time. A Python server on the board streams the processed signal over WebSocket to a Streamlit dashboard on a PC.

Hardware

Board: PYNQ-Z2 (Zynq xc7z020)
DAC: PmodDA4 on JA (AD5628-1, SPI, 12-bit)
ADC: PmodAD2 on JB (AD7991-0, I2C, 12-bit)
Loopback: DAC output physically wired to ADC input

Pipeline

ECG ROM → DDS → SPI DAC → [analog loopback] → I2C ADC → FIR Filter → R-peak Detector → AXI → PS → WebSocket → Dashboard
Stack

PL: Verilog RTL (Vivado 2023.2)
PS: Python 3, PYNQ 3.0 framework
PC: Streamlit dashboard
