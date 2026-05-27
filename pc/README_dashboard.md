# PYNQ-Z2 ECG Dashboard

Streamlit-based live ECG monitor for the PYNQ-Z2 board.

## Requirements

- Python 3.10 or newer
- A network connection to the PYNQ-Z2 board (default IP `192.168.2.99`)

## Install

```bash
pip install -r requirements.txt
```

## Run

```bash
# Make the launch script executable (Linux / macOS / WSL)
chmod +x run_dashboard.sh

./run_dashboard.sh
```

Or run directly:

```bash
streamlit run dashboard.py --server.port 8501 --server.headless false
```

## Open

Navigate to `http://localhost:8501` in your browser.

## Usage

1. **Connect** — Enter the board IP address in the _Board IP_ field and click **Connect**.
   The status badge turns green and the ECG waveform starts scrolling.

2. **Waveform** — Three overlaid traces are shown:
   - Blue (`#4488FF`, 50 % opacity) — DAC reference waveform
   - Grey (40 % opacity) — raw ADC samples
   - Green (`#00FF88`) — FIR-filtered ECG
   - Red dots mark detected R-peaks

3. **Heart Rate** — Displayed as a large metric in the top-right corner with a
   delta indicator showing the change from the previous beat.

4. **Adjust config** — Use the four sliders to change board parameters:

   | Slider | Range | Default |
   |---|---|---|
   | Heart Rate (BPM) | 30–240 | 60 |
   | RR Variation | 0–255 | 0 |
   | Amplitude Variation | 0–255 | 0 |
   | Detection Threshold | 0–4095 | 2983 |

   Click **Apply Config** to send the values to the board. Sliders do not
   auto-send — this prevents flooding the AXI bus with writes.

5. **Download CSV** — Click **Download CSV** to export all samples received
   during the current session.

   CSV columns: `timestamp_ms, ecg_raw, ecg_dac, ecg_filtered, bpm, rpeak`

6. **Disconnect** — Click **Disconnect** to close the WebSocket connection.
   The existing buffer and recording are preserved so you can still export data.

## Notes

- If the board disconnects mid-session the dashboard shows a reconnecting state
  and retries automatically every 3 seconds. Buffered data is not lost.
- The `⚠ Signal Lost` badge appears when the board reports `lead_off = true`.
- The chart refreshes at approximately 10 fps (100 ms rerun cycle).

## WebSocket / REST endpoints (provided by `ps/server.py`)

| Endpoint | Method | Description |
|---|---|---|
| `ws://{board_ip}:5000/ws` | WS | 360 Hz ECG packet stream |
| `http://{board_ip}:5000/status` | GET | Current config + status JSON |
| `http://{board_ip}:5000/config` | POST | Write config registers |
