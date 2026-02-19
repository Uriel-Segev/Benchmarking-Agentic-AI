#!/usr/bin/env bash
# =============================================================================
# Run scaling benchmark: execute a task at increasing parallel VM counts
#
# Runs run_parallel.sh at each power of 2 from 1 up to MAX_VMS and collects
# all results into a single JSON file for analysis / visualization.
#
# Usage:
#   sudo ./run_scaling.sh <task-dir-or-rootfs> <max_vms> --label <name> [options]
#
# Options:
#   --label <name>        Experiment label, e.g. "48c" (required)
#   --output <path>       Override output JSON path (default: auto in ~/results/)
#   --cooldown <seconds>  Pause between runs (default: 5)
#   --repeats <n>         Repeat each VM count n times (default: 1)
#   --resume              Skip VM counts that already have results in output file
#
# Results are saved to:
#   ~/results/<task>/cloud-hypervisor/<label>/<timestamp>/scaling.json
#
# Examples:
#   sudo ./run_scaling.sh /opt/cloud-hypervisor/rootfs-task.ext4 64 --label 48c --repeats 5
#   sudo ./run_scaling.sh /opt/cloud-hypervisor/rootfs-task.ext4 64 --label 48c --resume --output /path/to/old.json
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------
# Defaults
# ---------------------------

INPUT=""
MAX_VMS=""
LABEL=""
OUTPUT_EXPLICIT=""
COOLDOWN=5
REPEATS=1
RESUME=false
HYPERVISOR="cloud-hypervisor"

# ---------------------------
# Parse arguments
# ---------------------------

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)     LABEL="$2";           shift 2 ;;
    --output)    OUTPUT_EXPLICIT="$2"; shift 2 ;;
    --cooldown)  COOLDOWN="$2";        shift 2 ;;
    --repeats)   REPEATS="$2";         shift 2 ;;
    --resume)    RESUME=true;          shift   ;;
    -h|--help)
      echo "Usage: sudo $0 <task-dir-or-rootfs> <max_vms> --label <name> [options]"
      echo ""
      echo "Options:"
      echo "  --label <name>        Experiment label, e.g. '48c' (required)"
      echo "  --output <path>       Override output JSON path (default: auto in ~/results/)"
      echo "  --cooldown <seconds>  Pause between runs (default: 5)"
      echo "  --repeats <n>         Repeat each VM count n times (default: 1)"
      echo "  --resume              Skip VM counts already present in output file"
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

INPUT="${POSITIONAL[0]:-}"
MAX_VMS="${POSITIONAL[1]:-}"

# ---------------------------
# Helpers
# ---------------------------

log()  { echo -e "\n[run-scaling] $*\n"; }
die()  { echo -e "\nERROR: $*\n" >&2; exit 1; }

# ---------------------------
# Validation
# ---------------------------

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root: sudo $0 $*"
fi

[[ -n "${INPUT}" ]]    || die "Usage: $0 <task-dir-or-rootfs> <max_vms> --label <name> [options]"
[[ -n "${MAX_VMS}" ]]  || die "Usage: $0 <task-dir-or-rootfs> <max_vms> --label <name> [options]"
[[ -n "${LABEL}" ]]    || die "--label is required (e.g. --label 48c)"

[[ "${MAX_VMS}" =~ ^[0-9]+$ ]]  || die "max_vms must be a positive integer"
[[ "${MAX_VMS}" -ge 1 ]]        || die "max_vms must be at least 1"
[[ "${COOLDOWN}" =~ ^[0-9]+$ ]] || die "cooldown must be a non-negative integer"
[[ "${REPEATS}" =~ ^[0-9]+$ ]]  || die "repeats must be a positive integer"
[[ "${REPEATS}" -ge 1 ]]        || die "repeats must be at least 1"

if [[ -d "${INPUT}" ]]; then
  log "Task directory: ${INPUT}"
elif [[ -f "${INPUT}" ]]; then
  log "Rootfs file: ${INPUT}"
else
  die "Input not found: ${INPUT}"
fi

# ---------------------------
# Derive task name and compute results directory
# ---------------------------

if [[ -f "${INPUT}" ]]; then
  TASK_NAME=$(basename "${INPUT}" .ext4 | sed 's/^rootfs-//')
else
  TASK_NAME=$(basename "${INPUT}")
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${HOME}/results/${TASK_NAME}/${HYPERVISOR}/${LABEL}/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

if [[ -n "${OUTPUT_EXPLICIT}" ]]; then
  OUTPUT="${OUTPUT_EXPLICIT}"
else
  OUTPUT="${RESULTS_DIR}/scaling.json"
fi

log "Results dir: ${RESULTS_DIR}"

# ---------------------------
# Capture machine info (collected before experiment starts; does not affect timing)
# ---------------------------

MACHINE_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
MACHINE_CPUS=$(nproc 2>/dev/null || echo "0")
MACHINE_CORES=$(lscpu 2>/dev/null | awk '/^Core\(s\) per socket:/ {print $NF}' || echo "0")
MACHINE_SOCKETS=$(lscpu 2>/dev/null | awk '/^Socket\(s\):/ {print $NF}' || echo "0")
MACHINE_MEM_TOTAL=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
PHYSICAL_CORES=$(( MACHINE_CORES * MACHINE_SOCKETS ))

log "Machine: ${MACHINE_HOSTNAME} | ${MACHINE_CPUS} logical CPUs | ${PHYSICAL_CORES} physical cores | ${MACHINE_MEM_TOTAL}MB RAM"

# ---------------------------
# Build list of VM counts (powers of 2 up to MAX_VMS)
# ---------------------------

VM_COUNTS=()
n=1
while [[ ${n} -le ${MAX_VMS} ]]; do
  VM_COUNTS+=("${n}")
  n=$((n * 2))
done

log "Scaling sequence: ${VM_COUNTS[*]}"
log "Repeats per count: ${REPEATS}"
log "Cooldown between runs: ${COOLDOWN}s"
log "Output: ${OUTPUT}"

# ---------------------------
# Check available resources for the largest run
# ---------------------------

MAX_COUNT="${VM_COUNTS[-1]}"

# RAM check: each VM uses 1024 MiB by default
AVAIL_MEM_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
NEEDED_MEM_MB=$((MAX_COUNT * 1024))

if [[ ${AVAIL_MEM_MB} -gt 0 ]] && [[ ${NEEDED_MEM_MB} -gt ${AVAIL_MEM_MB} ]]; then
  log "WARNING: Largest run (${MAX_COUNT} VMs) needs ~${NEEDED_MEM_MB}MB RAM, only ${AVAIL_MEM_MB}MB available"
  log "Smaller counts will still run. Larger counts may fail."
fi

# CPU check (informational)
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

TMP_RESULT=$(mktemp /tmp/scaling-run-XXXXXX.json)
trap "rm -f '${TMP_RESULT}'" EXIT

# ---------------------------
# Run the scaling sweep
# ---------------------------

SCALING_START=$(date +%s)
TOTAL_RUNS=$(( ${#VM_COUNTS[@]} * REPEATS ))
COMPLETED_RUNS=0
SKIPPED_RUNS=0
FAILED_RUNS=0

# Collect all run results as JSON lines (one JSON object per line)
ALL_RUNS_FILE=$(mktemp /tmp/scaling-all-runs-XXXXXX.jsonl)

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
    log "RUN [${RUN_LABEL}]  ($(( COMPLETED_RUNS + SKIPPED_RUNS + 1 ))/${TOTAL_RUNS})"
    log "========================================"

    # Resource check before this specific run
    AVAIL_MEM_NOW=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    NEED_NOW=$((vm_count * 1024))
    if [[ ${AVAIL_MEM_NOW} -gt 0 ]] && [[ ${NEED_NOW} -gt ${AVAIL_MEM_NOW} ]]; then
      log "SKIP [${RUN_LABEL}] — not enough RAM (need ~${NEED_NOW}MB, have ${AVAIL_MEM_NOW}MB)"
      FAILED_RUNS=$((FAILED_RUNS + 1))

      # Record the skip in results
      SKIP_JSON=$(cat <<EOFSKIP
{"vm_count": ${vm_count}, "repeat": ${repeat}, "status": "skipped", "reason": "insufficient_ram", "needed_mb": ${NEED_NOW}, "available_mb": ${AVAIL_MEM_NOW}}
EOFSKIP
)
      echo "${SKIP_JSON}" >> "${ALL_RUNS_FILE}"
      continue
    fi

    # Run the parallel benchmark
    RUN_EXIT=0
    "${SCRIPT_DIR}/run_parallel.sh" "${INPUT}" "${vm_count}" "${TMP_RESULT}" || RUN_EXIT=$?

    RUN_TIMESTAMP=$(date -Iseconds)

    if [[ -f "${TMP_RESULT}" ]]; then
      # Wrap the run_parallel.sh output with metadata
      if command -v jq >/dev/null 2>&1; then
        RUN_JSON=$(jq -c \
          --argjson vm_count "${vm_count}" \
          --argjson repeat "${repeat}" \
          --argjson exit_code "${RUN_EXIT}" \
          --arg timestamp "${RUN_TIMESTAMP}" \
          '. + {vm_count: $vm_count, repeat: $repeat, exit_code: $exit_code, timestamp: $timestamp}' \
          "${TMP_RESULT}" 2>/dev/null || echo "")
      else
        # Fallback: no jq — embed raw JSON with shell
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

    # Cooldown between runs (skip after the very last run)
    if [[ ${COOLDOWN} -gt 0 ]] && [[ $(( COMPLETED_RUNS + SKIPPED_RUNS + FAILED_RUNS )) -lt ${TOTAL_RUNS} ]]; then
      log "Cooldown: ${COOLDOWN}s"
      sleep "${COOLDOWN}"
    fi

  done
done

SCALING_END=$(date +%s)
SCALING_WALL=$((SCALING_END - SCALING_START))

# ---------------------------
# Assemble final combined JSON (using --slurpfile to avoid arg-too-long)
# ---------------------------

log "Assembling results into ${OUTPUT}"

if command -v jq >/dev/null 2>&1; then
  # Build the runs array from collected JSON lines into a temp file
  RUNS_TMP=$(mktemp /tmp/scaling-runs-XXXXXX.json)
  jq -s '.' "${ALL_RUNS_FILE}" > "${RUNS_TMP}" 2>/dev/null || echo "[]" > "${RUNS_TMP}"

  jq -n \
    --arg task "${INPUT}" \
    --arg hypervisor "${HYPERVISOR}" \
    --arg label "${LABEL}" \
    --arg hostname "${MACHINE_HOSTNAME}" \
    --argjson logical_cpus "${MACHINE_CPUS}" \
    --argjson physical_cores "${PHYSICAL_CORES}" \
    --argjson total_mem_mb "${MACHINE_MEM_TOTAL}" \
    --argjson max_vms "${MAX_VMS}" \
    --argjson repeats "${REPEATS}" \
    --argjson total_runs "${TOTAL_RUNS}" \
    --argjson completed "${COMPLETED_RUNS}" \
    --argjson skipped "${SKIPPED_RUNS}" \
    --argjson failed "${FAILED_RUNS}" \
    --argjson wall_clock "${SCALING_WALL}" \
    --arg vm_counts "${VM_COUNTS[*]}" \
    --slurpfile runs "${RUNS_TMP}" \
    '{
      task: $task,
      hypervisor: $hypervisor,
      label: $label,
      machine: {
        hostname: $hostname,
        logical_cpus: $logical_cpus,
        physical_cores: $physical_cores,
        total_mem_mb: $total_mem_mb
      },
      max_vms: $max_vms,
      vm_counts: ($vm_counts | split(" ") | map(tonumber)),
      repeats_per_count: $repeats,
      total_runs: $total_runs,
      completed_runs: $completed,
      skipped_runs: $skipped,
      failed_runs: $failed,
      total_wall_clock_seconds: $wall_clock,
      runs: $runs[0]
    }' > "${OUTPUT}"

  rm -f "${RUNS_TMP}"
else
  # Fallback: build JSON without jq (best effort)
  log "WARNING: jq not found — output may not be perfectly formatted"
  {
    echo "{"
    echo "  \"task\": \"${INPUT}\","
    echo "  \"hypervisor\": \"${HYPERVISOR}\","
    echo "  \"label\": \"${LABEL}\","
    echo "  \"machine\": {\"hostname\": \"${MACHINE_HOSTNAME}\", \"logical_cpus\": ${MACHINE_CPUS}, \"physical_cores\": ${PHYSICAL_CORES}, \"total_mem_mb\": ${MACHINE_MEM_TOTAL}},"
    echo "  \"max_vms\": ${MAX_VMS},"
    echo "  \"vm_counts\": [$(IFS=,; echo "${VM_COUNTS[*]}")],"
    echo "  \"repeats_per_count\": ${REPEATS},"
    echo "  \"total_runs\": ${TOTAL_RUNS},"
    echo "  \"completed_runs\": ${COMPLETED_RUNS},"
    echo "  \"skipped_runs\": ${SKIPPED_RUNS},"
    echo "  \"failed_runs\": ${FAILED_RUNS},"
    echo "  \"total_wall_clock_seconds\": ${SCALING_WALL},"
    echo "  \"runs\": ["
    # Paste all JSON lines with commas
    first=true
    while IFS= read -r line; do
      if [[ "${first}" == "true" ]]; then
        echo "    ${line}"
        first=false
      else
        echo "    ,${line}"
      fi
    done < "${ALL_RUNS_FILE}"
    echo "  ]"
    echo "}"
  } > "${OUTPUT}"
fi

# Cleanup temp files
rm -f "${TMP_RESULT}" "${ALL_RUNS_FILE}"

# ---------------------------
# Final report
# ---------------------------

echo ""
echo "========================================"
echo "SCALING BENCHMARK COMPLETE"
echo "========================================"
echo "  Task:            ${INPUT}"
echo "  Hypervisor:      ${HYPERVISOR}"
echo "  Label:           ${LABEL}"
echo "  VM counts:       ${VM_COUNTS[*]}"
echo "  Repeats:         ${REPEATS}"
echo "  Total runs:      ${TOTAL_RUNS}"
echo "  Completed:       ${COMPLETED_RUNS}"
echo "  Skipped:         ${SKIPPED_RUNS}"
echo "  Failed:          ${FAILED_RUNS}"
echo "  Total wall time: ${SCALING_WALL}s"
echo "  Results:         ${OUTPUT}"
echo "========================================"

if [[ ${FAILED_RUNS} -gt 0 ]]; then
  exit 1
fi
exit 0
