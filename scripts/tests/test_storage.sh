#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: Storage Monitor Unit & Deterministic Fixture Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${TESTS_DIR}/fixtures"
MONITOR_DIR="${TESTS_DIR}/../monitoring"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"

describe "Storage Monitor: Filesystem, Inodes & Diskstats Verification"

export PROC_ROOT="${FIXTURES_DIR}/proc"
export SYS_ROOT="${FIXTURES_DIR}/sys"

it "excludes virtual loop devices from diskstats by default"
out="$(bash "${MONITOR_DIR}/storage_monitor.sh" -i 0 --json)"
assert_contains '"device": "nvme0n1"' "$out" "nvme0n1 included"

it "verifies loop devices are not included in diskstats"
assert_contains false "$(echo "$out" | grep -q '"device": "loop0"' && echo true || echo false)" "loop0 excluded from disk_io"

it "reads mount options from fixture /proc/mounts (rw,relatime)"
assert_contains "rw,relatime" "$out" "Mount options read from /proc/mounts"

it "supports targeted mount inspection (--mount /)"
out_root="$(bash "${MONITOR_DIR}/storage_monitor.sh" -i 0 --mount / --json)"
assert_contains '"mount_point": "/"' "$out_root" "Root mount inspected"

it "exits with code 0 when filesystem usage is below threshold"
code=0
bash "${MONITOR_DIR}/storage_monitor.sh" -i 0 --mount / --warn-disk 95 --crit-disk 99 >/dev/null 2>&1 || code=$?
assert_exit_code 0 "$code" "Should exit 0 when below thresholds"

it "exits with code 3 [WARN] when disk warning threshold is breached (e.g. >= 10%)"
code=0
bash "${MONITOR_DIR}/storage_monitor.sh" -i 0 --mount / --warn-disk 10 --crit-disk 99 >/dev/null 2>&1 || code=$?
assert_exit_code 3 "$code" "Should exit 3 on disk warn"

it "exits with code 4 [CRIT] when disk critical threshold is breached (e.g. >= 10%)"
code=0
bash "${MONITOR_DIR}/storage_monitor.sh" -i 0 --mount / --warn-disk 5 --crit-disk 10 >/dev/null 2>&1 || code=$?
assert_exit_code 4 "$code" "Should exit 4 on disk crit"

it "fails with exit code 1 when target mount does not exist"
code=0
bash "${MONITOR_DIR}/storage_monitor.sh" -i 0 --mount /nonexistent_mount_xyz >/dev/null 2>&1 || code=$?
assert_exit_code 1 "$code" "Should exit 1 on nonexistent mount"
