#!/usr/bin/env bash
# =============================================================================
# Run N Cloud Hypervisor VMs in parallel, each executing the same task
#
# This script:
#   1. Prepares N rootfs copies from a source rootfs (or task directory)
#   2. Creates TAP devices and iptables rules for instances 1..N-1
#   3. Runs a single ARP safety check (covers all instances)
#   4. Launches N run_task.sh instances in parallel
#   5. Aggregates results into parallel_results.json
#   6. Cleans up TAP devices and rules it created (leaves tap0 untouched)
#
# Usage:
#   sudo ./run_parallel.sh <rootfs_or_task_dir> <num_instances> [results_output]
#
# Examples:
#   sudo ./run_parallel.sh /opt/cloud-hypervisor/rootfs-task.ext4 4
#   sudo ./run_parallel.sh terminal-bench/original-tasks/hello-world 8 /tmp/results.json
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------
# Configuration
# ---------------------------

WORKDIR="${WORKDIR:-/opt/cloud-hypervisor}"
INPUT="${1:-}"
NUM_INSTANCES="${2:-}"
RESULTS_OUTPUT="${3:-parallel_results.json}"

# iptables chain owned by install_cloud_hypervisor.sh (we add rules to it, not create it)
CH_FWD_CHAIN="CH_FWD"

# Base subnet: instance i gets 192.168.(100+i).0/30
SUBNET_BASE=100

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[run-parallel] $*\n"; }
die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

# Track what we created so cleanup only removes our resources
CREATED_TAPS=()
CREATED_ROOTFS=()
INSTANCE_LOG_DIR=""

cleanup() {
  log "Cleaning up parallel resources"

  # Remove TAP devices we created (tap1+, never tap0)
  for tap in "${CREATED_TAPS[@]+"${CREATED_TAPS[@]}"}"; do
    # Remove iptables rules for this TAP from CH_FWD chain
    local default_iface
    default_iface="$(ip route list default | awk '{print $5; exit}' || true)"
    if [[ -n "${default_iface}" ]]; then
      iptables -D "${CH_FWD_CHAIN}" -i "${tap}" -o "${default_iface}" -j ACCEPT 2>/dev/null || true
      iptables -D "${CH_FWD_CHAIN}" -i "${default_iface}" -o "${tap}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
    # Remove the TAP device
    ip link del "${tap}" 2>/dev/null || true
    echo "  Removed ${tap}"
  done

  # Remove rootfs copies
  for rootfs in "${CREATED_ROOTFS[@]+"${CREATED_ROOTFS[@]}"}"; do
    rm -f "${rootfs}"
  done

  # Unmount any instance mount points we may have left
  for i in $(seq 0 $((NUM_INSTANCES - 1))); do
    local mnt="/mnt/ch-rootfs-${i}"
    if mountpoint -q "${mnt}" 2>/dev/null; then
      umount "${mnt}" 2>/dev/null || true
    fi
  done

  log "Cleanup complete"
}

trap cleanup EXIT

# ---------------------------
# Validation
# ---------------------------

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root: sudo $0 $*"
fi

[[ -n "${INPUT}" ]] || die "Usage: $0 <rootfs_or_task_dir> <num_instances> [results_output]"
[[ -n "${NUM_INSTANCES}" ]] || die "Usage: $0 <rootfs_or_task_dir> <num_instances> [results_output]"
[[ "${NUM_INSTANCES}" =~ ^[0-9]+$ ]] || die "num_instances must be a positive integer"
[[ "${NUM_INSTANCES}" -ge 1 ]] || die "num_instances must be at least 1"
[[ "${NUM_INSTANCES}" -le 254 ]] || die "num_instances must be at most 254 (MAC address limit)"

command -v cloud-hypervisor >/dev/null || die "cloud-hypervisor not found in PATH"

# ---------------------------
# Resolve source rootfs
# ---------------------------

SOURCE_ROOTFS=""

if [[ -d "${INPUT}" ]]; then
  # Input is a task directory — build rootfs from it
  log "Input is a directory; building rootfs with prepare_task_rootfs.sh"
  SOURCE_ROOTFS="${WORKDIR}/rootfs-parallel-source.ext4"
  "${SCRIPT_DIR}/prepare_task_rootfs.sh" "${INPUT}" "${SOURCE_ROOTFS}"
elif [[ -f "${INPUT}" ]]; then
  SOURCE_ROOTFS="${INPUT}"
else
  die "Input not found: ${INPUT}"
fi

[[ -f "${SOURCE_ROOTFS}" ]] || die "Source rootfs not found: ${SOURCE_ROOTFS}"

# ---------------------------
# Disk space check
# ---------------------------

log "Checking disk space for ${NUM_INSTANCES} rootfs copies"
ROOTFS_SIZE_KB=$(du -k "${SOURCE_ROOTFS}" | awk '{print $1}')
NEEDED_KB=$((ROOTFS_SIZE_KB * NUM_INSTANCES))
AVAIL_KB=$(df -k "$(dirname "${SOURCE_ROOTFS}")" | awk 'NR==2{print $4}')

echo "  Source rootfs: $((ROOTFS_SIZE_KB / 1024))MB"
echo "  Need: $((NEEDED_KB / 1024))MB for ${NUM_INSTANCES} copies"
echo "  Available: $((AVAIL_KB / 1024))MB"

if [[ ${NEEDED_KB} -gt ${AVAIL_KB} ]]; then
  die "Not enough disk space: need $((NEEDED_KB / 1024))MB, have $((AVAIL_KB / 1024))MB"
fi

# ---------------------------
# Create per-instance log directory
# ---------------------------

INSTANCE_LOG_DIR=$(mktemp -d -t ch-parallel-XXXXXX)
log "Instance logs: ${INSTANCE_LOG_DIR}"

# ---------------------------
# Copy rootfs for each instance
# ---------------------------

log "Creating ${NUM_INSTANCES} rootfs copies"
for i in $(seq 0 $((NUM_INSTANCES - 1))); do
  INST_ROOTFS="${WORKDIR}/rootfs-instance-${i}.ext4"
  cp "${SOURCE_ROOTFS}" "${INST_ROOTFS}"
  CREATED_ROOTFS+=("${INST_ROOTFS}")
  echo "  Created rootfs-instance-${i}.ext4"
done

# ---------------------------
# Detect default interface
# ---------------------------

DEFAULT_IFACE="$(ip route list default | awk '{print $5; exit}' || true)"
[[ -n "${DEFAULT_IFACE}" ]] || die "Could not detect DEFAULT_IFACE"

# ---------------------------
# Create TAP devices for instances 1..N-1
# (tap0 already exists from install_cloud_hypervisor.sh)
# ---------------------------

log "Setting up TAP devices"
echo "  tap0 already exists (from install_cloud_hypervisor.sh)"

for i in $(seq 1 $((NUM_INSTANCES - 1))); do
  TAP="tap${i}"
  TAP_IP_I="192.168.$((SUBNET_BASE + i)).1"

  # Remove old TAP if it exists (idempotent)
  ip link del "${TAP}" 2>/dev/null || true

  # Create TAP device
  ip tuntap add dev "${TAP}" mode tap
  ip addr add "${TAP_IP_I}/30" dev "${TAP}"
  ip link set dev "${TAP}" up
  CREATED_TAPS+=("${TAP}")

  # Add forwarding rules to the existing CH_FWD chain (idempotent)
  iptables -C "${CH_FWD_CHAIN}" -i "${TAP}" -o "${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null \
    || iptables -A "${CH_FWD_CHAIN}" -i "${TAP}" -o "${DEFAULT_IFACE}" -j ACCEPT
  iptables -C "${CH_FWD_CHAIN}" -i "${DEFAULT_IFACE}" -o "${TAP}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A "${CH_FWD_CHAIN}" -i "${DEFAULT_IFACE}" -o "${TAP}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  echo "  Created ${TAP} at ${TAP_IP_I}/30"
done

# ---------------------------
# Single ARP safety check
# ---------------------------

log "Running ARP safety check (10s) on ${DEFAULT_IFACE}"
TAP0_IP="192.168.${SUBNET_BASE}.1"
echo "  Checking for dangerous ARP involving ${TAP0_IP}..."
if timeout 10 tcpdump -n -c 1 -i "${DEFAULT_IFACE}" "arp and host ${TAP0_IP}" 2>/dev/null; then
  die "REFUSING TO RUN (CLOUDLAB SAFETY): Saw ARP involving TAP_IP (${TAP0_IP}) on ${DEFAULT_IFACE}. This is dangerous on CloudLab!"
fi
echo "  ARP check passed — safe to launch all instances"

# ---------------------------
# Launch N instances in parallel
# ---------------------------

log "Launching ${NUM_INSTANCES} Cloud Hypervisor instances in parallel"

PIDS=()
for i in $(seq 0 $((NUM_INSTANCES - 1))); do
  TAP_IP_I="192.168.$((SUBNET_BASE + i)).1"
  FC_IP_I="192.168.$((SUBNET_BASE + i)).2"

  INST_ROOTFS="${WORKDIR}/rootfs-instance-${i}.ext4"
  INST_LOG="${INSTANCE_LOG_DIR}/instance-${i}.log"

  echo "  Instance ${i}: tap${i} ${FC_IP_I} -> ${INST_LOG}"

  TAP_DEV="tap${i}" \
  TAP_IP="${TAP_IP_I}" \
  FC_IP="${FC_IP_I}" \
  MOUNT_POINT="/mnt/ch-rootfs-${i}" \
  SKIP_ARP_CHECK=1 \
  INSTANCE_ID="${i}" \
    "${SCRIPT_DIR}/run_task.sh" "${INST_ROOTFS}" > "${INST_LOG}" 2>&1 &

  PIDS+=($!)
done

# ---------------------------
# Wait for all instances
# ---------------------------

log "Waiting for all ${NUM_INSTANCES} instances to complete"
WALL_START=$(date +%s)

EXIT_CODES=()
for idx in $(seq 0 $((NUM_INSTANCES - 1))); do
  pid="${PIDS[$idx]}"
  wait "${pid}" && EXIT_CODES+=("0") || EXIT_CODES+=("$?")
  echo "  Instance ${idx} (PID ${pid}) exited with code ${EXIT_CODES[$idx]}"
done

WALL_END=$(date +%s)
WALL_CLOCK=$((WALL_END - WALL_START))

# ---------------------------
# Aggregate results
# ---------------------------

log "Aggregating results"

TOTAL_PASSED=0
TOTAL_FAILED=0
COMPLETED=0
INSTANCES_JSON=""

# Timing arrays for aggregation
BOOT_TIMES=()
SOLUTION_TIMES=()
TEST_TIMES=()
TASK_TOTAL_TIMES=()
SHUTDOWN_TIMES=()
LIFECYCLE_TIMES=()

# Helper to extract results and timing from a mounted rootfs
extract_instance_data() {
  local mnt="$1"

  if [[ -f "${mnt}/app/results.json" ]]; then
    STATUS=$(grep -oP '"status":\s*"\K[^"]+' "${mnt}/app/results.json" || echo "unknown")
    PASSED=$(grep -oP '"tests_passed":\s*\K\d+' "${mnt}/app/results.json" || echo "0")
    FAILED=$(grep -oP '"tests_failed":\s*\K\d+' "${mnt}/app/results.json" || echo "0")
  fi

  if [[ -f "${mnt}/app/timing_combined.json" ]]; then
    BOOT_T=$(grep -oP '"boot_time_s":\s*\K[0-9.]+' "${mnt}/app/timing_combined.json" || echo "0")
    SOLUTION_T=$(grep -oP '"solution_time_s":\s*\K[0-9.]+' "${mnt}/app/timing_combined.json" || echo "0")
    TEST_T=$(grep -oP '"test_time_s":\s*\K[0-9.]+' "${mnt}/app/timing_combined.json" || echo "0")
    TASK_TOTAL_T=$(grep -oP '"task_total_time_s":\s*\K[0-9.]+' "${mnt}/app/timing_combined.json" || echo "0")
    SHUTDOWN_T=$(grep -oP '"shutdown_time_s":\s*\K[0-9.]+' "${mnt}/app/timing_combined.json" || echo "0")
    LIFECYCLE_T=$(grep -oP '"total_vm_lifecycle_s":\s*\K[0-9.]+' "${mnt}/app/timing_combined.json" || echo "0")
    HAS_TIMING=true
  fi
}

for i in $(seq 0 $((NUM_INSTANCES - 1))); do
  INST_ROOTFS="${WORKDIR}/rootfs-instance-${i}.ext4"
  MNT="/mnt/ch-rootfs-${i}"
  mkdir -p "${MNT}"

  STATUS="error"
  PASSED=0
  FAILED=0
  EXIT_CODE="${EXIT_CODES[$i]}"
  HAS_TIMING=false
  BOOT_T="0"
  SOLUTION_T="0"
  TEST_T="0"
  TASK_TOTAL_T="0"
  SHUTDOWN_T="0"
  LIFECYCLE_T="0"

  # Mount to extract results and timing
  if mount -o loop,ro "${INST_ROOTFS}" "${MNT}" 2>/dev/null; then
    extract_instance_data "${MNT}"
    umount "${MNT}" 2>/dev/null || true
  else
    # Try fsck then mount
    e2fsck -y "${INST_ROOTFS}" >/dev/null 2>&1 || true
    if mount -o loop,ro "${INST_ROOTFS}" "${MNT}" 2>/dev/null; then
      extract_instance_data "${MNT}"
      umount "${MNT}" 2>/dev/null || true
    fi
  fi

  TOTAL_PASSED=$((TOTAL_PASSED + PASSED))
  TOTAL_FAILED=$((TOTAL_FAILED + FAILED))
  if [[ "${EXIT_CODE}" == "0" ]]; then
    COMPLETED=$((COMPLETED + 1))
  fi

  # Collect timing values for aggregation
  if [[ "${HAS_TIMING}" == "true" ]]; then
    BOOT_TIMES+=("${BOOT_T}")
    SOLUTION_TIMES+=("${SOLUTION_T}")
    TEST_TIMES+=("${TEST_T}")
    TASK_TOTAL_TIMES+=("${TASK_TOTAL_T}")
    SHUTDOWN_TIMES+=("${SHUTDOWN_T}")
    LIFECYCLE_TIMES+=("${LIFECYCLE_T}")
  fi

  # Build per-instance JSON entry
  if [[ "${HAS_TIMING}" == "true" ]]; then
    TIMING_ENTRY=", \"timing\": {\"boot_time_s\": ${BOOT_T}, \"solution_time_s\": ${SOLUTION_T}, \"test_time_s\": ${TEST_T}, \"task_total_time_s\": ${TASK_TOTAL_T}, \"shutdown_time_s\": ${SHUTDOWN_T}, \"total_vm_lifecycle_s\": ${LIFECYCLE_T}}"
  else
    TIMING_ENTRY=""
  fi
  ENTRY="    {\"id\": ${i}, \"status\": \"${STATUS}\", \"tests_passed\": ${PASSED}, \"tests_failed\": ${FAILED}, \"exit_code\": ${EXIT_CODE}${TIMING_ENTRY}}"
  if [[ -n "${INSTANCES_JSON}" ]]; then
    INSTANCES_JSON="${INSTANCES_JSON},
${ENTRY}"
  else
    INSTANCES_JSON="${ENTRY}"
  fi
done

# Compute min/max/avg stats using awk
compute_stats() {
  local values=("$@")
  if [[ ${#values[@]} -eq 0 ]]; then
    echo '{"min": 0, "max": 0, "avg": 0}'
    return
  fi
  echo "${values[@]}" | awk '{
    min=$1; max=$1; sum=0;
    for(i=1;i<=NF;i++) {
      if($i<min) min=$i;
      if($i>max) max=$i;
      sum+=$i;
    }
    printf "{\"min\": %.3f, \"max\": %.3f, \"avg\": %.3f}", min, max, sum/NF
  }'
}

# Build timing summary JSON
if [[ ${#BOOT_TIMES[@]} -gt 0 ]]; then
  BOOT_STATS=$(compute_stats "${BOOT_TIMES[@]}")
  SOLUTION_STATS=$(compute_stats "${SOLUTION_TIMES[@]}")
  TEST_STATS=$(compute_stats "${TEST_TIMES[@]}")
  TASK_TOTAL_STATS=$(compute_stats "${TASK_TOTAL_TIMES[@]}")
  SHUTDOWN_STATS=$(compute_stats "${SHUTDOWN_TIMES[@]}")
  LIFECYCLE_STATS=$(compute_stats "${LIFECYCLE_TIMES[@]}")

  TIMING_SUMMARY_JSON="\"timing_summary\": {
    \"boot_time_s\": ${BOOT_STATS},
    \"solution_time_s\": ${SOLUTION_STATS},
    \"test_time_s\": ${TEST_STATS},
    \"task_total_time_s\": ${TASK_TOTAL_STATS},
    \"shutdown_time_s\": ${SHUTDOWN_STATS},
    \"total_vm_lifecycle_s\": ${LIFECYCLE_STATS}
  },"
else
  TIMING_SUMMARY_JSON=""
fi

# Write combined results
cat > "${RESULTS_OUTPUT}" <<EOF
{
  "total_instances": ${NUM_INSTANCES},
  "completed": ${COMPLETED},
  "total_tests_passed": ${TOTAL_PASSED},
  "total_tests_failed": ${TOTAL_FAILED},
  "wall_clock_seconds": ${WALL_CLOCK},
  ${TIMING_SUMMARY_JSON}
  "instances": [
${INSTANCES_JSON}
  ]
}
EOF

# ---------------------------
# Final report
# ---------------------------

echo ""
echo "========================================"
echo "PARALLEL RESULTS"
echo "========================================"
echo "  Instances:     ${NUM_INSTANCES}"
echo "  Completed:     ${COMPLETED}"
echo "  Total Passed:  ${TOTAL_PASSED}"
echo "  Total Failed:  ${TOTAL_FAILED}"
echo "  Wall clock:    ${WALL_CLOCK}s"

if [[ ${#BOOT_TIMES[@]} -gt 0 ]]; then
  echo ""
  echo "  TIMING SUMMARY (across ${#BOOT_TIMES[@]} instances)"
  echo "  ──────────────────────────────────────"
  echo "${BOOT_TIMES[@]}" | awk '{min=$1;max=$1;s=0;for(i=1;i<=NF;i++){if($i<min)min=$i;if($i>max)max=$i;s+=$i}printf "  Boot time:      min=%.3fs  max=%.3fs  avg=%.3fs\n",min,max,s/NF}'
  echo "${SOLUTION_TIMES[@]}" | awk '{min=$1;max=$1;s=0;for(i=1;i<=NF;i++){if($i<min)min=$i;if($i>max)max=$i;s+=$i}printf "  Solution time:  min=%.3fs  max=%.3fs  avg=%.3fs\n",min,max,s/NF}'
  echo "${TEST_TIMES[@]}" | awk '{min=$1;max=$1;s=0;for(i=1;i<=NF;i++){if($i<min)min=$i;if($i>max)max=$i;s+=$i}printf "  Test time:      min=%.3fs  max=%.3fs  avg=%.3fs\n",min,max,s/NF}'
  echo "${TASK_TOTAL_TIMES[@]}" | awk '{min=$1;max=$1;s=0;for(i=1;i<=NF;i++){if($i<min)min=$i;if($i>max)max=$i;s+=$i}printf "  Task total:     min=%.3fs  max=%.3fs  avg=%.3fs\n",min,max,s/NF}'
  echo "${SHUTDOWN_TIMES[@]}" | awk '{min=$1;max=$1;s=0;for(i=1;i<=NF;i++){if($i<min)min=$i;if($i>max)max=$i;s+=$i}printf "  Shutdown time:  min=%.3fs  max=%.3fs  avg=%.3fs\n",min,max,s/NF}'
  echo "${LIFECYCLE_TIMES[@]}" | awk '{min=$1;max=$1;s=0;for(i=1;i<=NF;i++){if($i<min)min=$i;if($i>max)max=$i;s+=$i}printf "  VM lifecycle:   min=%.3fs  max=%.3fs  avg=%.3fs\n",min,max,s/NF}'
fi

echo ""
echo "  Results:       ${RESULTS_OUTPUT}"
echo "  Instance logs: ${INSTANCE_LOG_DIR}"
echo "========================================"

# Exit with failure if any instance failed
if [[ ${COMPLETED} -lt ${NUM_INSTANCES} ]]; then
  exit 1
fi
exit 0
