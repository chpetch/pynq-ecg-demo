# PYNQ-Z2 ECG Demo

## For Claude Code
You are the orchestrator for this project.
Read `agents/pynq_orchestrator.md` completely before doing anything else.
Do not write any code or create any files until you have read it.

## Current Milestone
<!-- UPDATE THIS MANUALLY AFTER EACH MILESTONE IS APPROVED -->
CURRENT: 3 — Signal Processing complete

## Active Agent Session
<!-- UPDATE THIS WHEN SWITCHING AGENTS -->
AGENT: pynq_orchestrator

## Project Folder Layout
```
agents/     ← all agent system prompts (read-only after creation)
handoffs/   ← shared contracts between agents (register map, schemas, specs)
algo/       ← algorithm validation scripts and plots
pl/         ← Verilog RTL source files
sim/        ← cocotb testbenches and results
ps/         ← Python PS server and Jupyter notebooks
pc/         ← Streamlit dashboard
docs/       ← generated documentation
```

## Switching Models Mid-Project
- Claude agents  : run `claude` in this folder
- Gemini agents  : run `antigravity` in this folder
- See SETUP.md for install instructions

## Context Saving Tips
- Run `/compact` when context feels heavy
- Update CURRENT milestone number above before closing a session
- Each agent only needs its own subfolder + handoffs/ — use .claudeignore
