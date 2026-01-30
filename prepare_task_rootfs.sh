#!/usr/bin/env bash
# =============================================================================
# Prepare a Firecracker rootfs for running terminal-bench tasks
#
# This script:
#   1. Creates a copy of the base rootfs
#   2. Mounts it and installs Python, pytest, and dependencies
#   3. Copies task files into /app
#   4. Sets up an auto-run script that executes on VM boot
#
# Usage:
#   sudo ./prepare_task_rootfs.sh <task_dir> [output_rootfs]
#
# Example:
#   sudo ./prepare_task_rootfs.sh /path/to/terminal-bench/original-tasks/hello-world
# =============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------

WORKDIR="${WORKDIR:-/opt/firecracker}"
BASE_ROOTFS="${BASE_ROOTFS:-${WORKDIR}/rootfs-ubuntu22.ext4}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/fc-rootfs}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[prepare-rootfs] $*\n"; }
die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

cleanup_mount() {
  # Unmount chroot filesystems first (use -lf for resilience)
  umount -lf "${MOUNT_POINT}/sys" 2>/dev/null || true
  umount -lf "${MOUNT_POINT}/proc" 2>/dev/null || true
  umount -lf "${MOUNT_POINT}/dev/pts" 2>/dev/null || true
  umount -lf "${MOUNT_POINT}/dev" 2>/dev/null || true
  # Then unmount the rootfs
  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    umount -lf "${MOUNT_POINT}" || true
  fi
}

# ---------------------------
# Argument parsing
# ---------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task_dir> [output_rootfs]"
  echo "Example: $0 /path/to/terminal-bench/original-tasks/hello-world"
  exit 1
fi

TASK_DIR="$(realpath "$1")"
OUTPUT_ROOTFS="${2:-${WORKDIR}/rootfs-task.ext4}"

# Validate task directory
[[ -d "${TASK_DIR}" ]] || die "Task directory not found: ${TASK_DIR}"
[[ -f "${TASK_DIR}/task.yaml" ]] || die "No task.yaml found in ${TASK_DIR}"
[[ -f "${BASE_ROOTFS}" ]] || die "Base rootfs not found: ${BASE_ROOTFS}"

# Extract task name from directory
TASK_NAME="$(basename "${TASK_DIR}")"

log "Preparing rootfs for task: ${TASK_NAME}"
echo "  Task directory: ${TASK_DIR}"
echo "  Base rootfs:    ${BASE_ROOTFS}"
echo "  Output rootfs:  ${OUTPUT_ROOTFS}"

# ---------------------------
# Check root
# ---------------------------

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root: sudo $0 $*"
fi

# ---------------------------
# Create output rootfs
# ---------------------------

log "Creating task rootfs from base image"

# Copy base rootfs
cp -f "${BASE_ROOTFS}" "${OUTPUT_ROOTFS}"

# Resize to ensure enough space (add 512MB)
log "Resizing rootfs to ensure space for dependencies"
truncate -s +512M "${OUTPUT_ROOTFS}"
e2fsck -f -y "${OUTPUT_ROOTFS}" || true
resize2fs "${OUTPUT_ROOTFS}"

# ---------------------------
# Mount rootfs
# ---------------------------

log "Mounting rootfs"
mkdir -p "${MOUNT_POINT}"
trap cleanup_mount EXIT

mount -o loop "${OUTPUT_ROOTFS}" "${MOUNT_POINT}"

# Ensure /tmp exists and is writable inside the rootfs (APT needs this)
mkdir -p "${MOUNT_POINT}/tmp"
chmod 1777 "${MOUNT_POINT}/tmp"


# ---------------------------
# Install dependencies inside rootfs
# ---------------------------

log "Installing dependencies in rootfs (via chroot)"

# Copy DNS resolution into chroot
cp /etc/resolv.conf "${MOUNT_POINT}/etc/resolv.conf" 2>/dev/null || true

# Mount essential filesystems for chroot (apt needs /dev/null, /proc, etc.)
# Use guards to make mounts idempotent (safe if script crashed mid-run previously)
log "Mounting essential filesystems for chroot"
mountpoint -q "${MOUNT_POINT}/dev"     || mount --bind /dev "${MOUNT_POINT}/dev"
mountpoint -q "${MOUNT_POINT}/dev/pts" || mount --bind /dev/pts "${MOUNT_POINT}/dev/pts" 2>/dev/null || true
mountpoint -q "${MOUNT_POINT}/proc"    || mount -t proc proc "${MOUNT_POINT}/proc"
mountpoint -q "${MOUNT_POINT}/sys"     || mount -t sysfs sysfs "${MOUNT_POINT}/sys"

# Install Python and dependencies via chroot
chroot "${MOUNT_POINT}" /bin/bash <<'CHROOT_INSTALL'
set -e

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Validate base rootfs has proper dpkg database
[[ -f /var/lib/dpkg/status ]] || { echo "ERROR: /var/lib/dpkg/status missing; base rootfs is not a normal Ubuntu rootfs"; exit 1; }

# Validate gpgv is available for apt signature verification
if ! command -v gpgv &>/dev/null && ! command -v gpgv1 &>/dev/null && ! command -v gpgv2 &>/dev/null; then
  echo "ERROR: gpgv not found; base rootfs is missing package signing tools"
  echo "Fix the base rootfs or use a proper Ubuntu image"
  exit 1
fi

# Update and install Python
# Enable universe repository (needed for python3-pip, python3-venv)
if ! grep -Rqs "^deb .* jammy universe" /etc/apt; then
  echo "Enabling Ubuntu universe repository"
  echo "deb http://archive.ubuntu.com/ubuntu jammy universe" \
    > /etc/apt/sources.list.d/universe.list
fi

apt-get update
apt-get install -y --no-install-recommends \
  python3 \
  python3-pip \
  python3-venv \
  curl \
  ca-certificates

# Install pytest directly (simpler than uv for this use case)
pip3 install --break-system-packages pytest==8.4.1 || pip3 install pytest==8.4.1

# Create /app directory
mkdir -p /app

# Clean up apt cache to save space
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Dependencies installed successfully"
CHROOT_INSTALL

# ---------------------------
# Copy task files
# ---------------------------

log "Copying task files to /app"

# Create task structure in rootfs
mkdir -p "${MOUNT_POINT}/app"
mkdir -p "${MOUNT_POINT}/app/tests"

# Copy task files
if [[ -f "${TASK_DIR}/solution.sh" ]]; then
  cp "${TASK_DIR}/solution.sh" "${MOUNT_POINT}/app/"
  chmod +x "${MOUNT_POINT}/app/solution.sh"
fi

if [[ -f "${TASK_DIR}/run-tests.sh" ]]; then
  cp "${TASK_DIR}/run-tests.sh" "${MOUNT_POINT}/app/"
  chmod +x "${MOUNT_POINT}/app/run-tests.sh"
fi

if [[ -f "${TASK_DIR}/task.yaml" ]]; then
  cp "${TASK_DIR}/task.yaml" "${MOUNT_POINT}/app/"
fi

# Copy test files
if [[ -d "${TASK_DIR}/tests" ]]; then
  cp -r "${TASK_DIR}/tests/"* "${MOUNT_POINT}/app/tests/" 2>/dev/null || true
else
  # Fallback: copy test_*.py files from task root (e.g., hello-world has test_outputs.py in root)
  for f in "${TASK_DIR}"/test_*.py; do
    [[ -f "$f" ]] && cp "$f" "${MOUNT_POINT}/app/tests/"
  done
fi

# ---------------------------
# Create auto-run script
# ---------------------------

log "Creating auto-run boot script"

cat > "${MOUNT_POINT}/app/autorun.sh" <<'AUTORUN_SCRIPT'
#!/bin/bash
# Auto-run script for terminal-bench task execution
# This runs automatically on VM boot

set -e

RESULTS_FILE="/app/results.json"
LOG_FILE="/app/run.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "========================================"
echo "Terminal-Bench Task Runner"
echo "Started at: $(date -Iseconds)"
echo "========================================"

cd /app

# Initialize results
echo '{"status": "running", "tests_passed": 0, "tests_failed": 0, "output": ""}' > "${RESULTS_FILE}"

# Run the solution (if exists)
if [[ -f /app/solution.sh ]]; then
  echo ""
  echo "[SOLUTION] Running solution.sh..."
  if bash /app/solution.sh; then
    echo "[SOLUTION] Completed successfully"
  else
    echo "[SOLUTION] Failed with exit code $?"
  fi
fi

# Run the tests
echo ""
echo "[TESTS] Running pytest..."

set +e
TEST_OUTPUT=$(python3 -m pytest /app/tests/test_outputs.py -v --tb=short 2>&1)
TEST_EXIT_CODE=$?
set -e

echo "${TEST_OUTPUT}"

# Parse pytest output for pass/fail counts
PASSED=$(echo "${TEST_OUTPUT}" | grep -oP '\d+(?= passed)' | head -1 || echo "0")
FAILED=$(echo "${TEST_OUTPUT}" | grep -oP '\d+(?= failed)' | head -1 || echo "0")

[[ -z "${PASSED}" ]] && PASSED=0
[[ -z "${FAILED}" ]] && FAILED=0

# Determine overall status
if [[ "${TEST_EXIT_CODE}" -eq 0 ]]; then
  STATUS="passed"
else
  STATUS="failed"
fi

# Write results JSON
cat > "${RESULTS_FILE}" <<EOF
{
  "status": "${STATUS}",
  "tests_passed": ${PASSED},
  "tests_failed": ${FAILED},
  "exit_code": ${TEST_EXIT_CODE},
  "timestamp": "$(date -Iseconds)"
}
EOF

echo ""
echo "========================================"
echo "Results: ${STATUS}"
echo "  Passed: ${PASSED}"
echo "  Failed: ${FAILED}"
echo "========================================"

# Signal completion by creating marker file
touch /app/TASK_COMPLETE

# Give time for output to flush, then shutdown
sync
sleep 2
echo "Shutting down VM..."
reboot -f
AUTORUN_SCRIPT

chmod +x "${MOUNT_POINT}/app/autorun.sh"

# ---------------------------
# Configure auto-start
# ---------------------------

log "Configuring auto-start on boot"

# Create systemd service to run on boot
cat > "${MOUNT_POINT}/etc/systemd/system/task-runner.service" <<'SYSTEMD_SERVICE'
[Unit]
Description=Terminal-Bench Task Runner
After=network.target
ConditionPathExists=/app/autorun.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /app/autorun.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE

# Enable the service
chroot "${MOUNT_POINT}" /bin/bash -c "systemctl enable task-runner.service" 2>/dev/null || true


# ---------------------------
# Unmount and finalize
# ---------------------------

log "Finalizing rootfs"
sync
cleanup_mount
trap - EXIT

echo ""
echo "========================================"
echo "Task rootfs prepared successfully"
echo "========================================"
echo "Output: ${OUTPUT_ROOTFS}"
echo "Task:   ${TASK_NAME}"
echo ""
echo "To run the task:"
echo "  sudo ./run_task.sh ${OUTPUT_ROOTFS}"
echo "========================================"
