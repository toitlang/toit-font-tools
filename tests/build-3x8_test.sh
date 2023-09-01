#!/bin/sh

set -e

TOIT_RUN=$1
TOIT_COMPILE=$2

pwd

echo $TOIT_RUN app/convertfont.toit --doc-comments -- tests/3x8proportional.bdf "Digital Clock 3x8 proportional" build/3x8proportional.toit
$TOIT_RUN app/convertfont.toit --doc-comments -- tests/3x8proportional.bdf "Digital Clock 3x8 proportional" build/3x8proportional.toit

echo $TOIT_COMPILE -Werror --analyze build/3x8proportional.toit
$TOIT_COMPILE -Werror --analyze build/3x8proportional.toit

echo cmp build/3x8proportional.toit tests/gold/3x8proportional.toit
cmp build/3x8proportional.toit tests/gold/3x8proportional.toit
