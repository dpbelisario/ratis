#!/bin/sh
# Called by the "lab hold" Byteman rules inside an SCM RPC handler thread.
# Blocks while /tmp/lab-fault/hold exists (max 6 hours), so the handler is stuck
# until ./scenario.sh fault-off removes the file.
i=0
while [ -f /tmp/lab-fault/hold ] && [ $i -lt 43200 ]; do sleep 0.5; i=$((i + 1)); done
