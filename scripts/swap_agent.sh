#!/bin/bash
# Usage: ./scripts/swap_agent.sh <agent_name>
# Example: ./scripts/swap_agent.sh pynq_ecg_gen

AGENT=$1
IGNORE_FILE="scripts/ignore_for_${AGENT#pynq_}.txt"

if [ -z "$AGENT" ]; then
  echo "Usage: $0 <agent_name>"
  echo "Agents: pynq_ecg_gen, pynq_ecg_algo, pynq_ecg_process,"
  echo "        pynq_simulation, pynq_ps_server, pynq_gui, pynq_docs"
  exit 1
fi

if [ ! -f "$IGNORE_FILE" ]; then
  echo "No ignore template found for '$AGENT' (looked for $IGNORE_FILE)"
  exit 1
fi

cp "$IGNORE_FILE" .claudeignore
echo "✓ .claudeignore set for $AGENT"
echo "  Now run: claude   (or aider for Gemini agents)"
