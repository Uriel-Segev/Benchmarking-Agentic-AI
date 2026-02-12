#!/usr/bin/env bash
# =============================================================================
# Run a terminal-bench task in Cloud Hypervisor and capture results
#
# This script:
#   1. Boots a Cloud Hypervisor VM with the prepared task rootfs
#   2. Waits for the task to complete (VM auto-shuts down via ACPI poweroff)
#   3. Mounts the rootfs and extracts results
#   4. Reports pass/fail status
#
# Usage:
#   sudo ./run_task.sh [rootfs_path]
#
# Example:
#   sudo ./run_task.sh /opt/cloud-hypervisor/rootfs-task.ext4
# =============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------

WORKDIR="${WORKDIR:-/opt/cloud-hypervisor}"
TASK_ROOTFS="${1:-${WORKDIR}/rootfs-task.ext4}"
KERNEL="${KERNEL:-${WORKDIR}/vmlinuz}"
INITRAMFS="${INITRAMFS:-${WORKDIR}/initrd.img}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/ch-rootfs}"

# VM configuration
VCPU_COUNT="${VCPU_COUNT:-2}"
MEM_SIZE_MIB="${MEM_SIZE_MIB:-1024}"

# Timeout for task completion (seconds)
TASK_TIMEOUT="${TASK_TIMEOUT:-300}"

# Network config (from install_cloud_hypervisor.sh defaults)
TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-192.168.100.1}"
FC_IP="${FC_IP:-192.168.100.2}"
NETMASK="${NETMASK:-255.255.255.252}"

# Parallel execution support
SKIP_ARP_CHECK="${SKIP_ARP_CHECK:-0}"
INSTANCE_ID="${INSTANCE_ID:-0}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[run-task] $*\n"; }
die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

cleanup() {
  # Kill cloud-hypervisor if running
  if [[ -n "${CH_PID:-}" ]] && kill -0 "${CH_PID}" 2>/dev/null; then
    kill "${CH_PID}" 2>/dev/null || true
    wait "${CH_PID}" 2>/dev/null || true
  fi

  # Unmount if mounted
  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    umount "${MOUNT_POINT}" 2>/dev/null || true
  fi
}

# ---------------------------
# Validation
# ---------------------------

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root: sudo $0 $*"
fi

[[ -f "${TASK_ROOTFS}" ]] || die "Task rootfs not found: ${TASK_ROOTFS}"
[[ -f "${KERNEL}" ]] || die "Kernel not found: ${KERNEL}"
command -v cloud-hypervisor >/dev/null || die "cloud-hypervisor not found in PATH"

# ---------------------------
# Setup
# ---------------------------

trap cleanup EXIT

log "Running task in Cloud Hypervisor (instance ${INSTANCE_ID})"
echo "  Rootfs: ${TASK_ROOTFS}"
echo "  Kernel: ${KERNEL}"
echo "  Timeout: ${TASK_TIMEOUT}s"

# Reset the TASK_COMPLETE marker in rootfs before running
log "Preparing rootfs for fresh run"
mkdir -p "${MOUNT_POINT}"
mount -o loop "${TASK_ROOTFS}" "${MOUNT_POINT}"
rm -f "${MOUNT_POINT}/app/TASK_COMPLETE"
rm -f "${MOUNT_POINT}/app/results.json"
rm -f "${MOUNT_POINT}/app/run.log"
rm -f "${MOUNT_POINT}/app/timing.json"
rm -f "${MOUNT_POINT}/app/timing_combined.json"
sync
umount "${MOUNT_POINT}"

# ---------------------------
# CloudLab safety checks before launching VM
# ---------------------------

log "Running CloudLab safety checks"

# Detect DEFAULT_IFACE if not set
if [[ -z "${DEFAULT_IFACE:-}" ]]; then
  DEFAULT_IFACE="$(ip route list default | awk '{print $5; exit}' || true)"
fi
[[ -n "${DEFAULT_IFACE}" ]] || die "REFUSING TO RUN (CLOUDLAB SAFETY): Could not detect DEFAULT_IFACE"

# Verify TAP_DEV exists
ip link show "${TAP_DEV}" &>/dev/null || die "REFUSING TO RUN (CLOUDLAB SAFETY): TAP_DEV ${TAP_DEV} does not exist. Run install_cloud_hypervisor.sh first."

# Verify TAP_IP is ONLY on TAP_DEV
_tap_ip_dev="$(ip -o addr show | awk -v ip="${TAP_IP}" '$0 ~ ip {print $2; exit}')"
if [[ "${_tap_ip_dev}" != "${TAP_DEV}" ]]; then
  die "REFUSING TO RUN (CLOUDLAB SAFETY): TAP_IP ${TAP_IP} appears on ${_tap_ip_dev} (expected ${TAP_DEV})"
fi
echo "  TAP_IP scope check passed (only on ${TAP_DEV})"

# ARP safety check on DEFAULT_IFACE (skippable for parallel runs where wrapper already checked)
if [[ "${SKIP_ARP_CHECK}" != "1" ]]; then
  echo "  ARP safety check (10s) - checking for dangerous ARP on ${DEFAULT_IFACE}..."
  if timeout 10 tcpdump -n -c 1 -i "${DEFAULT_IFACE}" "arp and host ${TAP_IP}" 2>/dev/null; then
    die "REFUSING TO RUN (CLOUDLAB SAFETY): Saw ARP involving TAP_IP (${TAP_IP}) on ${DEFAULT_IFACE}. This is dangerous on CloudLab!"
  fi
  echo "  ARP check passed (no TAP_IP ARP seen on ${DEFAULT_IFACE})"
else
  echo "  ARP safety check skipped (SKIP_ARP_CHECK=1)"
fi

# ---------------------------
# Build Cloud Hypervisor command line
# ---------------------------

# MAC address: use instance ID for uniqueness in parallel runs
MAC="AA:C0:00:00:00:$(printf '%02X' $((INSTANCE_ID + 1)))"

# Kernel command line
CMDLINE="console=ttyS0 root=/dev/vda rw ip=${FC_IP}::${TAP_IP}:${NETMASK}::eth0:off"

# Build the initramfs flag (optional — only if file exists)
INITRAMFS_FLAG=""
if [[ -f "${INITRAMFS}" ]]; then
  INITRAMFS_FLAG="--initramfs ${INITRAMFS}"
fi

# ---------------------------
# Launch Cloud Hypervisor
# ---------------------------

log "Starting Cloud Hypervisor VM"

# Run cloud-hypervisor in background, capturing output
CH_LOG=$(mktemp)
HOST_LAUNCH_EPOCH=$(date +%s.%N 2>/dev/null || date +%s)

cloud-hypervisor \
  --kernel "${KERNEL}" \
  ${INITRAMFS_FLAG} \
  --disk path="${TASK_ROOTFS}" \
  --cpus boot="${VCPU_COUNT}" \
  --memory size="${MEM_SIZE_MIB}M" \
  --net "tap=${TAP_DEV},mac=${MAC}" \
  --serial tty \
  --console off \
  --cmdline "${CMDLINE}" \
  > "${CH_LOG}" 2>&1 &
CH_PID=$!

echo "  Cloud Hypervisor PID: ${CH_PID}"
echo "  Console output: ${CH_LOG}"

# ---------------------------
# Wait for completion
# ---------------------------

log "Waiting for task completion (timeout: ${TASK_TIMEOUT}s)"

START_TIME=$(date +%s)
COMPLETED=false

while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  # Check if VM process is still running
  if ! kill -0 "${CH_PID}" 2>/dev/null; then
    HOST_VM_EXIT_EPOCH=$(date +%s.%N 2>/dev/null || date +%s)
    echo "  VM has shut down after ${ELAPSED}s"
    COMPLETED=true
    break
  fi

  # Check timeout
  if [[ ${ELAPSED} -ge ${TASK_TIMEOUT} ]]; then
    HOST_VM_EXIT_EPOCH=$(date +%s.%N 2>/dev/null || date +%s)
    echo "  Timeout reached (${TASK_TIMEOUT}s)"
    echo "  Killing VM..."
    kill "${CH_PID}" 2>/dev/null || true
    break
  fi

  # Progress indicator
  printf "\r  Elapsed: %ds / %ds" "${ELAPSED}" "${TASK_TIMEOUT}"
  sleep 1
done

echo ""

# Wait for process to fully exit
wait "${CH_PID}" 2>/dev/null || true
CH_PID=""

# ---------------------------
# Extract results
# ---------------------------

log "Extracting results from rootfs"

# Mount read-write first (ext4 may refuse ro mount if dirty after VM kill)
# Then we'll sync and it will be fine
mount -o loop "${TASK_ROOTFS}" "${MOUNT_POINT}" || {
  # If mount fails, try fsck first
  log "Mount failed, attempting fsck..."
  e2fsck -y "${TASK_ROOTFS}" || true
  mount -o loop "${TASK_ROOTFS}" "${MOUNT_POINT}"
}

# Check for completion marker
if [[ -f "${MOUNT_POINT}/app/TASK_COMPLETE" ]]; then
  echo "  Task completed successfully"
else
  echo "  WARNING: Task may not have completed (no TASK_COMPLETE marker)"
fi

# Read results
RESULTS_FILE="${MOUNT_POINT}/app/results.json"
LOG_FILE="${MOUNT_POINT}/app/run.log"

if [[ -f "${RESULTS_FILE}" ]]; then
  echo ""
  echo "========================================"
  echo "RESULTS"
  echo "========================================"
  cat "${RESULTS_FILE}"
  echo ""

  # Parse results
  STATUS=$(grep -oP '"status":\s*"\K[^"]+' "${RESULTS_FILE}" || echo "unknown")
  PASSED=$(grep -oP '"tests_passed":\s*\K\d+' "${RESULTS_FILE}" || echo "0")
  FAILED=$(grep -oP '"tests_failed":\s*\K\d+' "${RESULTS_FILE}" || echo "0")
else
  echo "  WARNING: No results.json found"
  STATUS="error"
  PASSED=0
  FAILED=0
fi

# ---------------------------
# Extract timing data
# ---------------------------

TIMING_FILE="${MOUNT_POINT}/app/timing.json"
if [[ -f "${TIMING_FILE}" ]]; then
  # Read guest-side timestamps
  GUEST_BOOT_DONE=$(grep -oP '"guest_boot_done_epoch":\s*\K[0-9.]+' "${TIMING_FILE}" || echo "0")
  GUEST_SOLUTION_START=$(grep -oP '"guest_solution_start_epoch":\s*\K[0-9.]+' "${TIMING_FILE}" || echo "0")
  GUEST_SOLUTION_END=$(grep -oP '"guest_solution_end_epoch":\s*\K[0-9.]+' "${TIMING_FILE}" || echo "0")
  GUEST_TESTS_START=$(grep -oP '"guest_tests_start_epoch":\s*\K[0-9.]+' "${TIMING_FILE}" || echo "0")
  GUEST_TESTS_END=$(grep -oP '"guest_tests_end_epoch":\s*\K[0-9.]+' "${TIMING_FILE}" || echo "0")
  GUEST_SHUTDOWN_START=$(grep -oP '"guest_shutdown_start_epoch":\s*\K[0-9.]+' "${TIMING_FILE}" || echo "0")

  # Compute derived metrics using awk (bash can't do float math)
  BOOT_TIME=$(awk "BEGIN {printf \"%.3f\", ${GUEST_BOOT_DONE} - ${HOST_LAUNCH_EPOCH}}")
  SOLUTION_TIME=$(awk "BEGIN {printf \"%.3f\", ${GUEST_SOLUTION_END} - ${GUEST_SOLUTION_START}}")
  TEST_TIME=$(awk "BEGIN {printf \"%.3f\", ${GUEST_TESTS_END} - ${GUEST_TESTS_START}}")
  TASK_TOTAL_TIME=$(awk "BEGIN {printf \"%.3f\", ${GUEST_SHUTDOWN_START} - ${GUEST_BOOT_DONE}}")
  SHUTDOWN_TIME=$(awk "BEGIN {printf \"%.3f\", ${HOST_VM_EXIT_EPOCH} - ${GUEST_SHUTDOWN_START}}")
  TOTAL_LIFECYCLE=$(awk "BEGIN {printf \"%.3f\", ${HOST_VM_EXIT_EPOCH} - ${HOST_LAUNCH_EPOCH}}")
else
  echo "  WARNING: No timing.json found"
  BOOT_TIME="N/A"
  SOLUTION_TIME="N/A"
  TEST_TIME="N/A"
  TASK_TOTAL_TIME="N/A"
  SHUTDOWN_TIME="N/A"
  TOTAL_LIFECYCLE=$(awk "BEGIN {printf \"%.3f\", ${HOST_VM_EXIT_EPOCH} - ${HOST_LAUNCH_EPOCH}}")
fi

# Write combined timing into rootfs for run_parallel.sh to extract
cat > "${MOUNT_POINT}/app/timing_combined.json" <<EOF
{
  "host_launch_epoch": ${HOST_LAUNCH_EPOCH},
  "host_vm_exit_epoch": ${HOST_VM_EXIT_EPOCH},
  "guest_boot_done_epoch": ${GUEST_BOOT_DONE:-0},
  "guest_solution_start_epoch": ${GUEST_SOLUTION_START:-0},
  "guest_solution_end_epoch": ${GUEST_SOLUTION_END:-0},
  "guest_tests_start_epoch": ${GUEST_TESTS_START:-0},
  "guest_tests_end_epoch": ${GUEST_TESTS_END:-0},
  "guest_shutdown_start_epoch": ${GUEST_SHUTDOWN_START:-0},
  "boot_time_s": ${BOOT_TIME},
  "solution_time_s": ${SOLUTION_TIME},
  "test_time_s": ${TEST_TIME},
  "task_total_time_s": ${TASK_TOTAL_TIME},
  "shutdown_time_s": ${SHUTDOWN_TIME},
  "total_vm_lifecycle_s": ${TOTAL_LIFECYCLE}
}
EOF
sync

# Show log excerpt
if [[ -f "${LOG_FILE}" ]]; then
  echo ""
  echo "========================================"
  echo "RUN LOG (last 50 lines)"
  echo "========================================"
  tail -50 "${LOG_FILE}"
fi

# Show console output
if [[ -f "${CH_LOG}" ]]; then
  echo ""
  echo "========================================"
  echo "CONSOLE OUTPUT (last 30 lines)"
  echo "========================================"
  tail -30 "${CH_LOG}"
fi

# Unmount
umount "${MOUNT_POINT}"

# Clean up cloud-hypervisor log
rm -f "${CH_LOG}"

# ---------------------------
# Final report
# ---------------------------

echo ""
echo "========================================"
echo "SUMMARY"
echo "========================================"
echo "  Status:       ${STATUS}"
echo "  Tests Passed: ${PASSED}"
echo "  Tests Failed: ${FAILED}"
echo "========================================"
echo ""
echo "========================================"
echo "TIMING BREAKDOWN"
echo "========================================"
echo "  Boot time:      ${BOOT_TIME}s  (host launch -> guest autorun start)"
echo "  Solution time:  ${SOLUTION_TIME}s  (solution.sh execution)"
echo "  Test time:      ${TEST_TIME}s  (pytest execution)"
echo "  Task total:     ${TASK_TOTAL_TIME}s  (boot-done -> pre-shutdown)"
echo "  Shutdown time:  ${SHUTDOWN_TIME}s  (poweroff -> process exit)"
echo "  ────────────────────────"
echo "  Total lifecycle: ${TOTAL_LIFECYCLE}s (host launch -> process exit)"
echo "========================================"

# Exit with appropriate code
if [[ "${STATUS}" == "passed" ]]; then
  echo ""
  echo "Task PASSED"
  exit 0
else
  echo ""
  echo "Task FAILED"
  exit 1
fi
