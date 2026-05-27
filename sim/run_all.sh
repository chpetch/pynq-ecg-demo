#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
PASS=0; FAIL=0
for dir in test_*/; do
    echo "=== Running $dir ==="
    cd "$dir"
    if make SIM=icarus 2>&1 | tee run.log | grep -q "FAILED"; then
        echo "FAIL: $dir"; FAIL=$((FAIL+1))
    else
        echo "PASS: $dir"; PASS=$((PASS+1))
    fi
    cd ..
done
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
