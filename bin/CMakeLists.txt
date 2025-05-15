# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

add_custom_target(
  "install-pkgs"
  COMMAND "${TOIT}" pkg install
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
)

