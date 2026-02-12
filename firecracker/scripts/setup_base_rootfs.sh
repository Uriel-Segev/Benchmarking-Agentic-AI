#!/usr/bin/env bash
# =============================================================================
# Setup base Ubuntu rootfs for Firecracker
#
# This script:
#   1. Creates an ext4 image using debootstrap
#   2. Configures systemd, serial console, and root login
#   3. Produces a bootable base rootfs for Firecracker
#
# Run AFTER install_firecracker.sh, BEFORE prepare_task_rootfs.sh
#
# Usage:
#   sudo ./setup_base_rootfs.sh
# =============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------

WORKDIR="${WORKDIR:-/opt/firecracker}"
ROOTFS_PATH="${ROOTFS_PATH:-${WORKDIR}/rootfs-ubuntu22.ext4}"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-2048}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/fc-rootfs}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-jammy}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[setup-base-rootfs] $*\n"; }
die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

cleanup() {
  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    umount -lf "${MOUNT_POINT}" 2>/dev/null || true
  fi
}

# ---------------------------
# Validation
# ---------------------------

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root: sudo $0"
fi

# Check for debootstrap
if ! command -v debootstrap &>/dev/null; then
  log "Installing debootstrap and e2fsprogs..."
  apt-get update
  apt-get install -y debootstrap e2fsprogs
fi

# ---------------------------
# Create ext4 image
# ---------------------------

log "Creating ${ROOTFS_SIZE_MB}MB ext4 image at ${ROOTFS_PATH}"

mkdir -p "${WORKDIR}"
mkdir -p "${MOUNT_POINT}"

# Create sparse file and format
dd if=/dev/zero of="${ROOTFS_PATH}" bs=1M count="${ROOTFS_SIZE_MB}" status=progress
mkfs.ext4 -F "${ROOTFS_PATH}"

# ---------------------------
# Bootstrap Ubuntu
# ---------------------------

log "Bootstrapping Ubuntu ${UBUNTU_RELEASE} (this takes a few minutes)..."

trap cleanup EXIT

mount -o loop "${ROOTFS_PATH}" "${MOUNT_POINT}"

debootstrap --arch=amd64 "${UBUNTU_RELEASE}" "${MOUNT_POINT}" "${UBUNTU_MIRROR}"

# ---------------------------
# Configure for Firecracker
# ---------------------------

log "Configuring rootfs for Firecracker boot"

# Set hostname
echo "firecracker-vm" > "${MOUNT_POINT}/etc/hostname"

# Basic fstab
cat > "${MOUNT_POINT}/etc/fstab" <<'EOF'
/dev/vda / ext4 defaults 0 1
EOF

# Configure inside chroot
chroot "${MOUNT_POINT}" /bin/bash <<'CHROOT_CONFIG'
set -e

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Ensure systemd is the init system
ln -sf /lib/systemd/systemd /sbin/init 2>/dev/null || true

# Enable serial console for ttyS0 (Firecracker uses this)
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true

# Set default target to multi-user (no GUI)
systemctl set-default multi-user.target 2>/dev/null || true

# Set root password for debugging (can SSH/login if needed)
echo "root:root" | chpasswd

# Allow root login on serial console
echo "ttyS0" >> /etc/securetty 2>/dev/null || true

# Configure DNS (use Google DNS as fallback)
cat > /etc/resolv.conf <<'DNS'
nameserver 8.8.8.8
nameserver 8.8.4.4
DNS

echo "Base rootfs configuration complete"
CHROOT_CONFIG

# ---------------------------
# Finalize
# ---------------------------

log "Finalizing rootfs"
sync
umount "${MOUNT_POINT}"
trap - EXIT

echo ""
echo "========================================"
echo "Base rootfs created successfully"
echo "========================================"
echo "  Path: ${ROOTFS_PATH}"
echo "  Size: ${ROOTFS_SIZE_MB}MB"
echo "  Release: Ubuntu ${UBUNTU_RELEASE}"
echo ""
echo "  Root login: root / root"
echo ""
echo "Next step:"
echo "  sudo ./prepare_task_rootfs.sh <task_dir>"
echo "========================================"
