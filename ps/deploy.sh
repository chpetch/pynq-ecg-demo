#!/bin/bash
BOARD_IP=${1:-192.168.2.99}
BOARD_USER=xilinx
DEST=/home/xilinx/pynq-ecg-demo

echo "Deploying to $BOARD_USER@$BOARD_IP:$DEST"
scp -r ../ps "$BOARD_USER@$BOARD_IP:$DEST/"
echo "Done. Run: ssh $BOARD_USER@$BOARD_IP '$DEST/ps/start_server.sh'"
