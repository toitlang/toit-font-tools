# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

message("TPKG: ${TOITPKG}")
add_custom_target(
  "install-pkgs"
  COMMAND "${TOITPKG}" install
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
)

