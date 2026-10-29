#!/bin/sh
# Called by the "lab hold" Byteman rules inside an SCM thread.
# Blocks while /tmp/lab-fault/<flag> exists (default flag "hold"; max 6 hours), so the
# thread is stuck until ./scenario.sh fault-off removes the file.
f=/tmp/lab-fault/${1:-hold}
i=0
while [ -f "$f" ] && [ $i -lt 43200 ]; do sleep 0.5; i=$((i + 1)); done
