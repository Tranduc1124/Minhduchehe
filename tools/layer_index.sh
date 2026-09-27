#!/bin/bash
# Print kShapeKeys with its explicit index so the census indices in
# [SB-LAYER] can be checked against the source instead of memory.
cd /home/tduck/Projects/FilzaJailedDS/FilzaJailedDS
sed -n '/kShapeKeys\[16\]/,/};/p' remote/SpringBoardOverlay.m \
  | grep -o '"[a-zA-Z]*"' | tr -d '"' | nl -v0 -ba -w2 -s'  '
