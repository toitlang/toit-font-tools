# Copyright (C) 2022 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

cmake_minimum_required(VERSION 3.22)

project(host NONE)

# Add windows exe extension.
set(TOIT "toit${CMAKE_EXECUTABLE_SUFFIX}" CACHE FILEPATH "The 'toit' executable")

enable_testing()
add_subdirectory(bin)
add_subdirectory(tests)

