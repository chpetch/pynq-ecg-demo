"""
ps/server_tornado.py — PYNQ-Z2 ECG server (Tornado transport).

Same WebSocket (/ws) + REST (/status, /config) contract as server.py, but built
on Tornado (already in the PYNQ venv) because the board is offline and cannot
install FastAPI/uvicorn. The dashboard is unchanged. All hardware logic lives in
ecg_hw.py.

Run on the board (root + sourced env) — see start_server.sh:
    sudo bash -c 'source /etc/profile.d/pynq_venv.sh; source /etc/profile.d/xrt_setup.sh; \
        cd .../ps; python3 -m tornado ... '  (start_server.sh handles this)
"""

import json
import signal

import tornado.ioloop
import tornado.web
import tornado.websocket

import ecg_hw

PORT = 5000


class _CORSMixin:
    def set_default_headers(self):
        self.set_header("Access-Control-Allow-Origin", "*")
        self.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.set_header("Access-Control-Allow-Headers", "Content-Type")

    def options(self, *args):
        self.set_status(204)
        self.finish()


class WSHandler(tornado.websocket.WebSocketHandler):
    """Streams one ECG packet per tick at SAMPLE_RATE_HZ to each client."""

    clients = set()

    def check_origin(self, origin):
        return True  # non-browser clients (dashboard) send no/any Origin

    def open(self):
        WSHandler.clients.add(self)
        period_ms = 1000.0 / ecg_hw.SAMPLE_RATE_HZ
        self._last_ts = None
        self._pcb = tornado.ioloop.PeriodicCallback(self._send, period_ms)
        self._pcb.start()
        print(f"WebSocket client connected. Total: {len(WSHandler.clients)}")

    def _send(self):
        try:
            pkt = ecg_hw.get_telemetry()        # broadcaster: no AXI reads here
            if not pkt or pkt.get("timestamp_ms") == self._last_ts:
                return                          # nothing new yet — skip duplicate
            self._last_ts = pkt["timestamp_ms"]
            self.write_message(json.dumps(pkt))
        except tornado.websocket.WebSocketClosedError:
            self._pcb.stop()
        except Exception as exc:
            print(f"WS send error: {exc}")

    def on_close(self):
        try:
            self._pcb.stop()
        except Exception:
            pass
        WSHandler.clients.discard(self)
        print(f"WebSocket client disconnected. Total: {len(WSHandler.clients)}")


class StatusHandler(_CORSMixin, tornado.web.RequestHandler):
    def get(self):
        self.write(ecg_hw.get_status())


class ConfigHandler(_CORSMixin, tornado.web.RequestHandler):
    def post(self):
        try:
            data = json.loads(self.request.body or b"{}")
        except json.JSONDecodeError:
            self.set_status(400)
            self.write({"status": "error", "detail": "invalid JSON"})
            return
        written = ecg_hw.apply_config(data)
        self.write({"status": "ok", "written": written})


def make_app():
    return tornado.web.Application([
        (r"/ws", WSHandler),
        (r"/status", StatusHandler),
        (r"/config", ConfigHandler),
    ])


def main():
    ecg_hw.load_overlay()
    app = make_app()
    app.listen(PORT, address="0.0.0.0")
    print(f"Tornado ECG server listening on 0.0.0.0:{PORT} (/ws, /status, /config)")

    loop = tornado.ioloop.IOLoop.current()

    def _graceful(*_):
        print("Shutting down ...")
        ecg_hw.shutdown()
        loop.add_callback_from_signal(loop.stop)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _graceful)

    loop.start()


if __name__ == "__main__":
    main()
