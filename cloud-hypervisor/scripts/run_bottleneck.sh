#!/usr/bin/env bash
# =============================================================================
# Run bottleneck analysis: benchmark with host-level monitoring (vmstat, iostat,
# mpstat) at fine-grained VM counts around the CPU saturation point.
#
# Runs run_parallel.sh at each VM count with concurrent host monitoring,
# saving per-run monitor logs alongside JSON results.
#
# Usage:
#   sudo ./run_bottleneck.sh <task-dir-or-rootfs> [options]
#
# Options:
#   --output <path>       Output JSON path (default: bottleneck_results.json)
#   --cooldown <seconds>  Pause between runs (default: 10)
#   --repeats <n>         Repeats per VM count (default: 3)
#   --resume              Skip already-completed runs
#   --log-dir <path>      Directory for monitor logs (default: ./bottleneck_logs/)
#
# Examples:
#   sudo ./run_bottleneck.sh terminal-bench/original-tasks/hello-world
#   sudo ./run_bottleneck.sh /opt/cloud-hypervisor/rootfs-task.ext4 --repeats 3
#   sudo ./run_bottleneck.sh terminal-bench/original-tasks/hello-world --resume
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------
# Defaults
# ---------------------------

INPUT=""
OUTPUT="bottleneck_results.json"
COOLDOWN=10
REPEATS=3
RESUME=false
LOG_DIR="./bottleneck_logs"

# VM_COUNTS is computed after machine info capture (see below)

# ---------------------------
# Parse arguments
# ---------------------------

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)    OUTPUT="$2";   shift 2 ;;
    --cooldown)  COOLDOWN="$2"; shift 2 ;;
    --repeats)   REPEATS="$2";  shift 2 ;;
    --resume)    RESUME=true;   shift   ;;
    --log-dir)   LOG_DIR="$2";  shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 <task-dir-or-rootfs> [options]"
      echo ""
      echo "Options:"
      echo "  --output <path>       Output JSON path (default: bottleneck_results.json)"
      echo "  --cooldown <seconds>  Pause between runs (default: 10)"
      echo "  --repeats <n>         Repeats per VM count (default: 3)"
      echo "  --resume              Skip already-completed runs"
      echo "  --log-dir <path>      Directory for monitor logs (default: ./bottleneck_logs/)"
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

INPUT="${POSITIONAL[0]:-}"

# ---------------------------
# Helpers
# ---------------------------

log()  { echo -e "\n[run-bottleneck] $*\n"; }
die()  { echo -e "\nERROR: $*\n" >&2; exit 1; }

# ---------------------------
# Validation
# ---------------------------

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root: sudo $0 $*"
fi

[[ -n "${INPUT}" ]]                || die "Usage: $0 <task-dir-or-rootfs> [options]"
[[ "${COOLDOWN}" =~ ^[0-9]+$ ]]   || die "cooldown must be a non-negative integer"
[[ "${REPEATS}" =~ ^[0-9]+$ ]]    || die "repeats must be a positive integer"
[[ "${REPEATS}" -ge 1 ]]          || die "repeats must be at least 1"

if [[ -d "${INPUT}" ]]; then
  log "Task directory: ${INPUT}"
elif [[ -f "${INPUT}" ]]; then
  log "Rootfs file: ${INPUT}"
else
  die "Input not found: ${INPUT}"
fi

# Check that monitoring tools are available
for cmd in vmstat iostat mpstat; do
  command -v "${cmd}" >/dev/null || die "${cmd} not found — install sysstat (apt install sysstat)"
done

# ---------------------------
# Create monitor log directory
# ---------------------------

mkdir -p "${LOG_DIR}"
log "Monitor logs: ${LOG_DIR}"

# ---------------------------
# Capture machine info
# ---------------------------

MACHINE_INFO_FILE="${LOG_DIR}/machine_info.txt"
log "Capturing machine info to ${MACHINE_INFO_FILE}"
{
  echo "=== Date ==="
  date -Iseconds
  echo ""
  echo "=== Hostname ==="
  hostname 2>/dev/null || true
  echo ""
  echo "=== lscpu ==="
  lscpu 2>/dev/null || true
  echo ""
  echo "=== free -h ==="
  free -h 2>/dev/null || true
  echo ""
  echo "=== /proc/meminfo (first 10 lines) ==="
  head -10 /proc/meminfo 2>/dev/null || true
  echo ""
  echo "=== uname -a ==="
  uname -a 2>/dev/null || true
  echo ""
  echo "=== lsblk ==="
  lsblk 2>/dev/null || true
} > "${MACHINE_INFO_FILE}" 2>&1

# Extract key machine info for JSON output
MACHINE_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
MACHINE_CPUS=$(nproc 2>/dev/null || echo "0")
MACHINE_CORES=$(lscpu 2>/dev/null | awk '/^Core\(s\) per socket:/ {print $NF}' || echo "0")
MACHINE_THREADS=$(lscpu 2>/dev/null | awk '/^Thread\(s\) per core:/ {print $NF}' || echo "0")
MACHINE_SOCKETS=$(lscpu 2>/dev/null | awk '/^Socket\(s\):/ {print $NF}' || echo "0")
MACHINE_MEM_TOTAL=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
MACHINE_MODEL=$(lscpu 2>/dev/null | grep 'Model name:' | sed 's/Model name: *//' || echo "unknown")

log "Machine: ${MACHINE_HOSTNAME} | ${MACHINE_CPUS} logical CPUs (${MACHINE_SOCKETS}s × ${MACHINE_CORES}c × ${MACHINE_THREADS}t) | ${MACHINE_MEM_TOTAL}MB RAM"
log "CPU model: ${MACHINE_MODEL}"

# ---------------------------
# Auto-compute VM count sequence based on physical cores
# ---------------------------

PHYSICAL_CORES=$((MACHINE_CORES * MACHINE_SOCKETS))
# Inflection point: physical_cores / vcpus_per_vm (2 vCPUs per VM)
VCPU_COUNT="${VCPU_COUNT:-2}"
INFLECTION=$((PHYSICAL_CORES / VCPU_COUNT))

log "Physical cores: ${PHYSICAL_CORES} | vCPUs per VM: ${VCPU_COUNT} | Expected inflection: ${INFLECTION} VMs"

# Build VM counts: every integer from 1 to 2x the inflection point
MAX_VM=$((INFLECTION * 2))
VM_COUNTS=()
for i in $(seq 1 "${MAX_VM}"); do
  VM_COUNTS+=("${i}")
done

# ---------------------------
# Summary
# ---------------------------

log "VM count sequence: ${VM_COUNTS[*]}"
log "Repeats per count: ${REPEATS}"
log "Cooldown between runs: ${COOLDOWN}s"
log "Output: ${OUTPUT}"

# ---------------------------
# Check available resources for the largest run
# ---------------------------

MAX_COUNT="${VM_COUNTS[-1]}"

AVAIL_MEM_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
NEEDED_MEM_MB=$((MAX_COUNT * 1024))

if [[ ${AVAIL_MEM_MB} -gt 0 ]] && [[ ${NEEDED_MEM_MB} -gt ${AVAIL_MEM_MB} ]]; then
  log "WARNING: Largest run (${MAX_COUNT} VMs) needs ~${NEEDED_MEM_MB}MB RAM, only ${AVAIL_MEM_MB}MB available"
  log "Smaller counts will still run. Larger counts may fail."
fi

if [[ ${MACHINE_CPUS} -gt 0 ]]; then
  log "Host CPUs: ${MACHINE_CPUS} | Max parallel VMs: ${MAX_COUNT} (2 vCPUs each = $((MAX_COUNT * 2)) vCPUs)"
fi

# ---------------------------
# Load existing results if resuming
# ---------------------------

EXISTING_RUNS="[]"
if [[ "${RESUME}" == "true" ]] && [[ -f "${OUTPUT}" ]]; then
  if command -v jq >/dev/null 2>&1; then
    EXISTING_RUNS=$(jq '.runs // []' "${OUTPUT}" 2>/dev/null || echo "[]")
    EXISTING_COUNT=$(echo "${EXISTING_RUNS}" | jq 'length')
    log "Resume mode: found ${EXISTING_COUNT} existing run(s) in ${OUTPUT}"
  else
    log "WARNING: jq not found, cannot parse existing results — resume disabled"
    RESUME=false
  fi
fi

# Check if a specific vm_count + repeat already has results
has_result() {
  local vm_count="$1"
  local repeat="$2"
  if [[ "${RESUME}" != "true" ]]; then
    return 1
  fi
  echo "${EXISTING_RUNS}" | jq -e \
    ".[] | select(.vm_count == ${vm_count} and .repeat == ${repeat})" \
    >/dev/null 2>&1
}

# ---------------------------
# Temporary file for per-run results from run_parallel.sh
# ---------------------------

TMP_RESULT=$(mktemp /tmp/bottleneck-run-XXXXXX.json)
TMP_RUN_OUTPUT=$(mktemp /tmp/bottleneck-run-output-XXXXXX.log)
trap "rm -f '${TMP_RESULT}' '${TMP_RUN_OUTPUT}'" EXIT

# ---------------------------
# Helper: write current results to output JSON (for incremental saving)
# ---------------------------

save_results() {
  local wall_clock="$1"
  if ! command -v jq >/dev/null 2>&1; then return; fi

  local runs_tmp
  runs_tmp=$(mktemp /tmp/bottleneck-runs-XXXXXX.json)
  jq -s '.' "${ALL_RUNS_FILE}" > "${runs_tmp}" 2>/dev/null || echo "[]" > "${runs_tmp}"

  jq -n \
    --arg task "${INPUT}" \
    --argjson repeats "${REPEATS}" \
    --argjson total_runs "${TOTAL_RUNS}" \
    --argjson completed "${COMPLETED_RUNS}" \
    --argjson skipped "${SKIPPED_RUNS}" \
    --argjson failed "${FAILED_RUNS}" \
    --argjson wall_clock "${wall_clock}" \
    --arg vm_counts "${VM_COUNTS[*]}" \
    --arg log_dir "${LOG_DIR}" \
    --arg hostname "${MACHINE_HOSTNAME}" \
    --argjson logical_cpus "${MACHINE_CPUS}" \
    --argjson cores_per_socket "${MACHINE_CORES}" \
    --argjson threads_per_core "${MACHINE_THREADS}" \
    --argjson sockets "${MACHINE_SOCKETS}" \
    --argjson total_mem_mb "${MACHINE_MEM_TOTAL}" \
    --arg cpu_model "${MACHINE_MODEL}" \
    --slurpfile runs "${runs_tmp}" \
    '{
      task: $task,
      machine: {
        hostname: $hostname,
        logical_cpus: $logical_cpus,
        cores_per_socket: $cores_per_socket,
        threads_per_core: $threads_per_core,
        sockets: $sockets,
        total_mem_mb: $total_mem_mb,
        cpu_model: $cpu_model
      },
      vm_counts: ($vm_counts | split(" ") | map(tonumber)),
      repeats_per_count: $repeats,
      total_runs: $total_runs,
      completed_runs: $completed,
      skipped_runs: $skipped,
      failed_runs: $failed,
      total_wall_clock_seconds: $wall_clock,
      monitor_log_dir: $log_dir,
      runs: $runs[0]
    }' > "${OUTPUT}"

  rm -f "${runs_tmp}"
}

# ---------------------------
# Run the bottleneck sweep
# ---------------------------

SCALING_START=$(date +%s)
TOTAL_RUNS=$(( ${#VM_COUNTS[@]} * REPEATS ))
COMPLETED_RUNS=0
SKIPPED_RUNS=0
FAILED_RUNS=0

# Collect all run results as JSON lines (one JSON object per line)
ALL_RUNS_FILE=$(mktemp /tmp/bottleneck-all-runs-XXXXXX.jsonl)

# If resuming, seed with existing runs
if [[ "${RESUME}" == "true" ]] && [[ "${EXISTING_RUNS}" != "[]" ]]; then
  echo "${EXISTING_RUNS}" | jq -c '.[]' >> "${ALL_RUNS_FILE}" 2>/dev/null || true
fi

for vm_count in "${VM_COUNTS[@]}"; do
  for repeat in $(seq 1 "${REPEATS}"); do

    RUN_LABEL="vm_count=${vm_count}, repeat=${repeat}/${REPEATS}"

    # Skip if we already have this result (resume mode)
    if has_result "${vm_count}" "${repeat}"; then
      log "SKIP [${RUN_LABEL}] — already in ${OUTPUT}"
      SKIPPED_RUNS=$((SKIPPED_RUNS + 1))
      continue
    fi

    log "========================================"
    log "RUN [${RUN_LABEL}]  ($(( COMPLETED_RUNS + SKIPPED_RUNS + FAILED_RUNS + 1 ))/${TOTAL_RUNS})"
    log "========================================"

    # Resource check before this specific run
    AVAIL_MEM_NOW=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    NEED_NOW=$((vm_count * 1024))
    if [[ ${AVAIL_MEM_NOW} -gt 0 ]] && [[ ${NEED_NOW} -gt ${AVAIL_MEM_NOW} ]]; then
      log "SKIP [${RUN_LABEL}] — not enough RAM (need ~${NEED_NOW}MB, have ${AVAIL_MEM_NOW}MB)"
      FAILED_RUNS=$((FAILED_RUNS + 1))

      SKIP_JSON=$(cat <<EOFSKIP
{"vm_count": ${vm_count}, "repeat": ${repeat}, "status": "skipped", "reason": "insufficient_ram", "needed_mb": ${NEED_NOW}, "available_mb": ${AVAIL_MEM_NOW}}
EOFSKIP
)
      echo "${SKIP_JSON}" >> "${ALL_RUNS_FILE}"
      continue
    fi

    # ---------------------------
    # Start host monitors
    # ---------------------------
    VMSTAT_LOG="${LOG_DIR}/vm${vm_count}_repeat${repeat}_vmstat.log"
    IOSTAT_LOG="${LOG_DIR}/vm${vm_count}_repeat${repeat}_iostat.log"
    MPSTAT_LOG="${LOG_DIR}/vm${vm_count}_repeat${repeat}_mpstat.log"

    vmstat 1 > "${VMSTAT_LOG}" &
    VMSTAT_PID=$!
    iostat -x 1 > "${IOSTAT_LOG}" &
    IOSTAT_PID=$!
    mpstat -P ALL 1 > "${MPSTAT_LOG}" &
    MPSTAT_PID=$!

    # ---------------------------
    # Run the parallel benchmark (capture output to find instance log dir)
    # ---------------------------
    RUN_EXIT=0
    "${SCRIPT_DIR}/run_parallel.sh" "${INPUT}" "${vm_count}" "${TMP_RESULT}" > "${TMP_RUN_OUTPUT}" 2>&1 || RUN_EXIT=$?
    cat "${TMP_RUN_OUTPUT}"

    # ---------------------------
    # Stop host monitors
    # ---------------------------
    kill ${VMSTAT_PID} ${IOSTAT_PID} ${MPSTAT_PID} 2>/dev/null || true
    wait ${VMSTAT_PID} 2>/dev/null || true
    wait ${IOSTAT_PID} 2>/dev/null || true
    wait ${MPSTAT_PID} 2>/dev/null || true

    # ---------------------------
    # Capture instance logs before they're lost
    # ---------------------------
    INST_LOG_SRC=$(grep 'Instance logs:' "${TMP_RUN_OUTPUT}" 2>/dev/null | tail -1 | sed 's/.*Instance logs: *//' | tr -d '[:space:]' || true)
    if [[ -n "${INST_LOG_SRC}" ]] && [[ -d "${INST_LOG_SRC}" ]]; then
      INST_LOG_DST="${LOG_DIR}/vm${vm_count}_repeat${repeat}_instances"
      cp -r "${INST_LOG_SRC}" "${INST_LOG_DST}" 2>/dev/null || true
      log "Saved instance logs to ${INST_LOG_DST}"
    else
      log "WARNING: Could not find instance logs (grep result: '${INST_LOG_SRC}')"
    fi

    RUN_TIMESTAMP=$(date -Iseconds)

    if [[ -f "${TMP_RESULT}" ]]; then
      if command -v jq >/dev/null 2>&1; then
        RUN_JSON=$(jq -c \
          --argjson vm_count "${vm_count}" \
          --argjson repeat "${repeat}" \
          --argjson exit_code "${RUN_EXIT}" \
          --arg timestamp "${RUN_TIMESTAMP}" \
          '. + {vm_count: $vm_count, repeat: $repeat, exit_code: $exit_code, timestamp: $timestamp}' \
          "${TMP_RESULT}" 2>/dev/null || echo "")
      else
        RUN_JSON="{\"vm_count\": ${vm_count}, \"repeat\": ${repeat}, \"exit_code\": ${RUN_EXIT}, \"timestamp\": \"${RUN_TIMESTAMP}\", \"raw_file\": \"${TMP_RESULT}\"}"
      fi

      if [[ -n "${RUN_JSON}" ]]; then
        echo "${RUN_JSON}" >> "${ALL_RUNS_FILE}"
      fi

      COMPLETED_RUNS=$((COMPLETED_RUNS + 1))

      if [[ ${RUN_EXIT} -ne 0 ]]; then
        log "WARNING: run_parallel.sh exited with code ${RUN_EXIT} for [${RUN_LABEL}]"
        FAILED_RUNS=$((FAILED_RUNS + 1))
      fi
    else
      log "WARNING: No results file produced for [${RUN_LABEL}]"
      FAILED_RUNS=$((FAILED_RUNS + 1))
    fi

    # ---------------------------
    # Incremental save (crash-safe)
    # ---------------------------
    CURRENT_WALL=$(( $(date +%s) - SCALING_START ))
    save_results "${CURRENT_WALL}"

    # Cleanup between runs: kill stragglers and verify memory is freed
    if [[ $(( COMPLETED_RUNS + SKIPPED_RUNS + FAILED_RUNS )) -lt ${TOTAL_RUNS} ]]; then
      pkill -9 cloud-hypervisor 2>/dev/null || true
      sleep 2

      # Wait for memory to be reclaimed before next run
      NEXT_NEED=$((vm_count * 1024))
      for _attempt in $(seq 1 5); do
        AVAIL_AFTER=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
        if [[ ${AVAIL_AFTER} -ge ${NEXT_NEED} ]]; then break; fi
        log "Waiting for memory to be reclaimed (have ${AVAIL_AFTER}MB, need ${NEXT_NEED}MB)..."
        sleep 3
      done

      if [[ ${COOLDOWN} -gt 0 ]]; then
        log "Cooldown: ${COOLDOWN}s"
        sleep "${COOLDOWN}"
      fi
    fi

  done
done

SCALING_END=$(date +%s)
SCALING_WALL=$((SCALING_END - SCALING_START))

# ---------------------------
# Final save
# ---------------------------

log "Assembling final results into ${OUTPUT}"
save_results "${SCALING_WALL}"

# Cleanup temp files
rm -f "${TMP_RESULT}" "${TMP_RUN_OUTPUT}" "${ALL_RUNS_FILE}"

# ---------------------------
# Final report
# ---------------------------

echo ""
echo "========================================"
echo "BOTTLENECK ANALYSIS COMPLETE"
echo "========================================"
echo "  Task:            ${INPUT}"
echo "  VM counts:       ${VM_COUNTS[*]}"
echo "  Repeats:         ${REPEATS}"
echo "  Total runs:      ${TOTAL_RUNS}"
echo "  Completed:       ${COMPLETED_RUNS}"
echo "  Skipped:         ${SKIPPED_RUNS}"
echo "  Failed:          ${FAILED_RUNS}"
echo "  Total wall time: ${SCALING_WALL}s"
echo "  Results:         ${OUTPUT}"
echo "  Monitor logs:    ${LOG_DIR}"
echo "========================================"

if [[ ${FAILED_RUNS} -gt 0 ]]; then
  exit 1
fi
exit 0
