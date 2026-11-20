#!/usr/bin/env bash
# Copyright 2026 Duatic AG
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that
# the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions, and
#    the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and
#    the following disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or
#    promote products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

set -euo pipefail

# Resolve rosdep dependencies for a workspace, degrading gracefully.
#
# Installs every dependency rosdep *can* resolve, records what is still missing afterwards to
# /etc/duatic/unresolved-rosdep.txt (the keys with no rosdep rule for this distro, and as
# "<installer>: <package>" each resolved dependency that failed to install), and prints
# a prominent warning. Completeness is auto-detected: an EMPTY manifest == complete.
#
#   rosdep_install.sh <src_path> <ros_distro> [--strict]
#
#   --strict   exit non-zero if anything is unresolved or an install fails. Used by
#              robot/runtime builds — the quality gate. Robots never ship incomplete.
#   (lenient)  always exit 0. Used by dev images: developers must never be blocked.

SRC="${1:-src}"
ROS_DISTRO_ARG="${2:-${ROS_DISTRO:-}}"
STRICT=0
[[ "${3:-}" == "--strict" ]] && STRICT=1

if [[ -z "$ROS_DISTRO_ARG" ]]; then
    echo "rosdep_install: ROS distro not given (arg 2 or \$ROS_DISTRO)" >&2
    exit 2
fi

MANIFEST=/etc/duatic/unresolved-rosdep.txt
mkdir -p "$(dirname "$MANIFEST")"
: > "$MANIFEST"

rosdep update

# Install everything resolvable. -r continues past unresolvable keys and failed installs.
set +e
rosdep install -r --from-paths "$SRC" --ignore-src --rosdistro "$ROS_DISTRO_ARG" -y
rc=$?
set -e

# What rosdep check still finds missing: keys with no rosdep rule for this distro, and the
# "<installer>\t<package>" lines of resolved dependencies that are not installed.
mapfile -t unresolved < <(
    rosdep check --from-paths "$SRC" --ignore-src --rosdistro "$ROS_DISTRO_ARG" 2>&1 |
        sed -nE -e 's/.*Cannot locate rosdep definition for \[([^]]+)\].*/\1/p' \
            -e 's/^([a-z]+)\t(.+)/\1: \2/p' | sort -u
)

if [[ ${#unresolved[@]} -gt 0 ]]; then
    printf '%s\n' "${unresolved[@]}" > "$MANIFEST"
    echo ""
    echo "=================================================================="
    echo "WARNING: unresolved rosdep dependencies for '${ROS_DISTRO_ARG}':"
    printf '  - %s\n' "${unresolved[@]}"
    echo "recorded in ${MANIFEST}"
    echo "=================================================================="
    echo ""
fi

if [[ "$STRICT" == "1" ]]; then
    if [[ ${#unresolved[@]} -gt 0 || $rc -ne 0 ]]; then
        echo "rosdep_install: strict mode — dependencies incomplete (rc=${rc}, unresolved=${#unresolved[@]})." >&2
        exit 1
    fi
fi

exit 0
