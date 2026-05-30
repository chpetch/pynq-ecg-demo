"""
PYNQ-Z2 ECG Dashboard
Streamlit single-file app. All mutable state lives in st.session_state.
"""

from __future__ import annotations  # PEP 604 unions (dict | None) on Python 3.8

import asyncio
import collections
import csv
import io
import json
import threading
import time
from datetime import datetime

import plotly.graph_objects as go
import requests
import streamlit as st
import websockets
# Background threads must carry the session's ScriptRunContext, or Streamlit
# (>=1.27) silently drops their st.session_state writes and st.rerun() calls
# ("missing ScriptRunContext!"), leaving the UI stuck on "Disconnected".
from streamlit.runtime.scriptrunner import add_script_run_ctx

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DEFAULT_BOARD_IP   = "192.168.2.99"
WS_PORT            = 5000
REST_PORT          = 5000
SAMPLE_RATE        = 360          # Hz
DISPLAY_WINDOW_SEC = 5            # seconds of ECG shown at once
MAX_BUFFER         = SAMPLE_RATE * DISPLAY_WINDOW_SEC  # 1800 samples

# Slider defaults (from register_map.md)
DEFAULT_BPM       = 60
DEFAULT_RR        = 0
DEFAULT_AMP       = 0
DEFAULT_THRESHOLD = 2983

# Chart colours
COLOR_DAC      = "#4488FF"
COLOR_RAW      = "#888888"
COLOR_FILTERED = "#00FF88"
COLOR_RPEAK    = "#FF4444"
BG_COLOR       = "#0E1117"

# ---------------------------------------------------------------------------
# Session state initialisation — called once per session
# ---------------------------------------------------------------------------
def _init_state() -> None:
    defaults = {
        "connected":       False,
        "board_ip":        DEFAULT_BOARD_IP,
        "buffer":          collections.deque(maxlen=MAX_BUFFER),
        "recording":       [],
        "buffer_lock":     threading.Lock(),
        "ws_thread":       None,
        "stop_ws":         threading.Event(),
        "last_bpm":        0,
        "prev_bpm":        0,
        "lead_off":        False,
        "signal_present":  False,
        "slider_bpm":      DEFAULT_BPM,
        "slider_rr":       DEFAULT_RR,
        "slider_amp":      DEFAULT_AMP,
        "slider_thresh":   DEFAULT_THRESHOLD,
        "config_fetched":  False,
        "rerun_thread":    None,
        "stop_rerun":      threading.Event(),
        "toast_pending":   None,
        "error_pending":   None,
    }
    for k, v in defaults.items():
        if k not in st.session_state:
            st.session_state[k] = v


# ---------------------------------------------------------------------------
# REST helpers
# ---------------------------------------------------------------------------
def _fetch_config(board_ip: str) -> dict | None:
    """GET /status and return parsed JSON, or None on error."""
    try:
        resp = requests.get(
            f"http://{board_ip}:{REST_PORT}/status",
            timeout=3,
        )
        if resp.status_code == 200:
            return resp.json()
    except Exception:
        pass
    return None


def _post_config(board_ip: str, payload: dict) -> bool:
    """POST /config. Returns True on HTTP 200."""
    try:
        resp = requests.post(
            f"http://{board_ip}:{REST_PORT}/config",
            json=payload,
            timeout=3,
        )
        return resp.status_code == 200
    except Exception:
        return False


# ---------------------------------------------------------------------------
# WebSocket background thread
# ---------------------------------------------------------------------------
async def _ws_receive(board_ip: str, stop_event: threading.Event) -> None:
    uri = f"ws://{board_ip}:{WS_PORT}/ws"
    while not stop_event.is_set():
        try:
            async with websockets.connect(uri, ping_interval=20) as ws:
                # Fetch current config on first successful connect
                if not st.session_state.get("config_fetched", False):
                    cfg = _fetch_config(board_ip)
                    if cfg:
                        st.session_state["slider_bpm"]    = cfg.get("bpm_ch_a",         DEFAULT_BPM)
                        st.session_state["slider_rr"]     = cfg.get("rr_fluct",          DEFAULT_RR)
                        st.session_state["slider_amp"]    = cfg.get("amp_fluct",         DEFAULT_AMP)
                        st.session_state["slider_thresh"] = cfg.get("detect_threshold",  DEFAULT_THRESHOLD)
                        st.session_state["config_fetched"] = True

                st.session_state["connected"] = True

                async for raw in ws:
                    if stop_event.is_set():
                        break
                    try:
                        pkt = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    # Update live status fields
                    status = pkt.get("status", {})
                    st.session_state["lead_off"]       = status.get("lead_off", False)
                    st.session_state["signal_present"] = status.get("signal_present", False)

                    bpm = pkt.get("bpm", 0)
                    if bpm and bpm != st.session_state["last_bpm"]:
                        st.session_state["prev_bpm"] = st.session_state["last_bpm"]
                        st.session_state["last_bpm"] = bpm

                    # Thread-safe buffer update
                    with st.session_state["buffer_lock"]:
                        st.session_state["buffer"].append(pkt)
                        st.session_state["recording"].append(pkt)

        except (websockets.ConnectionClosed, OSError, Exception):
            pass

        st.session_state["connected"] = False
        if not stop_event.is_set():
            await asyncio.sleep(3)   # retry after 3 s


def _ws_thread_target(board_ip: str, stop_event: threading.Event) -> None:
    asyncio.run(_ws_receive(board_ip, stop_event))


def _start_ws(board_ip: str) -> None:
    """Spawn the WebSocket background thread."""
    # Stop any existing thread first
    _stop_ws()

    stop_ev = threading.Event()
    st.session_state["stop_ws"] = stop_ev
    t = threading.Thread(
        target=_ws_thread_target,
        args=(board_ip, stop_ev),
        daemon=True,
    )
    add_script_run_ctx(t)   # so the thread's session_state writes take effect
    t.start()
    st.session_state["ws_thread"] = t


def _stop_ws() -> None:
    """Signal the WebSocket thread to stop."""
    if "stop_ws" in st.session_state:
        st.session_state["stop_ws"].set()
    st.session_state["connected"]      = False
    st.session_state["config_fetched"] = False


# Live refresh is handled by st.fragment(run_every=...) on the status and chart
# regions (see _status_fragment / _chart_fragment). A background thread calling
# st.rerun() is unreliable (its RerunException isn't caught by the script
# runner) and a main-thread full rerun loop flickers, so both were dropped.


# ---------------------------------------------------------------------------
# ECG chart builder
# ---------------------------------------------------------------------------
def _build_chart(buffer_snapshot: list) -> go.Figure:
    times      = []
    dac        = []
    raw        = []
    filtered   = []
    rp_times   = []
    rp_vals    = []

    n = len(buffer_snapshot)
    for i, pkt in enumerate(buffer_snapshot):
        t = i / SAMPLE_RATE
        times.append(t)
        dac.append(pkt.get("ecg_dac",      0))
        raw.append(pkt.get("ecg_raw",      0))
        filtered.append(pkt.get("ecg_filtered", 0))
        if pkt.get("rpeak", False):
            rp_times.append(t)
            rp_vals.append(pkt.get("ecg_filtered", 0))

    fig = go.Figure()

    fig.add_trace(go.Scatter(
        x=times, y=dac,
        name="DAC",
        line=dict(color=COLOR_DAC, width=1),
        opacity=0.5,
        mode="lines",
    ))

    fig.add_trace(go.Scatter(
        x=times, y=raw,
        name="ADC (live, CH0)",
        line=dict(color=COLOR_RAW, width=1.5),
        opacity=0.9,
        mode="lines",
    ))

    fig.add_trace(go.Scatter(
        x=times, y=filtered,
        name="Filtered ECG",
        line=dict(color=COLOR_FILTERED, width=1.5),
        opacity=1.0,
        mode="lines",
    ))

    if rp_times:
        fig.add_trace(go.Scatter(
            x=rp_times, y=rp_vals,
            name="R-peaks",
            mode="markers",
            marker=dict(color=COLOR_RPEAK, size=8, symbol="circle"),
        ))

    fig.update_layout(
        plot_bgcolor=BG_COLOR,
        paper_bgcolor=BG_COLOR,
        font=dict(color="#CCCCCC"),
        margin=dict(l=50, r=10, t=10, b=40),
        xaxis=dict(
            title="Time (s)",
            range=[0, DISPLAY_WINDOW_SEC],
            fixedrange=True,
            color="#CCCCCC",
            gridcolor="#222222",
        ),
        yaxis=dict(
            title="ADC counts",
            range=[0, 4095],
            color="#CCCCCC",
            gridcolor="#222222",
        ),
        showlegend=False,
        height=350,
    )
    return fig


# ---------------------------------------------------------------------------
# CSV builder
# ---------------------------------------------------------------------------
def _build_csv(recording: list) -> str:
    buf = io.StringIO()
    writer = csv.DictWriter(
        buf,
        fieldnames=["timestamp_ms", "ecg_raw", "ecg_dac", "ecg_filtered", "bpm", "rpeak"],
        extrasaction="ignore",
    )
    writer.writeheader()
    for pkt in recording:
        writer.writerow({
            "timestamp_ms":  pkt.get("timestamp_ms",  0),
            "ecg_raw":       pkt.get("ecg_raw",        0),
            "ecg_dac":       pkt.get("ecg_dac",        0),
            "ecg_filtered":  pkt.get("ecg_filtered",   0),
            "bpm":           pkt.get("bpm",            0),
            "rpeak":         pkt.get("rpeak",          False),
        })
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Live regions — st.fragment(run_every=...) reruns ONLY these blocks on a timer,
# so the chart/status update smoothly without a full-page rerun (which flickers).
# The WS background thread (with ScriptRunContext) fills session_state; these
# fragments just read and render it.
# ---------------------------------------------------------------------------
@st.fragment(run_every="0.3s")
def _status_fragment() -> None:
    connected = st.session_state["connected"]
    lead_off  = st.session_state["lead_off"]
    last_bpm  = st.session_state["last_bpm"]
    prev_bpm  = st.session_state["prev_bpm"]
    board_ip  = st.session_state["board_ip"]

    if lead_off:
        st.markdown('<span style="color:#FFAA00;font-size:1.1em">⚠ Signal Lost</span>',
                    unsafe_allow_html=True)
    elif connected:
        st.markdown(f'<span style="color:#00CC44;font-size:1.1em">● Connected — {board_ip}</span>',
                    unsafe_allow_html=True)
    else:
        st.markdown('<span style="color:#CC2222;font-size:1.1em">● Disconnected</span>',
                    unsafe_allow_html=True)

    bpm_delta = last_bpm - prev_bpm
    bpm_color = "normal" if 50 <= last_bpm <= 100 else "off"
    st.metric(
        label="Heart Rate",
        value=f"{last_bpm} BPM",
        delta=f"{bpm_delta:+d}" if prev_bpm else None,
        delta_color=bpm_color,
    )


@st.fragment(run_every="0.1s")
def _chart_fragment() -> None:
    connected = st.session_state["connected"]
    with st.session_state["buffer_lock"]:
        snapshot = list(st.session_state["buffer"])
    if snapshot:
        st.plotly_chart(
            _build_chart(snapshot),
            use_container_width=True,
            config={"displayModeBar": False},
        )
    elif connected:
        st.info("Waiting for ECG data…")
    else:
        st.info("Not connected. Enter board IP and click Connect.")


# ---------------------------------------------------------------------------
# Main app
# ---------------------------------------------------------------------------
def main() -> None:
    st.set_page_config(
        page_title="PYNQ-Z2 ECG Demo",
        layout="wide",
        initial_sidebar_state="collapsed",
    )

    _init_state()

    # Flush any deferred toasts / errors from previous rerun
    if st.session_state["toast_pending"]:
        st.toast(st.session_state["toast_pending"])
        st.session_state["toast_pending"] = None

    # -----------------------------------------------------------------------
    # Header row — status/BPM live in a fragment so they update without a
    # full-page rerun.
    # -----------------------------------------------------------------------
    connected = st.session_state["connected"]

    header_left, header_right = st.columns([3, 1])
    with header_left:
        st.markdown("## PYNQ-Z2 ECG Demo")
    with header_right:
        _status_fragment()

    st.divider()

    # -----------------------------------------------------------------------
    # Two-column layout
    # -----------------------------------------------------------------------
    col_chart, col_ctrl = st.columns([3, 1])

    # ---- Left: waveform (live fragment) ------------------------------------
    with col_chart:
        _chart_fragment()

    # ---- Right: controls ---------------------------------------------------
    with col_ctrl:
        st.markdown("#### Board IP")
        ip_input = st.text_input(
            "Board IP address",
            value=st.session_state["board_ip"],
            label_visibility="collapsed",
        )
        st.session_state["board_ip"] = ip_input

        btn_col1, btn_col2 = st.columns(2)
        with btn_col1:
            if st.button("Connect", use_container_width=True):
                _start_ws(ip_input)
        with btn_col2:
            if st.button("Disconnect", use_container_width=True):
                _stop_ws()

        if connected and not st.session_state.get("config_fetched", False):
            st.spinner("Reconnecting…")

        st.divider()
        st.markdown("#### Config")

        bpm_val = st.slider(
            "Heart Rate (BPM)",
            min_value=30, max_value=240,
            value=st.session_state["slider_bpm"],
            key="slider_bpm",
        )
        rr_val = st.slider(
            "RR Variation",
            min_value=0, max_value=255,
            value=st.session_state["slider_rr"],
            key="slider_rr",
        )
        amp_val = st.slider(
            "Amplitude Variation",
            min_value=0, max_value=255,
            value=st.session_state["slider_amp"],
            key="slider_amp",
        )
        thresh_val = st.slider(
            "Detection Threshold",
            min_value=0, max_value=4095,
            value=st.session_state["slider_thresh"],
            key="slider_thresh",
        )

        if st.button("Apply Config", use_container_width=True, type="primary"):
            payload = {
                "bpm_ch_a":         bpm_val,
                "rr_fluct":         rr_val,
                "amp_fluct":        amp_val,
                "detect_threshold": thresh_val,
            }
            ok = _post_config(st.session_state["board_ip"], payload)
            if ok:
                st.session_state["toast_pending"] = "Config applied"
                st.rerun()
            else:
                st.error("Failed to apply config — check board connection.")

        st.divider()
        st.markdown("#### Export")

        with st.session_state["buffer_lock"]:
            recording_snapshot = list(st.session_state["recording"])

        csv_data  = _build_csv(recording_snapshot)
        ts_str    = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename  = f"ecg_recording_{ts_str}.csv"

        st.download_button(
            label="Download CSV",
            data=csv_data,
            file_name=filename,
            mime="text/csv",
            use_container_width=True,
            disabled=len(recording_snapshot) == 0,
        )

        if recording_snapshot:
            st.caption(f"{len(recording_snapshot)} samples recorded")


if __name__ == "__main__":
    main()
