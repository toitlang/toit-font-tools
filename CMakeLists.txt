# Copyright (C) 2022 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

cmake_minimum_required(VERSION 3.22)

project(host NONE)

# Add windows exe extension.
set(TOITRUN "toit.run${CMAKE_EXECUTABLE_SUFFIX}" CACHE FILEPATH "The executable used to run the tests")
set(TOITPKG "toit.pkg${CMAKE_EXECUTABLE_SUFFIX}" CACHE FILEPATH "The executable used to install the packages")
set(TOITC "toit.compile${CMAKE_EXECUTABLE_SUFFIX}" CACHE FILEPATH "The executable used to check the syntax")

enable_testing()
add_subdirectory(bin)
add_subdirectory(tests)

