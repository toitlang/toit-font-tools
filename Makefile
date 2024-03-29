# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

all: test

.PHONY: build/host/CMakeCache.txt
build/CMakeCache.txt:
	$(MAKE) rebuild-cmake

install-pkgs: rebuild-cmake
	(cd build && ninja install-pkgs)

test: get-bdf install-pkgs rebuild-cmake
	(cd build && ninja check)

# We rebuild the cmake file all the time.
# We use "glob" in the cmakefile, and wouldn't otherwise notice if a new
# file (for example a test) was added or removed.
# It takes <1s on Linux to run cmake, so it doesn't hurt to run it frequently.
rebuild-cmake:
	mkdir -p build
	(cd build && cmake .. -G Ninja)

get-bdf:
	mkdir -p build/
	(git -C build/toit-font-clock pull || git -C build clone https://github.com/toitware/toit-font-clock.git)

.PHONY: all test rebuild-cmake install-pkgs get-bdf

