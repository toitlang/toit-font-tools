#!/bin/sh
# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/TESTS_LICENSE file.

set -e

TOIT_RUN=$1
TOIT_COMPILE=$2

pwd

echo $TOIT_RUN bin/convertfont.toit --doc-comments -- tests/3x8proportional.bdf "Digital Clock 3x8 proportional" build/3x8proportional.toit
$TOIT_RUN bin/convertfont.toit --doc-comments -- build/toit-font-clock/bdf/3x8proportional.bdf "Digital Clock 3x8 proportional" build/3x8proportional.toit

echo $TOIT_COMPILE -Werror --analyze build/3x8proportional.toit
$TOIT_COMPILE -Werror --analyze build/3x8proportional.toit

echo cmp build/3x8proportional.toit tests/gold/3x8proportional.toit
cmp build/3x8proportional.toit tests/gold/3x8proportional.toit
