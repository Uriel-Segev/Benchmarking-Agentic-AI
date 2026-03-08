#!/usr/bin/env bash
# =============================================================================
# Campaign runner: execute multiple binary search experiments sequentially
#
# Runs every (task × hypervisor) combination one at a time. Each run is
# self-contained under its own results directory:
#
#   ~/results/<task>/<hypervisor>/<label>/<timestamp>/
#     summary.json      machine info + search state + final result
#     run.log           full binary search stdout/stderr
#     probes/           one JSON per probe
#     diagnosis/        crash artifacts per failed probe
#
# Resume is automatic: rerun with the same args and completed runs are skipped,
# in-progress runs are resumed from where they left off.
#
# Usage:
#   sudo ./run_campaign.sh \
#     --task hello-world --task pytorch-model-recovery \
#     --hypervisor firecracker --hypervisor cloud-hypervisor \
#     --label 48c \
#     [--repeats <n>] [--cooldown <s>] [--between-runs <s>] \
#     [--max-vms <n>] [--vm-ram <mb>]
#
# Options:
#   --task <name>         task name under tasks/ (repeatable)
#   --hypervisor <hv>     firecracker or cloud-hypervisor (repeatable)
#   --label <name>        experiment label, e.g. "48c"
#   --repeats <n>         repeats per binary search probe (default: 3)
#   --cooldown <s>        cooldown between probes within a run (default: 10)
#   --between-runs <s>    cooldown between campaign runs (default: 60)
#   --max-vms <n>         upper bound override for binary search
#   --vm-ram <mb>         per-VM RAM in MB (skips auto-profiling)
#
# Runs are executed in order: task1/hv1, task1/hv2, task2/hv1, task2/hv2, ...
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BSEARCH="${SCRIPT_DIR}/run_binary_search.sh"

# ---------------------------
# Defaults
# ---------------------------

TASKS=()
HYPERVISORS=()
LABEL=""
REPEATS=3
COOLDOWN=10
BETWEEN_RUNS=60
MAX_VMS_ARG=""
VM_RAM_ARG=""

# ---------------------------
# Parse arguments
# ---------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)         TASKS+=("$2");       shift 2 ;;
    --hypervisor)   HYPERVISORS+=("$2"); shift 2 ;;
    --label)        LABEL="$2";          shift 2 ;;
    --repeats)      REPEATS="$2";        shift 2 ;;
    --cooldown)     COOLDOWN="$2";       shift 2 ;;
    --between-runs) BETWEEN_RUNS="$2";   shift 2 ;;
    --max-vms)      MAX_VMS_ARG="$2";    shift 2 ;;
    --vm-ram)       VM_RAM_ARG="$2";     shift 2 ;;
    -h|--help)
      sed -n '3,31p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------
# Validation
# ---------------------------

[[ "${EUID}" -eq 0 ]]            || { echo "ERROR: Run as root: sudo $0" >&2; exit 1; }
[[ -n "${LABEL}" ]]              || { echo "ERROR: --label is required" >&2; exit 1; }
[[ "${#TASKS[@]}" -gt 0 ]]       || { echo "ERROR: at least one --task is required" >&2; exit 1; }
[[ "${#HYPERVISORS[@]}" -gt 0 ]] || { echo "ERROR: at least one --hypervisor is required" >&2; exit 1; }
[[ -f "${BSEARCH}" ]]            || { echo "ERROR: run_binary_search.sh not found: ${BSEARCH}" >&2; exit 1; }

for hv in "${HYPERVISORS[@]}"; do
  case "${hv}" in
    firecracker|cloud-hypervisor) ;;
    *) echo "ERROR: Unknown hypervisor '${hv}'" >&2; exit 1 ;;
  esac
done

# ---------------------------
# Build run list: cartesian product of tasks × hypervisors
# ---------------------------

RUN_TASKS=()
RUN_HVS=()

for task in "${TASKS[@]}"; do
  for hv in "${HYPERVISORS[@]}"; do
    RUN_TASKS+=("${task}")
    RUN_HVS+=("${hv}")
  done
done

TOTAL_RUNS="${#RUN_TASKS[@]}"

# ---------------------------
# Helpers
# ---------------------------

log_event() {
  echo "[campaign $(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# _run_status <task> <hv>
# Returns the status from the most recent summary.json for this task/hv/label,
# and sets LATEST_RUN_DIR to that directory. Returns "none" if no run exists.
LATEST_RUN_DIR=""
_run_status() {
  local task="$1" hv="$2"
  LATEST_RUN_DIR=""

  local search_dir="${HOME}/results/${task}/${hv}/${LABEL}"
  local latest
  latest=$(find "${search_dir}" -name "summary.json" -type f 2>/dev/null \
    | xargs -I{} dirname {} 2>/dev/null \
    | sort | tail -1 || true)

  [[ -z "${latest}" ]] && echo "none" && return

  LATEST_RUN_DIR="${latest}"

  if command -v jq >/dev/null 2>&1; then
    jq -r '.status // "unknown"' "${latest}/summary.json" 2>/dev/null || echo "unknown"
  else
    grep -oP '"status":\s*"\K[^"]+' "${latest}/summary.json" 2>/dev/null || echo "unknown"
  fi
}

# _between_runs [next_task] [next_hv]
# Kill stray hypervisor processes, then cooldown before next run.
_between_runs() {
  local next_task="${1:-}"
  local next_hv="${2:-}"
  log_event "Between-run cleanup: killing stray processes, waiting ${BETWEEN_RUNS}s..."
  pkill -9 firecracker      2>/dev/null || true
  pkill -9 cloud-hypervisor 2>/dev/null || true
  sleep 2
  [[ "${BETWEEN_RUNS}" -gt 0 ]] && sleep "${BETWEEN_RUNS}"
  [[ -n "${next_task}" ]] && log_event "Next up: ${next_task} / ${next_hv}"
}

# ---------------------------
# Main loop
# ---------------------------

CAMPAIGN_START=$(date +%s)
log_event "Campaign: label=${LABEL}, repeats=${REPEATS}, probe_cooldown=${COOLDOWN}s, between_runs=${BETWEEN_RUNS}s"
log_event "Runs (${TOTAL_RUNS} total):"
for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
  log_event "  $((idx+1)). ${RUN_TASKS[${idx}]} / ${RUN_HVS[${idx}]}"
done

RUN_OUTCOMES=()   # one entry per run: "completed" | "failed" | "skipped"
RUN_DIRS=()       # results dir for each run

for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
  task="${RUN_TASKS[${idx}]}"
  hv="${RUN_HVS[${idx}]}"
  run_label="[$((idx+1))/${TOTAL_RUNS}] ${task} / ${hv}"

  task_dir="${SCRIPT_DIR}/tasks/${task}"
  if [[ ! -d "${task_dir}" ]]; then
    log_event "ERROR ${run_label}: task directory not found: ${task_dir}"
    RUN_OUTCOMES+=("failed")
    RUN_DIRS+=("")
    continue
  fi

  # Check existing run state from summary.json
  current_status=$(_run_status "${task}" "${hv}")

  bsearch_resume_flag=""
  results_dir=""

  case "${current_status}" in
    completed)
      log_event "SKIP ${run_label} — already completed: ${LATEST_RUN_DIR}/"
      RUN_OUTCOMES+=("skipped")
      RUN_DIRS+=("${LATEST_RUN_DIR}")
      continue
      ;;
    in_progress)
      log_event "RESUME ${run_label} from: ${LATEST_RUN_DIR}/"
      bsearch_resume_flag="--resume"
      results_dir="${LATEST_RUN_DIR}"
      ;;
    *)
      results_dir="${HOME}/results/${task}/${hv}/${LABEL}/$(date +%Y%m%d_%H%M%S)"
      log_event "START ${run_label}"
      mkdir -p "${results_dir}"
      ;;
  esac

  RUN_DIRS+=("${results_dir}")

  # Build run_binary_search.sh args
  bsearch_args=(
    "${task_dir}"
    --hypervisor "${hv}"
    --label      "${LABEL}"
    --repeats    "${REPEATS}"
    --cooldown   "${COOLDOWN}"
    --output     "${results_dir}"
  )
  [[ -n "${MAX_VMS_ARG}" ]]         && bsearch_args+=(--max-vms "${MAX_VMS_ARG}")
  [[ -n "${VM_RAM_ARG}" ]]          && bsearch_args+=(--vm-ram  "${VM_RAM_ARG}")
  [[ -n "${bsearch_resume_flag}" ]] && bsearch_args+=("${bsearch_resume_flag}")

  run_log="${results_dir}/run.log"
  log_event "  Results: ${results_dir}/"

  run_exit=0
  set +e
  bash "${BSEARCH}" "${bsearch_args[@]}" 2>&1 | tee -a "${run_log}"
  run_exit=${PIPESTATUS[0]}
  set -e

  if [[ "${run_exit}" -eq 0 ]]; then
    RUN_OUTCOMES+=("completed")
    log_event "DONE ${run_label}  exit=0"
  else
    RUN_OUTCOMES+=("failed")
    log_event "FAIL ${run_label}  exit=${run_exit}  (log: ${run_log})"
  fi

  # Between-run cooldown (skipped after the last run)
  if [[ "${idx}" -lt $(( TOTAL_RUNS - 1 )) ]]; then
    next_idx=$(( idx + 1 ))
    _between_runs "${RUN_TASKS[${next_idx}]}" "${RUN_HVS[${next_idx}]}"
  fi
done

# ---------------------------
# Final report
# ---------------------------

CAMPAIGN_END=$(date +%s)
CAMPAIGN_WALL=$(( CAMPAIGN_END - CAMPAIGN_START ))

echo ""
echo "========================================"
echo "CAMPAIGN COMPLETE"
echo "========================================"
echo "  Label:      ${LABEL}"
echo "  Total runs: ${TOTAL_RUNS}"
echo "  Wall time:  ${CAMPAIGN_WALL}s"
echo ""

COMPLETED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
  outcome="${RUN_OUTCOMES[${idx}]:-unknown}"
  run_dir="${RUN_DIRS[${idx}]:-}"
  run_label="${RUN_TASKS[${idx}]} / ${RUN_HVS[${idx}]}"
  case "${outcome}" in
    completed) COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 )) ;;
    failed)    FAILED_COUNT=$(( FAILED_COUNT + 1 )) ;;
    skipped)   SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 )) ;;
  esac
  printf "  %-45s %s\n" "${run_label}" "${outcome}"
  [[ -n "${run_dir}" ]] && printf "  %-45s %s\n" "" "${run_dir}/"
done

echo ""
echo "  Completed: ${COMPLETED_COUNT}/${TOTAL_RUNS}"
[[ "${FAILED_COUNT}"  -gt 0 ]] && echo "  Failed:    ${FAILED_COUNT}/${TOTAL_RUNS}"
[[ "${SKIPPED_COUNT}" -gt 0 ]] && echo "  Skipped:   ${SKIPPED_COUNT}/${TOTAL_RUNS}"
echo "========================================"

log_event "Campaign finished. completed=${COMPLETED_COUNT} failed=${FAILED_COUNT} wall=${CAMPAIGN_WALL}s"

exit 0
