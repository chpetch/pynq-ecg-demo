# pynq_gui — ECG Dashboard GUI Agent

## Your Role
You are a frontend Python engineer. You build a Streamlit dashboard that
connects to the PYNQ-Z2 PS server over WebSocket, displays a live ECG
waveform, and lets the user send config commands back to the board.

You do NOT write Verilog, server-side Python, or anything outside `pc/`.

## Recommended Model
This agent is suitable for Gemini 2.5 Pro.

## Style Convention
- Python 3.10+, snake_case, UPPER_SNAKE_CASE constants
- Streamlit for all UI — no Flask, no Dash
- Plotly for all charts — no matplotlib
- Comments: # inline only
- No global mutable state — use st.session_state exclusively

---

## Read Before Starting — Mandatory
1. `handoffs/ws_schema.json` — exact WebSocket JSON packet format from PS
2. `handoffs/register_map.md` — register names, ranges, defaults for sliders

---

## Files You Must Produce

### 1. `pc/dashboard.py`
Single-file Streamlit app. Structure:

#### Constants (top of file)
```python
DEFAULT_BOARD_IP   = "192.168.2.99"
WS_PORT            = 5000
REST_PORT          = 5000
SAMPLE_RATE        = 360          # Hz
DISPLAY_WINDOW_SEC = 5            # seconds of ECG shown at once
MAX_BUFFER         = SAMPLE_RATE * DISPLAY_WINDOW_SEC  # 1800 samples
```

#### Layout — two columns
```
┌─────────────────────────────────────────────────────┐
│  🫀 PYNQ-Z2 ECG Demo          [status badge] [BPM]  │
├──────────────────────────────┬──────────────────────┤
│                              │  Board IP: [input]   │
│   ECG Waveform (Plotly)      │  [Connect] [Disconn] │
│   Raw (grey) + Filtered (green)                     │
│   R-peaks marked as red dots │  ── Config ──        │
│                              │  Heart Rate (BPM)    │
│                              │  [slider 30–240]     │
│                              │                      │
│                              │  RR Variation        │
│                              │  [slider 0–255]      │
│                              │                      │
│                              │  Amplitude Variation │
│                              │  [slider 0–255]      │
│                              │                      │
│                              │  Detection Threshold │
│                              │  [slider 0–4095]     │
│                              │                      │
│                              │  [Apply Config]      │
│                              │  ── Export ──        │
│                              │  [Download CSV]      │
└──────────────────────────────┴──────────────────────┘
```

#### WebSocket connection
- Run WebSocket client in a background thread using `websockets` library
- Store received packets in `st.session_state.buffer` (a `collections.deque`)
- Deque max length = `MAX_BUFFER`
- Thread-safe: use `threading.Lock()` for buffer access
- On disconnect: set `st.session_state.connected = False`, retry after 3s
- On connect: fetch current config via `GET /status`, populate slider defaults

#### ECG waveform chart
- Plotly `go.Figure` with two traces:
  - Raw ECG: grey, opacity 0.4, line width 1
  - Filtered ECG: `#00FF88` (green), line width 1.5
- R-peak markers: red dots (`mode="markers"`) at detected rpeak positions
- X-axis: time in seconds (0 to DISPLAY_WINDOW_SEC), no zoom
- Y-axis: 0–4095 (12-bit range), labelled "ADC counts"
- Dark background: `plot_bgcolor="#0E1117"`, `paper_bgcolor="#0E1117"`
- No legend box — use trace names only
- Update via `st.empty()` placeholder, call `st.rerun()` every 100ms

#### BPM display
- Large metric: `st.metric("Heart Rate", f"{bpm} BPM")`
- Show delta from last beat: `delta=f"{bpm - prev_bpm:+d}"`
- Colour: green if 50–100, amber if outside range

#### Status badge
- Green `●  Connected` or red `●  Disconnected`
- Show board IP when connected
- Show `⚠ Signal Lost` if `status.lead_off` is true

#### Config sliders
```python
bpm_val       = st.slider("Heart Rate (BPM)", 30, 240, 60)
rr_val        = st.slider("RR Variation", 0, 255, 0)
amp_val       = st.slider("Amplitude Variation", 0, 255, 0)
thresh_val    = st.slider("Detection Threshold", 0, 4095, 2048)
```
- Populate defaults from `GET /status` on first connect
- [Apply Config] button POSTs to `http://{board_ip}:{REST_PORT}/config`
- Show success toast: `st.toast("Config applied ✓")` on 200 response
- Show error: `st.error(...)` on failure

#### CSV export
- Buffer all received packets in `st.session_state.recording`
- [Download CSV] uses `st.download_button`
- CSV columns: `timestamp_ms, ecg_raw, ecg_filtered, bpm, rpeak`
- Filename: `ecg_recording_{datetime}.csv`

---

### 2. `pc/requirements.txt`
```
streamlit>=1.32
plotly>=5.18
websockets>=12.0
requests>=2.31
```

### 3. `pc/run_dashboard.sh`
```bash
#!/bin/bash
streamlit run dashboard.py --server.port 8501 --server.headless false
```

### 4. `pc/README_dashboard.md`
Short usage guide:
- Install: `pip install -r requirements.txt`
- Run: `./run_dashboard.sh`
- Open: `http://localhost:8501`
- Enter board IP, click Connect
- Adjust sliders, click Apply Config to update board in real time
- Click Download CSV to export recording

---

## Rules
- Never use `time.sleep()` in the main Streamlit thread — it blocks the UI
- Never use global variables — all state in `st.session_state`
- Chart must update smoothly at ~10 fps (every 100ms rerun) — use
  `st.empty()` placeholder, not a full page rerun for the chart only
- Slider changes do NOT auto-send — user must click [Apply Config]
  to avoid flooding the board with AXI writes
- If WebSocket disconnects mid-session, show reconnecting spinner,
  do not lose the existing buffer data

## What Success Looks Like
When done, the following must exist:
- `pc/dashboard.py`
- `pc/requirements.txt`
- `pc/run_dashboard.sh` (executable)
- `pc/README_dashboard.md`

The orchestrator will check all four files before proceeding to pynq_docs.
