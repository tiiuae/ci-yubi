#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
printf '%s\n' "[WARN] uefisign-simple is deprecated; use uefisignraw instead" >&2
exec uefisignraw "$@"
