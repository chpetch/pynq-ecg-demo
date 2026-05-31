# Launch the PYNQ-Z2 ECG Streamlit dashboard (PC, Windows).
#
# Uses the Anaconda Python (3.8) explicitly: the machine's default `py` is 3.9.7,
# which modern Streamlit blacklists (Requires-Python != 3.9.7), so `streamlit` /
# `py` would fail. Anaconda 3.8.8 runs Streamlit 1.40 fine.
#
# Optional auto-start on login: create a Windows Scheduled Task that runs this
# script At log on (Task Scheduler -> Create Task -> Trigger: At log on ->
# Action: powershell.exe -File <full path to this script>).

$ErrorActionPreference = "Stop"
$py = Join-Path $env:USERPROFILE "anaconda3\python.exe"
if (-not (Test-Path $py)) {
    Write-Error "Anaconda Python not found at $py — adjust the path for your install."
    exit 1
}
& $py -m streamlit run "$PSScriptRoot\dashboard.py" --server.port 8501 --server.headless false
