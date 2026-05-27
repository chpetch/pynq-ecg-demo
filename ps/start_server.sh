#!/bin/bash
cd /home/xilinx/pynq-ecg-demo/ps
uvicorn server:app --host 0.0.0.0 --port 5000 --workers 1
