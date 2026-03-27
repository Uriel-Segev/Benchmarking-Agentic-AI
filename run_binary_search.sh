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
#   --resume              resume the most recent in-progress run for this
#                         task/hypervisor/label, or from --output if specified
#   --max-vms <n>         override upper bound (default: auto from RAM + disk)
#   --vm-ram <mb>         RAM per VM in MB; skips auto-profiling (default: auto-profiled)
#   --cooldown <s>        seconds to wait between every run_parallel.sh call (default: 10)
#   --output <dir>        override output directory (also used as resume source)
#
# Results saved to:
#   ~/results/<task>/<hypervisor>/<label>/<timestamp>/
#     summary.json           top-level metadata, updated after every probe
#     probes/
#       probe_001_n064_r1.json
#       probe_002_n128_r1.json
#       ...
#     diagnosis/
#       probe_001_n064/
#         dmesg.txt  memory.txt  ...
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
VM_RAM_EXPLICIT=false

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
    --vm-ram)     VM_RAM_MB="$2"; VM_RAM_EXPLICIT=true; shift 2 ;;
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
    WORKDIR="${WORKDIR:-/mydata/firecracker}"
    HV_BIN="firecracker"
    ;;
  cloud-hypervisor)
    HV_SCRIPT_DIR="${SCRIPT_DIR}/cloud-hypervisor/scripts"
    WORKDIR="${WORKDIR:-/mydata/cloud-hypervisor}"
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
    RESULTS_DIR="${OUTPUT_EXPLICIT}"
    [[ -d "${RESULTS_DIR}" ]] || die "Resume directory not found: ${RESULTS_DIR}"
    [[ -f "${RESULTS_DIR}/summary.json" ]] || die "No summary.json in: ${RESULTS_DIR}"
  else
    # Find the most recent in-progress run for this task/hypervisor/label
    RESUME_SEARCH_DIR="${HOME}/results/${TASK_NAME}/${HYPERVISOR}/${LABEL}"
    RESULTS_DIR=$(find "${RESUME_SEARCH_DIR}" -name "summary.json" -type f 2>/dev/null \
      | xargs grep -l '"in_progress"' 2>/dev/null \
      | xargs -I{} dirname {} 2>/dev/null \
      | sort | tail -1 || true)
    [[ -n "${RESULTS_DIR}" ]] || die "No in-progress run found in ${RESUME_SEARCH_DIR}/. Use --output <dir> to specify explicitly."
  fi
  log "Resuming from: ${RESULTS_DIR}/"
else
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  RESULTS_DIR="${OUTPUT_EXPLICIT:-${HOME}/results/${TASK_NAME}/${HYPERVISOR}/${LABEL}/${TIMESTAMP}}"
  mkdir -p "${RESULTS_DIR}"
  log "Results will be written to: ${RESULTS_DIR}/"
fi

PROBES_DIR="${RESULTS_DIR}/probes"
mkdir -p "${PROBES_DIR}"
SUMMARY_FILE="${RESULTS_DIR}/summary.json"

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

ROOTFS_SIZE_KB=$(du -k "${PROBE_INPUT}" | awk '{print $1}')
ROOTFS_SIZE_MB=$(( (ROOTFS_SIZE_KB + 1023) / 1024 ))
AVAIL_DISK_KB=$(df -k "$(dirname "${PROBE_INPUT}")" | awk 'NR==2{print $4}')
AVAIL_DISK_MB=$(( AVAIL_DISK_KB / 1024 ))
DISK_LIMIT=$(( ROOTFS_SIZE_MB > 0 ? AVAIL_DISK_MB / ROOTFS_SIZE_MB : 9999 ))

if [[ -n "${MAX_VMS_OVERRIDE}" ]]; then
  INIT_HI="${MAX_VMS_OVERRIDE}"
  log "Upper bound: ${INIT_HI} VMs (user override)"
else
  INIT_HI="${DISK_LIMIT}"
  log "Upper bound: ${INIT_HI} VMs (disk allows ~${DISK_LIMIT}; RAM limit removed — binary search finds the real crash point)"
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
trap "rm -f '${TMP_PROBE}'" EXIT

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
# Resume: load existing probes from probes/ dir, reconstruct lo/hi
# ---------------------------

if [[ "${RESUME}" == "true" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    log "WARNING: jq not found — resume disabled, starting fresh"
    RESUME=false
  else
    log "Scanning probe files from ${PROBES_DIR}/"

    # Two associative arrays to track per-vm_count stability across repeats:
    #   _rvm_seen[N]=1          — vm_count N was probed at least once
    #   _rvm_any_failed[N]=1    — at least one repeat for vm_count N failed
    declare -A _rvm_seen _rvm_any_failed

    for probe_file in $(ls -v "${PROBES_DIR}"/probe_*.json 2>/dev/null || true); do
      [[ -f "${probe_file}" ]] || continue

      _p_iter=$(jq -r '.iteration'   "${probe_file}" 2>/dev/null || echo "0")
      _p_vmc=$(jq -r  '.vm_count'   "${probe_file}" 2>/dev/null || echo "0")
      _p_stable=$(jq -r '.stable'   "${probe_file}" 2>/dev/null || echo "false")
      _p_base=$(jq -r  '.is_baseline' "${probe_file}" 2>/dev/null || echo "false")

      [[ "${_p_iter}" -gt "${PROBE_ITERATION}" ]] && PROBE_ITERATION="${_p_iter}"
      [[ "${_p_base}" == "true" ]] && BASELINE_DONE=true

      if [[ "${_p_base}" == "false" ]]; then
        _rvm_seen["${_p_vmc}"]=1
        [[ "${_p_stable}" == "false" ]] && _rvm_any_failed["${_p_vmc}"]=1
      fi
    done

    # Reconstruct lo/hi from per-vm_count stability
    for _p_vmc in "${!_rvm_seen[@]}"; do
      if [[ -n "${_rvm_any_failed[${_p_vmc}]+_}" ]]; then
        CACHED_VM_STABLE["${_p_vmc}"]="false"
        [[ "${_p_vmc}" -lt "${HI}" ]] && HI="${_p_vmc}"
        GOT_FAILURE=true
      else
        CACHED_VM_STABLE["${_p_vmc}"]="true"
        [[ "${_p_vmc}" -gt "${LO}" ]] && LO="${_p_vmc}"
      fi
    done

    _existing_count=$(ls "${PROBES_DIR}"/probe_*.json 2>/dev/null | wc -l || echo 0)
    log "Loaded ${_existing_count} probe files"
    log "Resumed state: lo=${LO}, hi=${HI}, baseline_done=${BASELINE_DONE}, cached_counts=${#CACHED_VM_STABLE[@]}"
  fi
fi

# ---------------------------
# System snapshot + failure diagnosis helpers
# ---------------------------

_avail_ram_mb() {
  awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0"
}

# _capture_probe_diagnosis <probe_iter> <vm_count> <completed> <exit_code> <wall_clock> [inst_log_dir]
# Saves dmesg, memory, fd, tap stats + instance logs to RESULTS_DIR/diagnosis/.
# Classifies failure into one of:
#   host_oom         — host OOM killer fired (dmesg OOM or SIGKILL exit 137)
#   guest_oom        — guest-side OOM (FC exited cleanly, OOM in guest log)
#   vmm_crash        — VMM crashed for non-OOM reason (e.g. SIGPIPE / exit 141)
#   timeout          — VMs exceeded TASK_TIMEOUT
#   fd_exhaustion    — host file descriptor limit hit
#   mmap_limit       — mmap / max_map_count limit hit
#   partial_completion — some VMs succeeded, some failed
#   unknown          — no clear signal
# Prints "reason|diag_dir" on stdout.
_capture_probe_diagnosis() {
  local probe_iter="$1"
  local vm_count="$2"
  local completed="$3"
  local exit_code="$4"
  local wall_clock="$5"
  local inst_log_dir="${6:-}"

  local diag_dir="${RESULTS_DIR}/diagnosis/probe_${probe_iter}_n${vm_count}"
  mkdir -p "${diag_dir}"

  free -m                                  > "${diag_dir}/memory.txt"        2>/dev/null || true
  dmesg | tail -200                        > "${diag_dir}/dmesg.txt"         2>/dev/null || true
  cat /proc/sys/fs/file-nr                 > "${diag_dir}/file_nr.txt"       2>/dev/null || true
  cat /proc/sys/vm/max_map_count           > "${diag_dir}/max_map_count.txt" 2>/dev/null || true
  ip link show 2>/dev/null | grep -c "tap" > "${diag_dir}/tap_count.txt"     2>/dev/null || true

  if [[ -n "${inst_log_dir}" ]] && [[ -d "${inst_log_dir}" ]]; then
    cp -r "${inst_log_dir}" "${diag_dir}/instance_logs" 2>/dev/null || true
  fi

  local reason="unknown"

  # partial_completion: a mix of success and failure — not a hard crash
  if [[ "${completed}" -gt 0 ]] && [[ "${completed}" -lt "${vm_count}" ]]; then
    reason="partial_completion"

  # host_oom: OOM killer in dmesg, or any instance process was SIGKILLed (exit 137)
  elif grep -qi "out of memory\|oom.*kill\|killed process" "${diag_dir}/dmesg.txt" 2>/dev/null; then
    reason="host_oom"
  elif [[ -f "${TMP_PROBE}" ]] && command -v jq >/dev/null 2>&1 && \
       jq -e '[.instances[]?.exit_code] | any(. == 137)' "${TMP_PROBE}" >/dev/null 2>&1; then
    reason="host_oom"

  # timeout: instance logs show the timeout message from run_task.sh
  elif [[ -n "${inst_log_dir}" ]] && \
       grep -rql "Timeout reached" "${inst_log_dir}" 2>/dev/null; then
    reason="timeout"

  # fd_exhaustion: file descriptor limit hit
  elif grep -qi "file table overflow\|too many open files" "${diag_dir}/dmesg.txt" 2>/dev/null; then
    reason="fd_exhaustion"

  # mmap_limit: mmap or max_map_count failures
  elif grep -qi "mmap\|max_map_count\|cannot allocate memory" "${diag_dir}/dmesg.txt" 2>/dev/null || \
       { [[ -n "${inst_log_dir}" ]] && grep -rql "mmap\|Cannot allocate" "${inst_log_dir}" 2>/dev/null; }; then
    reason="mmap_limit"

  # guest_oom: OOM inside the guest (FC process exited cleanly, OOM in guest logs)
  elif [[ -n "${inst_log_dir}" ]] && \
       grep -rql "out of memory\|oom-kill\|Killed" "${inst_log_dir}" 2>/dev/null; then
    reason="guest_oom"

  # vmm_crash: VMM exited non-zero with no other explanation (e.g. SIGPIPE / exit 141)
  elif [[ "${exit_code}" -ne 0 ]]; then
    reason="vmm_crash"
  fi

  log "Diagnosis saved: ${diag_dir}  reason=${reason}"
  echo "${reason}|${diag_dir}"
}

# _profile_vm_ram
# Launches up to 16 VMs through the task, samples Firecracker process RSS and
# MemAvailable during the run, then sets VM_RAM_MB = ceil((peak_rss + kernel_overhead) * 1.2).
# Falls back to the current VM_RAM_MB on any error.
_profile_vm_ram() {
  local profile_n=16

  # Scale down if current RAM limit × N would exceed available memory
  local avail
  avail=$(_avail_ram_mb)
  while [[ "${profile_n}" -gt 1 ]] && [[ $(( profile_n * VM_RAM_MB )) -gt "${avail}" ]]; do
    profile_n=$(( profile_n / 2 ))
  done

  log "RAM PROFILING: launching ${profile_n} VM(s) to measure actual per-VM memory usage"
  log "  (current limit: ${VM_RAM_MB}MB — measures real working set, then right-sizes)"

  local profile_output profile_log
  profile_output=$(mktemp /tmp/bsearch-profile-XXXXXX.json)
  profile_log="${RESULTS_DIR}/profile_ram.log"

  local mem_before mem_available_min
  mem_before=$(_avail_ram_mb)
  mem_available_min="${mem_before}"

  # Launch profiling run, suppress console output
  SKIP_ARP_CHECK=1 WORKDIR="${WORKDIR}" MEM_SIZE_MIB="${VM_RAM_MB}" \
    "${PARALLEL_SH}" "${PROBE_INPUT}" "${profile_n}" "${profile_output}" \
    >"${profile_log}" 2>&1 &
  local parallel_pid=$!

  # Sample RSS of all hypervisor processes while they run
  local peak_total_rss_kb=0 sample_count=0
  while kill -0 "${parallel_pid}" 2>/dev/null; do
    local total_rss_kb=0 pid
    while IFS= read -r pid; do
      [[ -z "${pid}" ]] && continue
      local rss
      rss=$(awk '/^VmRSS:/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null || echo "0")
      total_rss_kb=$(( total_rss_kb + rss ))
    done < <(pgrep -f "${HV_BIN}" 2>/dev/null || true)
    [[ "${total_rss_kb}" -gt "${peak_total_rss_kb}" ]] && peak_total_rss_kb="${total_rss_kb}"

    local avail_now
    avail_now=$(_avail_ram_mb)
    [[ "${avail_now}" -lt "${mem_available_min}" ]] && mem_available_min="${avail_now}"

    sample_count=$(( sample_count + 1 ))
    sleep 0.5
  done

  local profile_exit=0
  wait "${parallel_pid}" || profile_exit=$?
  rm -f "${profile_output}"

  # If the profiling run exited non-zero, save instance logs for diagnosis.
  # This does NOT automatically abort — we first check if RSS samples were collected.
  # The most common cause is post-VM mount failures in run_task.sh (exit 32), which
  # happen AFTER the VMs have already run and RSS was sampled, so the data is valid.
  if [[ "${profile_exit}" -ne 0 ]]; then
    log "WARNING: profiling run exited with code ${profile_exit} — checking if RSS samples are usable"
    log "  See ${profile_log} for details"
    local _inst_log_dir
    _inst_log_dir=$(grep 'Instance logs:' "${profile_log}" 2>/dev/null \
      | tail -1 | sed 's/.*Instance logs: *//' | tr -d '[:space:]' || true)
    if [[ -n "${_inst_log_dir}" ]] && [[ -d "${_inst_log_dir}" ]]; then
      local _saved="${RESULTS_DIR}/profile_ram_instance_logs"
      cp -r "${_inst_log_dir}" "${_saved}" 2>/dev/null || true
      log "  Profiling instance logs saved to: ${_saved}"
    fi
  fi

  # If we collected no RSS samples at all, the VMs never started — fatal.
  # (Don't silently fall back to the default; that ruins the whole benchmark run.)
  if [[ "${sample_count}" -eq 0 ]] || [[ "${peak_total_rss_kb}" -eq 0 ]]; then
    die "RAM profiling collected no RSS data (${sample_count} samples, peak=${peak_total_rss_kb}KB). VMs may not have started. See ${profile_log}. Use --vm-ram <mb> to skip profiling."
  fi

  if [[ "${profile_exit}" -ne 0 ]]; then
    log "NOTE: RSS data is valid (${sample_count} samples captured while VMs ran). Proceeding with measured values."
  fi

  # Convert peak total RSS to MB (ceiling division)
  local peak_total_rss_mb=$(( (peak_total_rss_kb + 1023) / 1024 ))
  local peak_rss_per_vm=$(( peak_total_rss_mb / profile_n ))
  [[ "${peak_rss_per_vm}" -eq 0 ]] && peak_rss_per_vm=1

  # Kernel overhead per VM: total MemAvailable drop minus FC process RSS, divided by N
  local total_mem_used=$(( mem_before - mem_available_min ))
  local kernel_overhead_total=$(( total_mem_used - peak_total_rss_mb ))
  [[ "${kernel_overhead_total}" -lt 0 ]] && kernel_overhead_total=0
  local kernel_overhead_per_vm=$(( kernel_overhead_total / profile_n ))

  # allocation = (peak_rss + kernel_overhead) * 1.2
  local computed_mb=$(( (peak_rss_per_vm + kernel_overhead_per_vm) * 6 / 5 ))

  log "RAM profiling results:"
  log "  VMs profiled:       ${profile_n}"
  log "  Peak RSS per VM:    ${peak_rss_per_vm}MB"
  log "  Kernel overhead/VM: ${kernel_overhead_per_vm}MB"
  log "  Allocated per VM:   ${computed_mb}MB  (x1.2 margin)"

  VM_RAM_MB="${computed_mb}"
  export VM_RAM_MB
}

# ---------------------------
# _save_summary <status>
#
# Atomically writes RESULTS_DIR/summary.json with current search state.
# <status> is "in_progress" or "completed".
# Uses write-to-tmp + mv so a crash mid-write never corrupts the file.
# ---------------------------

_save_summary() {
  local status="$1"
  local tmp
  tmp=$(mktemp "${RESULTS_DIR}/.summary-XXXXXX.tmp")

  local max_stable_json="null" ceiling_json="null" wall_json="null"
  if [[ "${status}" == "completed" ]]; then
    max_stable_json="${MAX_STABLE_VMS}"
    ceiling_json="${GOT_FAILURE}"
    wall_json="${SEARCH_WALL}"
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg     status             "${status}" \
      --arg     task               "${INPUT}" \
      --arg     hypervisor         "${HYPERVISOR}" \
      --arg     label              "${LABEL}" \
      --arg     hostname           "${MACHINE_HOSTNAME}" \
      --argjson logical_cpus       "${MACHINE_CPUS}" \
      --argjson physical_cores     "${PHYSICAL_CORES}" \
      --argjson total_mem_mb       "${MACHINE_MEM_TOTAL}" \
      --argjson vm_ram_mb          "${VM_RAM_MB}" \
      --arg     vm_ram_mb_source   "${VM_RAM_MB_SOURCE}" \
      --argjson repeats_per_probe  "${REPEATS}" \
      --argjson lo_initial         1 \
      --argjson hi_initial         "${INIT_HI}" \
      --argjson lo_current         "${LO}" \
      --argjson hi_current         "${HI}" \
      --argjson total_probes       "${PROBE_ITERATION}" \
      --argjson max_stable_vms     "${max_stable_json}" \
      --argjson ceiling_found      "${ceiling_json}" \
      --argjson total_wall         "${wall_json}" \
      --arg     timestamp_updated  "$(date -Iseconds)" \
      '{
        status:                   $status,
        task:                     $task,
        hypervisor:               $hypervisor,
        label:                    $label,
        machine: {
          hostname:               $hostname,
          logical_cpus:           $logical_cpus,
          physical_cores:         $physical_cores,
          total_mem_mb:           $total_mem_mb
        },
        vm_ram_mb:                $vm_ram_mb,
        vm_ram_mb_source:         $vm_ram_mb_source,
        repeats_per_probe:        $repeats_per_probe,
        search_bounds: {
          lo_initial:             $lo_initial,
          hi_initial:             $hi_initial
        },
        lo_current:               $lo_current,
        hi_current:               $hi_current,
        total_probes:             $total_probes,
        max_stable_vms:           $max_stable_vms,
        ceiling_found:            $ceiling_found,
        total_wall_clock_seconds: $total_wall,
        timestamp_updated:        $timestamp_updated
      }' > "${tmp}" 2>/dev/null && mv "${tmp}" "${SUMMARY_FILE}" || rm -f "${tmp}"
  else
    {
      echo "{"
      echo "  \"status\": \"${status}\","
      echo "  \"task\": \"${INPUT}\","
      echo "  \"hypervisor\": \"${HYPERVISOR}\","
      echo "  \"label\": \"${LABEL}\","
      echo "  \"vm_ram_mb\": ${VM_RAM_MB},"
      echo "  \"lo_current\": ${LO},"
      echo "  \"hi_current\": ${HI},"
      echo "  \"total_probes\": ${PROBE_ITERATION},"
      echo "  \"max_stable_vms\": ${max_stable_json},"
      echo "  \"ceiling_found\": ${ceiling_json}"
      echo "}"
    } > "${tmp}" && mv "${tmp}" "${SUMMARY_FILE}" || rm -f "${tmp}"
  fi
}

# ---------------------------
# run_probe <vm_count> <is_baseline> <repeat_num> <total_repeats>
#
# Calls run_parallel.sh with SKIP_ARP_CHECK=1, writes one probe JSON file to
# PROBES_DIR, updates summary.json, and returns 0 if stable, 1 otherwise.
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
  local avail_ram_before failure_reason diagnosis_dir
  avail_ram_before=$(_avail_ram_mb)
  failure_reason=""
  diagnosis_dir=""
  probe_start=$(date +%s)

  SKIP_ARP_CHECK=1 \
  WORKDIR="${WORKDIR}" \
  MEM_SIZE_MIB="${VM_RAM_MB}" \
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

  # Capture diagnosis and classify failure BEFORE writing probe JSON
  if [[ "${stable}" == "false" ]]; then
    local inst_log_dir=""
    if [[ -f "${TMP_PROBE}" ]] && command -v jq >/dev/null 2>&1; then
      inst_log_dir=$(jq -r '.instance_log_dir // ""' "${TMP_PROBE}" 2>/dev/null || echo "")
    fi
    local diag_result
    diag_result=$(_capture_probe_diagnosis \
      "${PROBE_ITERATION}" "${vm_count}" "${completed}" "${exit_code}" "${wall_clock}" "${inst_log_dir}")
    failure_reason="${diag_result%%|*}"
    diagnosis_dir="${diag_result##*|}"
  fi

  local timestamp
  timestamp=$(date -Iseconds)

  local probe_file
  probe_file="${PROBES_DIR}/probe_$(printf '%03d' "${PROBE_ITERATION}")_n$(printf '%04d' "${vm_count}")_r${repeat_num}.json"

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
      --argjson timing          "${timing_json}" \
      --argjson avail_ram_mb    "${avail_ram_before}" \
      --arg     failure_reason  "${failure_reason}" \
      --arg     diagnosis_dir   "${diagnosis_dir}" \
      --arg     timestamp       "${timestamp}" \
      '{
        iteration:           $iteration,
        vm_count:            $vm_count,
        repeat:              $repeat_num,
        total_repeats:       $total_reps,
        lo_before:           $lo,
        hi_before:           $hi,
        stable:              $stable,
        exit_code:           $exit_code,
        completed:           $completed,
        total:               $total,
        wall_clock_seconds:  $wall_clock,
        is_baseline:         $is_baseline,
        avail_ram_mb_before: $avail_ram_mb,
        failure_reason:      (if ($failure_reason | length) > 0 then $failure_reason else null end),
        diagnosis_dir:       (if ($diagnosis_dir | length) > 0 then $diagnosis_dir else null end),
        timing_summary:      $timing,
        timestamp:           $timestamp
      }' > "${probe_file}" 2>/dev/null || true
  else
    echo "{\"iteration\": ${PROBE_ITERATION}, \"vm_count\": ${vm_count}, \"repeat\": ${repeat_num}, \"total_repeats\": ${total_repeats}, \"lo_before\": ${lo_now}, \"hi_before\": ${hi_now}, \"stable\": ${stable}, \"exit_code\": ${exit_code}, \"completed\": ${completed}, \"total\": ${vm_count}, \"wall_clock_seconds\": ${wall_clock}, \"is_baseline\": ${is_baseline}, \"timestamp\": \"${timestamp}\"}" \
      > "${probe_file}"
  fi

  _save_summary "in_progress"

  if [[ "${stable}" == "true" ]]; then
    echo "  Result: STABLE  (${completed}/${vm_count} completed in ${wall_clock}s)"
    return 0
  else
    echo "  Result: UNSTABLE  (${completed}/${vm_count} completed, exit_code=${exit_code}, likely: ${failure_reason})"
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
# RAM profiling (skipped if --vm-ram was explicitly set, or if resuming)
# ---------------------------

VM_RAM_MB_SOURCE="default"
if [[ "${VM_RAM_EXPLICIT}" == "true" ]]; then
  VM_RAM_MB_SOURCE="user_specified"
  log "VM RAM: ${VM_RAM_MB}MB per VM (user-specified via --vm-ram)"
elif [[ "${RESUME}" == "false" ]]; then
  _profile_vm_ram
  between_probes 0
  VM_RAM_MB_SOURCE="profiled"
else
  VM_RAM_MB_SOURCE="default"
  log "VM RAM: ${VM_RAM_MB}MB per VM (resume mode — re-using prior allocation)"
fi

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
# Save completed summary
# ---------------------------

log "Saving final summary to ${SUMMARY_FILE}"
_save_summary "completed"

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
echo "  VM RAM:            ${VM_RAM_MB}MB per VM  (${VM_RAM_MB_SOURCE})"
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
echo "  Results dir:       ${RESULTS_DIR}/"
echo "  Summary:           ${SUMMARY_FILE}"
echo "  Probes:            ${PROBES_DIR}/"
echo "========================================"

exit 0
