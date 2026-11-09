#!/usr/bin/env bash

CAND=$(gh run list -e push -w sanity --json headBranch   -q '.[] | select(.headBranch | contains("candidate")) | .headBranch' | head -1)

if [ -n "$CAND" ]; then
  while true; do
    gh run list -b $CAND
    sleep 60
  done
fi
