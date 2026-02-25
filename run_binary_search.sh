#!/usr/bin/env bash
# =============================================================================
# Binary search for the maximum stable parallel VM count
#
# Finds the largest N where all N VMs complete successfully when run in
# parallel via run_parallel.sh. Timing data is recorded at every probe so
# the full result set can be used for post-hoc non-linearity analysis.
#
# The ARP safety check (CloudLab guard) runs ONCE at startup, not per probe.
# Probes skip it via SKIP_ARP_CHECK=1.
#
# Usage:
#   sudo ./run_binary_search.sh [<task-dir-or-rootfs>] \
#     --hypervisor <firecracker|cloud-hypervisor> --label <name> [options]
#
# Options:
#   --hypervisor <name>   firecracker or cloud-hypervisor (required)
#   --label <name>        experiment label, e.g. "32c" (required)
#   --task <name>         shorthand for tasks/<name>/ (e.g. --task hello-world)
#   --repeats <n>         run_parallel.sh calls per binary search probe (default: 3)
#                         all repeats must pass for a probe to be considered stable
#   --resume              resume from the most recent binary_search.json for this
#                         task/hypervisor/label, or from --output if specified
#   --max-vms <n>         override upper bound (default: auto from RAM + disk)
#   --vm-ram <mb>         RAM per VM in MB for ceiling estimate (default: 1024)
#   --cooldown <s>        seconds to wait between every run_parallel.sh call (default: 10)
#   --output <path>       override output JSON path (also used as resume source)
#
# Results saved to:
#   ~/results/<task>/<hypervisor>/<label>/<timestamp>/binary_search.json
#
# NOTE: If no failures are found within the search range, max_stable_vms will
# equal hi_initial and ceiling_found will be false. Re-run with a larger
# --max-vms to find the true crash limit.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------
# Defaults
# ---------------------------

INPUT=""
TASK_FLAG=""
HYPERVISOR=""
LABEL=""
REPEATS=3
RESUME=false
MAX_VMS_OVERRIDE=""
VM_RAM_MB=1024
COOLDOWN=10
OUTPUT_EXPLICIT=""

# ---------------------------
# Parse arguments
# ---------------------------

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hypervisor) HYPERVISOR="$2";       shift 2 ;;
    --label)      LABEL="$2";            shift 2 ;;
    --task)       TASK_FLAG="$2";        shift 2 ;;
    --repeats)    REPEATS="$2";          shift 2 ;;
    --resume)     RESUME=true;           shift   ;;
    --max-vms)    MAX_VMS_OVERRIDE="$2"; shift 2 ;;
    --vm-ram)     VM_RAM_MB="$2";        shift 2 ;;
    --cooldown)   COOLDOWN="$2";         shift 2 ;;
    --output)     OUTPUT_EXPLICIT="$2";  shift 2 ;;
    -h|--help)
      sed -n '3,33p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

INPUT="${POSITIONAL[0]:-}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[binary-search] $*\n"; }
die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

# ---------------------------
# Validation
# ---------------------------

[[ "${EUID}" -eq 0 ]]    || die "Run as root: sudo $0 $*"
[[ -n "${HYPERVISOR}" ]] || die "--hypervisor is required (firecracker or cloud-hypervisor)"
[[ -n "${LABEL}" ]]      || die "--label is required"
[[ "${REPEATS}" =~ ^[0-9]+$ ]] && [[ "${REPEATS}" -ge 1 ]] || die "--repeats must be a positive integer"

# Resolve --task shorthand before checking INPUT
if [[ -n "${TASK_FLAG}" ]]; then
  [[ -n "${INPUT}" ]] && die "Cannot use both a positional argument and --task"
  INPUT="${SCRIPT_DIR}/tasks/${TASK_FLAG}"
fi

[[ -n "${INPUT}" ]] || die "Provide a task via --task <name> or as a positional argument"

case "${HYPERVISOR}" in
  firecracker)
    HV_SCRIPT_DIR="${SCRIPT_DIR}/firecracker/scripts"
    WORKDIR="/opt/firecracker"
    HV_BIN="firecracker"
    ;;
  cloud-hypervisor)
    HV_SCRIPT_DIR="${SCRIPT_DIR}/cloud-hypervisor/scripts"
    WORKDIR="/opt/cloud-hypervisor"
    HV_BIN="cloud-hypervisor"
    ;;
  *)
    die "Unknown hypervisor '${HYPERVISOR}'. Use firecracker or cloud-hypervisor."
    ;;
esac

PARALLEL_SH="${HV_SCRIPT_DIR}/run_parallel.sh"
[[ -f "${PARALLEL_SH}" ]] || die "run_parallel.sh not found at ${PARALLEL_SH}"
command -v "${HV_BIN}" >/dev/null || die "${HV_BIN} not found in PATH"

if [[ -d "${INPUT}" ]]; then
  log "Task directory: ${INPUT}"
elif [[ -f "${INPUT}" ]]; then
  log "Rootfs file: ${INPUT}"
else
  die "Input not found: ${INPUT}"
fi

# ---------------------------
# Derive task name
# ---------------------------

if [[ -f "${INPUT}" ]]; then
  TASK_NAME=$(basename "${INPUT}" .ext4 | sed 's/^rootfs-//')
else
  TASK_NAME=$(basename "${INPUT}")
fi

# ---------------------------
# Determine output path and results directory
# ---------------------------

if [[ "${RESUME}" == "true" ]]; then
  if [[ -n "${OUTPUT_EXPLICIT}" ]]; then
    OUTPUT="${OUTPUT_EXPLICIT}"
    [[ -f "${OUTPUT}" ]] || die "Resume file not found: ${OUTPUT}"
  else
    # Find the most recent binary_search.json for this task/hypervisor/label
    RESUME_SEARCH_DIR="${HOME}/results/${TASK_NAME}/${HYPERVISOR}/${LABEL}"
    OUTPUT=$(find "${RESUME_SEARCH_DIR}" -name "binary_search.json" -type f 2>/dev/null \
      | sort | tail -1 || true)
    [[ -n "${OUTPUT}" ]] || die "Resume requested but no binary_search.json found in ${RESUME_SEARCH_DIR}/"
  fi
  RESULTS_DIR="$(dirname "${OUTPUT}")"
  log "Resuming from: ${OUTPUT}"
else
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  RESULTS_DIR="${HOME}/results/${TASK_NAME}/${HYPERVISOR}/${LABEL}/${TIMESTAMP}"
  mkdir -p "${RESULTS_DIR}"
  OUTPUT="${OUTPUT_EXPLICIT:-${RESULTS_DIR}/binary_search.json}"
  log "Results will be written to: ${OUTPUT}"
fi

# ---------------------------
# Machine info
# ---------------------------

MACHINE_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
MACHINE_CPUS=$(nproc 2>/dev/null || echo "0")
MACHINE_CORES=$(lscpu 2>/dev/null | awk '/^Core\(s\) per socket:/ {print $NF}' || echo "0")
MACHINE_SOCKETS=$(lscpu 2>/dev/null | awk '/^Socket\(s\):/ {print $NF}' || echo "0")
MACHINE_MEM_TOTAL=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
PHYSICAL_CORES=$(( MACHINE_CORES * MACHINE_SOCKETS ))

log "Machine: ${MACHINE_HOSTNAME} | ${MACHINE_CPUS} logical CPUs | ${PHYSICAL_CORES} physical cores | ${MACHINE_MEM_TOTAL}MB RAM"

# ---------------------------
# Resolve source rootfs (build once from task dir if needed)
# ---------------------------

if [[ -d "${INPUT}" ]]; then
  log "Building rootfs from task directory (once for all probes)"
  PROBE_INPUT="${WORKDIR}/rootfs-bsearch-source.ext4"
  "${HV_SCRIPT_DIR}/prepare_task_rootfs.sh" "${INPUT}" "${PROBE_INPUT}"
else
  PROBE_INPUT="${INPUT}"
fi

[[ -f "${PROBE_INPUT}" ]] || die "Source rootfs not found: ${PROBE_INPUT}"

# ---------------------------
# Compute initial upper bound (hi)
# ---------------------------

AVAIL_RAM_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
RAM_LIMIT=$(( AVAIL_RAM_MB / VM_RAM_MB ))

ROOTFS_SIZE_KB=$(du -k "${PROBE_INPUT}" | awk '{print $1}')
ROOTFS_SIZE_MB=$(( (ROOTFS_SIZE_KB + 1023) / 1024 ))
AVAIL_DISK_KB=$(df -k "$(dirname "${PROBE_INPUT}")" | awk 'NR==2{print $4}')
AVAIL_DISK_MB=$(( AVAIL_DISK_KB / 1024 ))
DISK_LIMIT=$(( ROOTFS_SIZE_MB > 0 ? AVAIL_DISK_MB / ROOTFS_SIZE_MB : 9999 ))

AUTO_HI=$(( RAM_LIMIT < DISK_LIMIT ? RAM_LIMIT : DISK_LIMIT ))

if [[ -n "${MAX_VMS_OVERRIDE}" ]]; then
  INIT_HI="${MAX_VMS_OVERRIDE}"
  log "Upper bound: ${INIT_HI} VMs (user override)"
else
  INIT_HI="${AUTO_HI}"
  log "Upper bound: ${INIT_HI} VMs (RAM allows ~${RAM_LIMIT}, disk allows ~${DISK_LIMIT})"
fi

[[ "${INIT_HI}" -ge 2 ]] || die "Upper bound (${INIT_HI}) is too low — not enough RAM or disk for even 2 VMs"

# ---------------------------
# Detect default interface for ARP check
# ---------------------------

DEFAULT_IFACE="$(ip route list default | awk '{print $5; exit}' || true)"
[[ -n "${DEFAULT_IFACE}" ]] || die "Could not detect default network interface"

# ---------------------------
# One-time ARP safety check (CloudLab guard)
# All probes skip this via SKIP_ARP_CHECK=1
# ---------------------------

log "ARP safety check on ${DEFAULT_IFACE} (runs once, not per probe)"
echo "  Verifying 192.168.0.0/16 is not active on the public interface..."

if ip addr show "${DEFAULT_IFACE}" | grep -qE "192\.168\."; then
  die "CLOUDLAB SAFETY: 192.168.x.x address found on ${DEFAULT_IFACE}. IP conflict risk — aborting."
fi

if timeout 5 tcpdump -n -c 1 -i "${DEFAULT_IFACE}" "arp and net 192.168.0.0/16" 2>/dev/null; then
  die "CLOUDLAB SAFETY: ARP for 192.168.x.x seen on ${DEFAULT_IFACE}. This is dangerous on CloudLab!"
fi

echo "  ARP check passed — safe to proceed"

# ---------------------------
# Temp files
# ---------------------------

TMP_PROBE=$(mktemp /tmp/bsearch-probe-XXXXXX.json)
ALL_PROBES_FILE=$(mktemp /tmp/bsearch-all-probes-XXXXXX.jsonl)
trap "rm -f '${TMP_PROBE}' '${ALL_PROBES_FILE}'" EXIT

# ---------------------------
# Binary search state
# ---------------------------

LO=1
HI="${INIT_HI}"
PROBE_ITERATION=0
GOT_FAILURE=false
BASELINE_DONE=false

# Cache of already-completed vm_counts from a prior run (resume mode).
# Key = vm_count, value = "true" (all repeats stable) or "false" (any repeat failed).
declare -A CACHED_VM_STABLE

# ---------------------------
# Resume: load existing probes, reconstruct lo/hi, seed ALL_PROBES_FILE
# ---------------------------

if [[ "${RESUME}" == "true" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    log "WARNING: jq not found — resume disabled, starting fresh"
    RESUME=false
  else
    log "Loading existing probes from ${OUTPUT}"

    # Seed ALL_PROBES_FILE with the existing probe entries
    jq -c '.probes[]' "${OUTPUT}" >> "${ALL_PROBES_FILE}" 2>/dev/null || true

    # Count how many probe entries were loaded
    EXISTING_COUNT=$(wc -l < "${ALL_PROBES_FILE}" || echo 0)
    log "Loaded ${EXISTING_COUNT} existing probe entries"

    # Check if baseline was already completed
    baseline_count=$(jq '[.probes[] | select(.is_baseline == true)] | length' \
      "${OUTPUT}" 2>/dev/null || echo "0")
    [[ "${baseline_count}" -gt 0 ]] && BASELINE_DONE=true

    # Reconstruct lo and hi by replaying each binary search step.
    # Group non-baseline probes by vm_count. If any repeat failed at that
    # vm_count, the step is unstable (hi = vm_count). Otherwise stable (lo = vm_count).
    while IFS=$'\t' read -r vm_count any_failed; do
      if [[ "${any_failed}" == "false" ]]; then
        CACHED_VM_STABLE["${vm_count}"]="true"
        [[ "${vm_count}" -gt "${LO}" ]] && LO="${vm_count}"
      else
        CACHED_VM_STABLE["${vm_count}"]="false"
        [[ "${vm_count}" -lt "${HI}" ]] && HI="${vm_count}"
        GOT_FAILURE=true
      fi
    done < <(jq -r '
      .probes
      | map(select(.is_baseline == false))
      | group_by(.vm_count)
      | map({
          vm_count: .[0].vm_count,
          any_failed: (map(.stable) | any(. == false))
        })
      | .[]
      | [.vm_count, (.any_failed | tostring)]
      | @tsv
    ' "${OUTPUT}" 2>/dev/null || true)

    # Recover PROBE_ITERATION from the highest iteration already recorded
    PROBE_ITERATION=$(jq '[.probes[].iteration] | max // 0' "${OUTPUT}" 2>/dev/null || echo "0")

    log "Resumed state: lo=${LO}, hi=${HI}, baseline_done=${BASELINE_DONE}, cached_counts=${#CACHED_VM_STABLE[@]}"
  fi
fi

# ---------------------------
# run_probe <vm_count> <is_baseline> <repeat_num> <total_repeats>
#
# Calls run_parallel.sh with SKIP_ARP_CHECK=1 and appends one JSON line to
# ALL_PROBES_FILE. Returns 0 if all VMs completed successfully, 1 otherwise.
# ---------------------------

run_probe() {
  local vm_count="$1"
  local is_baseline="$2"
  local repeat_num="$3"
  local total_repeats="$4"
  PROBE_ITERATION=$(( PROBE_ITERATION + 1 ))

  local lo_now="${LO}"
  local hi_now="${HI}"

  log "========================================"
  log "PROBE #${PROBE_ITERATION}: ${vm_count} VMs  repeat=${repeat_num}/${total_repeats}  (lo=${lo_now}, hi=${hi_now})"
  log "========================================"

  local probe_start exit_code=0
  probe_start=$(date +%s)

  SKIP_ARP_CHECK=1 \
    "${PARALLEL_SH}" "${PROBE_INPUT}" "${vm_count}" "${TMP_PROBE}" \
    || exit_code=$?

  local probe_end wall_clock
  probe_end=$(date +%s)
  wall_clock=$(( probe_end - probe_start ))

  local stable="false"
  local completed=0
  local timing_json="null"

  if [[ -f "${TMP_PROBE}" ]]; then
    completed=$(grep -oP '"completed":\s*\K\d+' "${TMP_PROBE}" 2>/dev/null || echo "0")
    if [[ "${exit_code}" -eq 0 ]] && [[ "${completed}" -eq "${vm_count}" ]]; then
      stable="true"
    fi
    if grep -q "timing_summary" "${TMP_PROBE}" 2>/dev/null; then
      if command -v jq >/dev/null 2>&1; then
        timing_json=$(jq '.timing_summary // null' "${TMP_PROBE}" 2>/dev/null || echo "null")
      fi
    fi
  fi

  local timestamp
  timestamp=$(date -Iseconds)

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --argjson iteration    "${PROBE_ITERATION}" \
      --argjson vm_count     "${vm_count}" \
      --argjson lo           "${lo_now}" \
      --argjson hi           "${hi_now}" \
      --argjson stable       "${stable}" \
      --argjson exit_code    "${exit_code}" \
      --argjson completed    "${completed}" \
      --argjson total        "${vm_count}" \
      --argjson wall_clock   "${wall_clock}" \
      --argjson is_baseline  "${is_baseline}" \
      --argjson repeat_num   "${repeat_num}" \
      --argjson total_reps   "${total_repeats}" \
      --argjson timing       "${timing_json}" \
      --arg     timestamp    "${timestamp}" \
      '{
        iteration:          $iteration,
        vm_count:           $vm_count,
        repeat:             $repeat_num,
        total_repeats:      $total_reps,
        lo_before:          $lo,
        hi_before:          $hi,
        stable:             $stable,
        exit_code:          $exit_code,
        completed:          $completed,
        total:              $total,
        wall_clock_seconds: $wall_clock,
        is_baseline:        $is_baseline,
        timing_summary:     $timing,
        timestamp:          $timestamp
      }' >> "${ALL_PROBES_FILE}" 2>/dev/null || true
  else
    echo "{\"iteration\": ${PROBE_ITERATION}, \"vm_count\": ${vm_count}, \"repeat\": ${repeat_num}, \"total_repeats\": ${total_repeats}, \"lo_before\": ${lo_now}, \"hi_before\": ${hi_now}, \"stable\": ${stable}, \"exit_code\": ${exit_code}, \"completed\": ${completed}, \"total\": ${vm_count}, \"wall_clock_seconds\": ${wall_clock}, \"is_baseline\": ${is_baseline}, \"timestamp\": \"${timestamp}\"}" \
      >> "${ALL_PROBES_FILE}"
  fi

  if [[ "${stable}" == "true" ]]; then
    echo "  Result: STABLE  (${completed}/${vm_count} completed in ${wall_clock}s)"
    return 0
  else
    echo "  Result: UNSTABLE  (${completed}/${vm_count} completed, exit_code=${exit_code})"
    return 1
  fi
}

# ---------------------------
# run_probe_with_repeats <vm_count>
#
# Runs run_probe REPEATS times for a binary search step. Fails fast on the
# first unstable repeat. Returns 0 only if all repeats pass.
# ---------------------------

run_probe_with_repeats() {
  local vm_count="$1"
  local all_stable=true

  for repeat in $(seq 1 "${REPEATS}"); do
    between_probes "${vm_count}"
    if ! run_probe "${vm_count}" "false" "${repeat}" "${REPEATS}"; then
      all_stable=false
      break
    fi
  done

  [[ "${all_stable}" == "true" ]]
}

# ---------------------------
# between_probes <next_vm_count>
#
# Kill stray hypervisor processes, wait for memory reclaim, then cooldown.
# Called before every run_parallel.sh invocation except the baseline.
# ---------------------------

between_probes() {
  local next_n="${1:-0}"

  pkill -9 "${HV_BIN}" 2>/dev/null || true
  sleep 2

  if [[ "${next_n}" -gt 0 ]]; then
    local need_mb=$(( next_n * VM_RAM_MB ))
    for _attempt in $(seq 1 6); do
      local avail
      avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
      if [[ "${avail}" -ge "${need_mb}" ]]; then break; fi
      log "Waiting for memory reclaim (have ${avail}MB, need ${need_mb}MB)..."
      sleep 5
    done
  fi

  if [[ "${COOLDOWN}" -gt 0 ]]; then
    log "Cooldown: ${COOLDOWN}s"
    sleep "${COOLDOWN}"
  fi
}

# ---------------------------
# Baseline: verify N=1 works and capture timing reference
# ---------------------------

SEARCH_START=$(date +%s)

if [[ "${BASELINE_DONE}" == "true" ]]; then
  log "BASELINE: N=1 (skipping — already completed in prior run)"
else
  log "BASELINE: N=1"
  if ! run_probe 1 "true" 1 1; then
    die "Baseline at N=1 failed. Cannot run even a single VM. Aborting."
  fi
fi

# ---------------------------
# Binary search
# lo = max verified-stable count  (starts at 1)
# hi = first known-unstable count (starts at INIT_HI)
# Loop terminates when hi - lo == 1; lo is the answer.
# ---------------------------

log "Starting binary search: lo=${LO}, hi=${HI}, repeats_per_probe=${REPEATS}"

while (( HI - LO > 1 )); do
  MID=$(( (LO + HI) / 2 ))

  if [[ -n "${CACHED_VM_STABLE[${MID}]+_}" ]]; then
    # This vm_count was already probed in a prior run — use cached result
    cached_stable="${CACHED_VM_STABLE[${MID}]}"
    log "RESUME: N=${MID} already in cache (stable=${cached_stable}), skipping probe"
    if [[ "${cached_stable}" == "true" ]]; then
      LO="${MID}"
    else
      HI="${MID}"
      GOT_FAILURE=true
    fi
  else
    if run_probe_with_repeats "${MID}"; then
      LO="${MID}"
    else
      HI="${MID}"
      GOT_FAILURE=true
    fi
  fi
done

SEARCH_END=$(date +%s)
SEARCH_WALL=$(( SEARCH_END - SEARCH_START ))
MAX_STABLE_VMS="${LO}"

# ---------------------------
# Assemble output JSON
# ---------------------------

log "Writing results to ${OUTPUT}"

if command -v jq >/dev/null 2>&1; then
  RUNS_TMP=$(mktemp /tmp/bsearch-runs-XXXXXX.json)
  jq -s '.' "${ALL_PROBES_FILE}" > "${RUNS_TMP}" 2>/dev/null || echo "[]" > "${RUNS_TMP}"

  jq -n \
    --arg     task             "${INPUT}" \
    --arg     hypervisor       "${HYPERVISOR}" \
    --arg     label            "${LABEL}" \
    --arg     hostname         "${MACHINE_HOSTNAME}" \
    --argjson logical_cpus     "${MACHINE_CPUS}" \
    --argjson physical_cores   "${PHYSICAL_CORES}" \
    --argjson total_mem_mb     "${MACHINE_MEM_TOTAL}" \
    --argjson vm_ram_mb        "${VM_RAM_MB}" \
    --argjson repeats_per_probe "${REPEATS}" \
    --argjson lo_initial       1 \
    --argjson hi_initial       "${INIT_HI}" \
    --argjson max_stable       "${MAX_STABLE_VMS}" \
    --argjson got_failure      "${GOT_FAILURE}" \
    --argjson total_wall       "${SEARCH_WALL}" \
    --argjson total_probes     "${PROBE_ITERATION}" \
    --slurpfile probes         "${RUNS_TMP}" \
    '{
      task:               $task,
      hypervisor:         $hypervisor,
      label:              $label,
      machine: {
        hostname:         $hostname,
        logical_cpus:     $logical_cpus,
        physical_cores:   $physical_cores,
        total_mem_mb:     $total_mem_mb
      },
      vm_ram_mb:          $vm_ram_mb,
      repeats_per_probe:  $repeats_per_probe,
      search_bounds: {
        lo_initial:       $lo_initial,
        hi_initial:       $hi_initial
      },
      max_stable_vms:     $max_stable,
      ceiling_found:      $got_failure,
      total_probes:       $total_probes,
      total_wall_clock_seconds: $total_wall,
      probes:             $probes[0]
    }' > "${OUTPUT}"

  rm -f "${RUNS_TMP}"
else
  # Fallback: assemble JSON without jq
  {
    echo "{"
    echo "  \"task\": \"${INPUT}\","
    echo "  \"hypervisor\": \"${HYPERVISOR}\","
    echo "  \"label\": \"${LABEL}\","
    echo "  \"machine\": {\"hostname\": \"${MACHINE_HOSTNAME}\", \"logical_cpus\": ${MACHINE_CPUS}, \"physical_cores\": ${PHYSICAL_CORES}, \"total_mem_mb\": ${MACHINE_MEM_TOTAL}},"
    echo "  \"vm_ram_mb\": ${VM_RAM_MB},"
    echo "  \"repeats_per_probe\": ${REPEATS},"
    echo "  \"search_bounds\": {\"lo_initial\": 1, \"hi_initial\": ${INIT_HI}},"
    echo "  \"max_stable_vms\": ${MAX_STABLE_VMS},"
    echo "  \"ceiling_found\": ${GOT_FAILURE},"
    echo "  \"total_probes\": ${PROBE_ITERATION},"
    echo "  \"total_wall_clock_seconds\": ${SEARCH_WALL},"
    echo "  \"probes\": ["
    first=true
    while IFS= read -r line; do
      if [[ "${first}" == "true" ]]; then
        echo "    ${line}"
        first=false
      else
        echo "    ,${line}"
      fi
    done < "${ALL_PROBES_FILE}"
    echo "  ]"
    echo "}"
  } > "${OUTPUT}"
fi

# ---------------------------
# Final report
# ---------------------------

echo ""
echo "========================================"
echo "BINARY SEARCH COMPLETE"
echo "========================================"
echo "  Task:              ${INPUT}"
echo "  Hypervisor:        ${HYPERVISOR}"
echo "  Label:             ${LABEL}"
echo "  Search range:      1 .. ${INIT_HI}"
echo "  Repeats per probe: ${REPEATS}"
echo "  Total probes:      ${PROBE_ITERATION}"
echo "  Max stable VMs:    ${MAX_STABLE_VMS}"
if [[ "${GOT_FAILURE}" == "false" ]]; then
  echo ""
  echo "  WARNING: No failures found within range [1, ${INIT_HI}]."
  echo "  The true crash limit may be higher than ${INIT_HI}."
  echo "  Re-run with --max-vms <larger_value> to find it."
fi
echo "  Total wall time:   ${SEARCH_WALL}s"
echo "  Results:           ${OUTPUT}"
echo "========================================"

exit 0
