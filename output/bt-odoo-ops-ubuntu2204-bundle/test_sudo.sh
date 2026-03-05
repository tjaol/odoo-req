#!/bin/bash
PASSWORD='@dminFPD001'
ssh -p 14321 -i ~/.ssh/id_ed25519 -o BatchMode=yes adminfpd@203.154.2.65 "PASSWORD='$PASSWORD' bash -s" <<'REMOTE'
echo "Testing sudo..."
echo "$PASSWORD" | sudo -S -v && echo "SUDO OK" || echo "SUDO FAILED"
REMOTE
