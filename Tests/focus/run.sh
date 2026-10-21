#!/bin/bash
# No focus rings: the UI kit must strip every outline (beats plugin CSS) and native views must not draw rings.
set -e
cd "$(dirname "$0")/../.."
grep -q '\*:focus-visible { outline: none !important; }' NookUI/nook-ui.css || { echo "FAIL: nook-ui.css lost the no-ring rule"; exit 1; }
! grep -rnE 'strokeBorder\(Color\.(orange|accentColor|blue)[^)]*focused' Nook || { echo "FAIL: a native focus ring is back"; exit 1; }
grep -q 'focusEffectDisabled()' Nook/Views/NotchRootView.swift || { echo "FAIL: notch root must disable system focus rings"; exit 1; }
echo "PASS: no focus rings"
