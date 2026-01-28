#!/usr/bin/env bash
# =============================================================================
# Run a terminal-bench task in Firecracker and capture results
#
# This script:
#   1. Boots a Firecracker VM with the prepared task rootfs
#   2. Waits for the task to complete (VM auto-shuts down)
#   3. Mounts the rootfs and extracts results
#   4. Reports pass/fail status
#
# Usage:
#   sudo ./run_task.sh [rootfs_path]
#
# Example:
#   sudo ./run_task.sh /opt/firecracker/rootfs-task.ext4
# =============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------

WORKDIR="${WORKDIR:-/opt/firecracker}"
TASK_ROOTFS="${1:-${WORKDIR}/rootfs-task.ext4}"
KERNEL="${KERNEL:-${WORKDIR}/vmlinux.bin}"
SOCKET_PATH="${SOCKET_PATH:-/tmp/firecracker-task.socket}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/fc-rootfs}"

# VM configuration
VCPU_COUNT="${VCPU_COUNT:-2}"
MEM_SIZE_MIB="${MEM_SIZE_MIB:-1024}"

# Timeout for task completion (seconds)
TASK_TIMEOUT="${TASK_TIMEOUT:-300}"

# Network config (from install_firecracker.sh defaults)
TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-192.168.100.1}"
FC_IP="${FC_IP:-192.168.100.2}"
NETMASK="${NETMASK:-255.255.255.252}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[run-task] $*\n"; }
die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

cleanup() {
  # Kill firecracker if running
  if [[ -n "${FC_PID:-}" ]] && kill -0 "${FC_PID}" 2>/dev/null; then
    kill "${FC_PID}" 2>/dev/null || true
    wait "${FC_PID}" 2>/dev/null || true
  fi

  # Clean up socket
  rm -f "${SOCKET_PATH}"

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
command -v firecracker >/dev/null || die "firecracker not found in PATH"

# ---------------------------
# Setup
# ---------------------------

trap cleanup EXIT

log "Running task in Firecracker"
echo "  Rootfs: ${TASK_ROOTFS}"
echo "  Kernel: ${KERNEL}"
echo "  Timeout: ${TASK_TIMEOUT}s"

# Clean up any existing socket
rm -f "${SOCKET_PATH}"

# Reset the TASK_COMPLETE marker in rootfs before running
log "Preparing rootfs for fresh run"
mkdir -p "${MOUNT_POINT}"
mount -o loop "${TASK_ROOTFS}" "${MOUNT_POINT}"
rm -f "${MOUNT_POINT}/app/TASK_COMPLETE"
rm -f "${MOUNT_POINT}/app/results.json"
rm -f "${MOUNT_POINT}/app/run.log"
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
ip link show "${TAP_DEV}" &>/dev/null || die "REFUSING TO RUN (CLOUDLAB SAFETY): TAP_DEV ${TAP_DEV} does not exist. Run setup_network.sh first."

# Verify TAP_IP is ONLY on TAP_DEV
_tap_ip_dev="$(ip -o addr show | awk -v ip="${TAP_IP}" '$0 ~ ip {print $2; exit}')"
if [[ "${_tap_ip_dev}" != "${TAP_DEV}" ]]; then
  die "REFUSING TO RUN (CLOUDLAB SAFETY): TAP_IP ${TAP_IP} appears on ${_tap_ip_dev} (expected ${TAP_DEV})"
fi
echo "  TAP_IP scope check passed (only on ${TAP_DEV})"

# ARP safety check on DEFAULT_IFACE
echo "  ARP safety check (10s) - checking for dangerous ARP on ${DEFAULT_IFACE}..."
if timeout 10 tcpdump -n -c 1 -i "${DEFAULT_IFACE}" "arp and host ${TAP_IP}" 2>/dev/null; then
  die "REFUSING TO RUN (CLOUDLAB SAFETY): Saw ARP involving TAP_IP (${TAP_IP}) on ${DEFAULT_IFACE}. This is dangerous on CloudLab!"
fi
echo "  ARP check passed (no TAP_IP ARP seen on ${DEFAULT_IFACE})"

# ---------------------------
# Create VM config
# ---------------------------

VM_CONFIG=$(mktemp)
cat > "${VM_CONFIG}" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${KERNEL}",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=${FC_IP}::${TAP_IP}:${NETMASK}::eth0:off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${TASK_ROOTFS}",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "AA:FC:00:00:00:01",
      "host_dev_name": "${TAP_DEV}"
    }
  ],
  "machine-config": {
    "vcpu_count": ${VCPU_COUNT},
    "mem_size_mib": ${MEM_SIZE_MIB}
  }
}
EOF

# ---------------------------
# Launch Firecracker
# ---------------------------

log "Starting Firecracker VM"

# Run firecracker in background, capturing output
FC_LOG=$(mktemp)
firecracker --api-sock "${SOCKET_PATH}" --config-file "${VM_CONFIG}" > "${FC_LOG}" 2>&1 &
FC_PID=$!

echo "  Firecracker PID: ${FC_PID}"
echo "  Console output: ${FC_LOG}"

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
  if ! kill -0 "${FC_PID}" 2>/dev/null; then
    echo "  VM has shut down after ${ELAPSED}s"
    COMPLETED=true
    break
  fi

  # Check timeout
  if [[ ${ELAPSED} -ge ${TASK_TIMEOUT} ]]; then
    echo "  Timeout reached (${TASK_TIMEOUT}s)"
    echo "  Killing VM..."
    kill "${FC_PID}" 2>/dev/null || true
    break
  fi

  # Progress indicator
  printf "\r  Elapsed: %ds / %ds" "${ELAPSED}" "${TASK_TIMEOUT}"
  sleep 1
done

echo ""

# Wait for process to fully exit
wait "${FC_PID}" 2>/dev/null || true
FC_PID=""

# Clean up temp config
rm -f "${VM_CONFIG}"

# ---------------------------
# Extract results
# ---------------------------

log "Extracting results from rootfs"

mount -o loop,ro "${TASK_ROOTFS}" "${MOUNT_POINT}"

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

# Show log excerpt
if [[ -f "${LOG_FILE}" ]]; then
  echo ""
  echo "========================================"
  echo "RUN LOG (last 50 lines)"
  echo "========================================"
  tail -50 "${LOG_FILE}"
fi

# Show console output
if [[ -f "${FC_LOG}" ]]; then
  echo ""
  echo "========================================"
  echo "CONSOLE OUTPUT (last 30 lines)"
  echo "========================================"
  tail -30 "${FC_LOG}"
fi

# Unmount
umount "${MOUNT_POINT}"

# Clean up firecracker log
rm -f "${FC_LOG}"

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
