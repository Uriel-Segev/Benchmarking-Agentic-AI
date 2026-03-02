#!/usr/bin/env bash
# =============================================================================
# Campaign runner: execute multiple binary search experiments sequentially
#
# Runs every (task × hypervisor) combination one at a time. Tracks state so
# the campaign can be resumed after a crash, SSH disconnect, or interruption.
# Run inside tmux for unattended multi-day experiments.
#
# Usage:
#   sudo ./run_campaign.sh \
#     --task hello-world --task pytorch-model-recovery \
#     --hypervisor firecracker --hypervisor cloud-hypervisor \
#     --label 48c \
#     [--repeats <n>] [--cooldown <s>] [--between-runs <s>] \
#     [--max-vms <n>] [--vm-ram <mb>] [--resume]
#
# Options:
#   --task <name>         task name under tasks/ (repeatable)
#   --hypervisor <hv>     firecracker or cloud-hypervisor (repeatable)
#   --label <name>        experiment label, passed through to binary search
#   --repeats <n>         repeats per binary search probe (default: 3)
#   --cooldown <s>        cooldown between probes within a run (default: 10)
#   --between-runs <s>    cooldown between campaign runs (default: 60)
#   --max-vms <n>         upper bound override for binary search
#   --vm-ram <mb>         per-VM RAM in MB (skips auto-profiling)
#   --resume              resume the most recent in-progress campaign for this label
#
# Runs are executed in order: task1/hv1, task1/hv2, task2/hv1, task2/hv2, ...
#
# Campaign state saved to:
#   ~/results/campaigns/<label>/<timestamp>/
#     campaign.json         updated after every state change (atomic write)
#     campaign.log          timestamped log of campaign-level events
#     <task>_<hv>.log       full stdout/stderr of each binary search run
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
RESUME=false
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
    --resume)       RESUME=true;         shift   ;;
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

# Per-run state (parallel arrays indexed 0..TOTAL_RUNS-1)
RUN_STATUSES=()       # pending | in_progress | completed | failed
RUN_RESULTS_DIRS=()   # path to binary search results dir
RUN_EXIT_CODES=()     # exit code of run_binary_search.sh
RUN_STARTED_ATS=()    # ISO timestamp
RUN_COMPLETED_ATS=()  # ISO timestamp

# ---------------------------
# Helpers
# ---------------------------

CAMPAIGN_DIR=""
CAMPAIGN_JSON=""
CAMPAIGN_LOG=""

log_event() {
  local msg="[campaign $(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "${msg}"
  [[ -n "${CAMPAIGN_LOG}" ]] && echo "${msg}" >> "${CAMPAIGN_LOG}" || true
}

die() { log_event "FATAL: $*"; exit 1; }

# ---------------------------
# _save_campaign_json
# Atomically rebuilds campaign.json from current state arrays.
# ---------------------------

_save_campaign_json() {
  [[ -z "${CAMPAIGN_DIR}" ]] && return

  local tmp
  tmp=$(mktemp "${CAMPAIGN_DIR}/.campaign-XXXXXX.tmp")

  # Determine overall status
  local overall_status="completed"
  for s in "${RUN_STATUSES[@]}"; do
    if [[ "${s}" == "pending" || "${s}" == "in_progress" ]]; then
      overall_status="in_progress"
      break
    fi
  done

  if command -v jq >/dev/null 2>&1; then
    # Build runs JSON array by accumulating individual run objects
    local runs_json="["
    local first_run=true
    for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
      [[ "${first_run}" == "false" ]] && runs_json+=","
      first_run=false
      local run_obj
      run_obj=$(jq -n \
        --arg task         "${RUN_TASKS[${idx}]}" \
        --arg hv           "${RUN_HVS[${idx}]}" \
        --arg status       "${RUN_STATUSES[${idx}]:-pending}" \
        --arg results_dir  "${RUN_RESULTS_DIRS[${idx}]:-}" \
        --arg exit_code    "${RUN_EXIT_CODES[${idx}]:-}" \
        --arg started_at   "${RUN_STARTED_ATS[${idx}]:-}" \
        --arg completed_at "${RUN_COMPLETED_ATS[${idx}]:-}" \
        '{
          task:         $task,
          hypervisor:   $hv,
          status:       $status,
          results_dir:  (if $results_dir  == "" then null else $results_dir  end),
          exit_code:    (if $exit_code    == "" then null else ($exit_code | tonumber) end),
          started_at:   (if $started_at   == "" then null else $started_at   end),
          completed_at: (if $completed_at == "" then null else $completed_at end)
        }')
      runs_json+="${run_obj}"
    done
    runs_json+="]"

    jq -n \
      --arg     status     "${overall_status}" \
      --arg     label      "${LABEL}" \
      --argjson total      "${TOTAL_RUNS}" \
      --argjson runs       "${runs_json}" \
      --arg     updated    "$(date -Iseconds)" \
      '{
        status:     $status,
        label:      $label,
        total_runs: $total,
        updated:    $updated,
        runs:       $runs
      }' > "${tmp}" && mv "${tmp}" "${CAMPAIGN_JSON}" || rm -f "${tmp}"
  else
    # Fallback without jq
    {
      echo "{"
      echo "  \"status\": \"${overall_status}\","
      echo "  \"label\": \"${LABEL}\","
      echo "  \"total_runs\": ${TOTAL_RUNS}"
      echo "}"
    } > "${tmp}" && mv "${tmp}" "${CAMPAIGN_JSON}" || rm -f "${tmp}"
  fi
}

# ---------------------------
# _between_runs [next_task] [next_hv]
# Kill stray hypervisor processes, then cooldown before next run.
# ---------------------------

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
# Setup campaign directory
# ---------------------------

CAMPAIGN_BASE="${HOME}/results/campaigns/${LABEL}"

if [[ "${RESUME}" == "true" ]]; then
  command -v jq >/dev/null 2>&1 || die "jq is required for --resume"

  # Find most recent in-progress campaign for this label
  CAMPAIGN_DIR=$(find "${CAMPAIGN_BASE}" -name "campaign.json" -type f 2>/dev/null \
    | xargs grep -l '"in_progress"' 2>/dev/null \
    | xargs -I{} dirname {} 2>/dev/null \
    | sort | tail -1 || true)
  [[ -n "${CAMPAIGN_DIR}" ]] \
    || die "No in-progress campaign found under ${CAMPAIGN_BASE}/. Start a new one without --resume."

  CAMPAIGN_JSON="${CAMPAIGN_DIR}/campaign.json"
  CAMPAIGN_LOG="${CAMPAIGN_DIR}/campaign.log"
  log_event "Resuming campaign from: ${CAMPAIGN_DIR}/"

  # Load existing run states from campaign.json
  while IFS=$'\t' read -r idx task hv status results_dir exit_code started_at completed_at; do
    RUN_TASKS["${idx}"]="${task}"
    RUN_HVS["${idx}"]="${hv}"
    RUN_STATUSES["${idx}"]="${status}"
    RUN_RESULTS_DIRS["${idx}"]="${results_dir}"
    RUN_EXIT_CODES["${idx}"]="${exit_code}"
    RUN_STARTED_ATS["${idx}"]="${started_at}"
    RUN_COMPLETED_ATS["${idx}"]="${completed_at}"
  done < <(jq -r '.runs | to_entries[] | [
    .key,
    .value.task,
    .value.hypervisor,
    .value.status,
    (.value.results_dir  // ""),
    (.value.exit_code    // "" | tostring | if . == "null" then "" else . end),
    (.value.started_at   // ""),
    (.value.completed_at // "")
  ] | @tsv' "${CAMPAIGN_JSON}")

  TOTAL_RUNS="${#RUN_TASKS[@]}"
  log_event "Loaded ${TOTAL_RUNS} runs from campaign.json"

else
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  CAMPAIGN_DIR="${CAMPAIGN_BASE}/${TIMESTAMP}"
  mkdir -p "${CAMPAIGN_DIR}"
  CAMPAIGN_JSON="${CAMPAIGN_DIR}/campaign.json"
  CAMPAIGN_LOG="${CAMPAIGN_DIR}/campaign.log"

  # Initialize state arrays
  for _ in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
    RUN_STATUSES+=("pending")
    RUN_RESULTS_DIRS+=("")
    RUN_EXIT_CODES+=("")
    RUN_STARTED_ATS+=("")
    RUN_COMPLETED_ATS+=("")
  done

  _save_campaign_json

  log_event "New campaign started: ${CAMPAIGN_DIR}/"
  log_event "Runs (${TOTAL_RUNS} total, in order):"
  for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
    log_event "  $((idx+1)). ${RUN_TASKS[${idx}]} / ${RUN_HVS[${idx}]}"
  done
fi

# ---------------------------
# Main loop
# ---------------------------

CAMPAIGN_START=$(date +%s)
log_event "Campaign loop: label=${LABEL}, repeats=${REPEATS}, probe_cooldown=${COOLDOWN}s, between_runs=${BETWEEN_RUNS}s"

for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
  task="${RUN_TASKS[${idx}]}"
  hv="${RUN_HVS[${idx}]}"
  status="${RUN_STATUSES[${idx}]:-pending}"
  run_label="[$((idx+1))/${TOTAL_RUNS}] ${task} / ${hv}"

  # Skip completed runs
  if [[ "${status}" == "completed" ]]; then
    log_event "SKIP ${run_label} — already completed"
    continue
  fi

  log_event "START ${run_label}"

  task_dir="${SCRIPT_DIR}/tasks/${task}"
  if [[ ! -d "${task_dir}" ]]; then
    log_event "ERROR: task directory not found: ${task_dir}"
    RUN_STATUSES["${idx}"]="failed"
    RUN_EXIT_CODES["${idx}"]="1"
    RUN_COMPLETED_ATS["${idx}"]="$(date -Iseconds)"
    _save_campaign_json
    continue
  fi

  # Decide whether to resume the binary search or start fresh
  bsearch_resume_flag=""
  results_dir="${RUN_RESULTS_DIRS[${idx}]:-}"

  if [[ -n "${results_dir}" ]] && [[ -f "${results_dir}/summary.json" ]] && \
     grep -q '"in_progress"' "${results_dir}/summary.json" 2>/dev/null; then
    bsearch_resume_flag="--resume"
    log_event "  Resuming binary search: ${results_dir}/"
  else
    # Fresh binary search — fix the results dir now so we can record it
    results_dir="${HOME}/results/${task}/${hv}/${LABEL}/$(date +%Y%m%d_%H%M%S)"
    log_event "  Fresh binary search: ${results_dir}/"
  fi

  # Build run_binary_search.sh args
  bsearch_args=(
    "${task_dir}"
    --hypervisor "${hv}"
    --label      "${LABEL}"
    --repeats    "${REPEATS}"
    --cooldown   "${COOLDOWN}"
    --output     "${results_dir}"
  )
  [[ -n "${MAX_VMS_ARG}" ]]      && bsearch_args+=(--max-vms "${MAX_VMS_ARG}")
  [[ -n "${VM_RAM_ARG}" ]]       && bsearch_args+=(--vm-ram  "${VM_RAM_ARG}")
  [[ -n "${bsearch_resume_flag}" ]] && bsearch_args+=("${bsearch_resume_flag}")

  # Record in_progress state before launching (so a crash is visible in campaign.json)
  RUN_STATUSES["${idx}"]="in_progress"
  RUN_RESULTS_DIRS["${idx}"]="${results_dir}"
  RUN_STARTED_ATS["${idx}"]="$(date -Iseconds)"
  RUN_EXIT_CODES["${idx}"]=""
  RUN_COMPLETED_ATS["${idx}"]=""
  _save_campaign_json

  # Run, capturing output to per-run log file AND terminal
  run_log="${CAMPAIGN_DIR}/${task}_${hv}.log"
  log_event "  Output: ${run_log}"

  run_exit=0
  set +e
  bash "${BSEARCH}" "${bsearch_args[@]}" 2>&1 | tee -a "${run_log}"
  run_exit=${PIPESTATUS[0]}
  set -e

  # Record outcome
  RUN_EXIT_CODES["${idx}"]="${run_exit}"
  RUN_COMPLETED_ATS["${idx}"]="$(date -Iseconds)"
  if [[ "${run_exit}" -eq 0 ]]; then
    RUN_STATUSES["${idx}"]="completed"
    log_event "DONE ${run_label}  exit=0"
  else
    RUN_STATUSES["${idx}"]="failed"
    log_event "FAIL ${run_label}  exit=${run_exit}  (log: ${run_log})"
  fi
  _save_campaign_json

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
echo "  Label:        ${LABEL}"
echo "  Total runs:   ${TOTAL_RUNS}"
echo "  Wall time:    ${CAMPAIGN_WALL}s"
echo ""

COMPLETED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

for idx in $(seq 0 $(( TOTAL_RUNS - 1 ))); do
  s="${RUN_STATUSES[${idx}]}"
  run_label="${RUN_TASKS[${idx}]} / ${RUN_HVS[${idx}]}"
  results_dir="${RUN_RESULTS_DIRS[${idx}]:-}"
  case "${s}" in
    completed) COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 )) ;;
    failed)    FAILED_COUNT=$(( FAILED_COUNT + 1 )) ;;
    pending)   SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 )) ;;
  esac
  printf "  %-45s %s\n" "${run_label}" "${s}"
  [[ -n "${results_dir}" ]] && printf "  %-45s %s\n" "" "${results_dir}/"
done

echo ""
echo "  Completed: ${COMPLETED_COUNT}/${TOTAL_RUNS}"
[[ "${FAILED_COUNT}"  -gt 0 ]] && echo "  Failed:    ${FAILED_COUNT}/${TOTAL_RUNS}"
[[ "${SKIPPED_COUNT}" -gt 0 ]] && echo "  Skipped:   ${SKIPPED_COUNT}/${TOTAL_RUNS}"
echo "  Campaign:  ${CAMPAIGN_DIR}/"
echo "========================================"

log_event "Campaign finished. completed=${COMPLETED_COUNT} failed=${FAILED_COUNT} wall=${CAMPAIGN_WALL}s"
_save_campaign_json

exit 0
