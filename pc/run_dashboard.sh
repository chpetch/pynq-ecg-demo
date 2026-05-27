#!/bin/bash
# Launch the PYNQ-Z2 ECG Streamlit dashboard.
# Run from the pc/ directory or provide the full path to dashboard.py.
streamlit run dashboard.py --server.port 8501 --server.headless false
