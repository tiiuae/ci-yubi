# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors            # SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_TEST_CA="$SCRIPT_DIR/create-test-ca.sh"

"$CREATE_TEST_CA" --create-root

for env in dev prod dbg release; do
  "$CREATE_TEST_CA" --env "$env"
done
