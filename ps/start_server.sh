#!/bin/bash
# Launch the PYNQ-Z2 ECG PS server.
# Overlay load needs root AND the sourced PYNQ/XRT env (else "No Devices Found").
# The board is offline (no FastAPI/uvicorn) — run the Tornado server, which only
# needs packages already in the PYNQ venv. Same /ws + /status + /config contract.
DEST=/home/xilinx/jupyter_notebooks/pynq-ecg-demo/ps
sudo bash -c "source /etc/profile.d/pynq_venv.sh; source /etc/profile.d/xrt_setup.sh; \
  cd $DEST; exec python3 -u server_tornado.py"
