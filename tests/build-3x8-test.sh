#!/bin/sh
# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/TESTS_LICENSE file.

set -e

TOIT=$1

pwd

echo $TOIT run bin/convertfont.toit -- --doc-comments -- tests/3x8proportional.bdf "Digital Clock 3x8 proportional" build/3x8proportional.toit
$TOIT run bin/convertfont.toit -- --doc-comments -- build/toit-font-clock/bdf/3x8proportional.bdf "Digital Clock 3x8 proportional" build/3x8proportional.toit

echo $TOIT analyze -Werror build/3x8proportional.toit
$TOIT analyze -Werror build/3x8proportional.toit

echo cmp build/3x8proportional.toit tests/gold/3x8proportional.toit
cmp build/3x8proportional.toit tests/gold/3x8proportional.toit
