#!/usr/bin/env bash
# =============================================================================
# CloudLab-safe Firecracker bootstrap (install + networking + run helper scripts)
#
# Goals:
#  - Install Firecracker (pinned version), kernel, rootfs
#  - Bring up a TAP interface on a SAFE RFC1918 subnet (default 192.168.100.0/30)
#  - Enable NAT so the microVM can reach the internet
#  - Be *idempotent*: rerunning should not stack iptables rules or break state
#  - Be *reversible*: provide cleanup that removes only what we added
#
# IMPORTANT CLOUDLAB NOTE:
#  - DO NOT use 172.16.0.0/12 on CloudLab; it overlaps their control network.
#  - This script defaults to 192.168.100.0/30.
#
# Run with: sudo ./install_firecracker.sh
# =============================================================================

set -euo pipefail

# ---------------------------
# User-configurable settings
# ---------------------------

# Work directory (everything goes here)
WORKDIR="${WORKDIR:-/opt/firecracker}"

# Network config (safe defaults)
TAP_DEV="${TAP_DEV:-tap0}"

# Default safe subnet for CloudLab; /30 gives exactly 2 usable IPs (host + guest).
# If you change this, keep it RFC1918 and avoid 172.16.0.0/12 entirely on CloudLab.
SUBNET_CIDR="${SUBNET_CIDR:-192.168.100.0/30}"

# Optionally override these; if empty, we derive them from SUBNET_CIDR
TAP_IP="${TAP_IP:-}"   # host-side IP on tap
FC_IP="${FC_IP:-}"     # guest IP

# If you know the correct egress interface, set it explicitly (recommended).
# Otherwise, we auto-detect default route interface.
DEFAULT_IFACE="${DEFAULT_IFACE:-}"

# Firecracker version + architecture
FC_VERSION="${FC_VERSION:-v1.10.1}"
ARCH="$(uname -m)"

# Download URLs (pinned-ish; consider checksums for paper-quality)
FC_RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz"
KERNEL_URL="${KERNEL_URL:-https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/${ARCH}/kernels/vmlinux.bin}"
ROOTFS_URL="${ROOTFS_URL:-https://s3.amazonaws.com/spec.ccfc.min/ci-artifacts/disks/${ARCH}/ubuntu-22.04.ext4}"

# iptables chain names we own (so we can remove cleanly)
FC_NAT_CHAIN="FC_NAT"
FC_FWD_CHAIN="FC_FWD"

# State file to restore sysctls
IPFWD_STATE_FILE="/run/firecracker_ip_forward.prev"

# Safety options
DRY_RUN="${DRY_RUN:-0}"
RUN_ARP_TEST="${RUN_ARP_TEST:-1}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[firecracker-setup] $*\n"; }

die() { echo -e "\nERROR: $*\n" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo $0"
  fi
}

require_kvm() {
  [[ -e /dev/kvm ]] || die "/dev/kvm missing; KVM not available. Ensure you're on bare-metal or a VM with nested virt enabled."
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Derive TAP_IP and FC_IP from SUBNET_CIDR if not provided.
# For /30, usable hosts are .1 and .2 (for typical RFC1918 /30 blocks).
derive_ips_from_cidr() {
  # We keep it simple and safe: default assumes x.y.z.0/30 and uses .1 (host), .2 (guest).
  # If you provide TAP_IP/FC_IP explicitly, we skip this.
  if [[ -n "${TAP_IP}" && -n "${FC_IP}" ]]; then
    return
  fi

  local base="${SUBNET_CIDR%/*}"
  local prefix="${SUBNET_CIDR#*/}"

  [[ "${prefix}" == "30" ]] || die "This script currently expects /30 by default. Set TAP_IP and FC_IP explicitly if you want a different prefix."

  # Expect base ends with .0
  if [[ ! "${base}" =~ \.0$ ]]; then
    die "SUBNET_CIDR base should end in .0 for /30 (e.g., 192.168.100.0/30). Got: ${SUBNET_CIDR}"
  fi

  local base_prefix="${base%.0}."
  TAP_IP="${TAP_IP:-${base_prefix}1}"
  FC_IP="${FC_IP:-${base_prefix}2}"
}

# Basic CloudLab safety checks (not perfect, but catches the big footguns)
cloudlab_safety_checks() {
  # Disallow 172.16.0.0/12 outright (CloudLab control range)
  if [[ "${TAP_IP}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    die "TAP_IP=${TAP_IP} is in 172.16.0.0/12 which is NOT CloudLab-safe. Use 192.168.x.x or 10.x.x.x."
  fi
  if [[ "${FC_IP}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    die "FC_IP=${FC_IP} is in 172.16.0.0/12 which is NOT CloudLab-safe. Use 192.168.x.x or 10.x.x.x."
  fi

  # Avoid link-local range
  if [[ "${TAP_IP}" =~ ^169\.254\. || "${FC_IP}" =~ ^169\.254\. ]]; then
    die "169.254.0.0/16 is link-local; do not use it here."
  fi
}

detect_default_iface() {
  if [[ -n "${DEFAULT_IFACE}" ]]; then
    return
  fi
  # Prefer JSON route if available (ip -j). Otherwise fallback.
  if has_cmd jq; then
    DEFAULT_IFACE="$(ip -j route list default | jq -r '.[0].dev' 2>/dev/null || true)"
  fi
  if [[ -z "${DEFAULT_IFACE}" || "${DEFAULT_IFACE}" == "null" ]]; then
    DEFAULT_IFACE="$(ip route list default | awk '{print $5; exit}' || true)"
  fi
  [[ -n "${DEFAULT_IFACE}" ]] || die "Could not auto-detect DEFAULT_IFACE. Set DEFAULT_IFACE=ens3 (or similar) and rerun."
}

# Preflight summary - show what we're about to do
preflight_print() {
  log "Preflight"
  echo "  TAP_DEV=${TAP_DEV}"
  echo "  SUBNET_CIDR=${SUBNET_CIDR}"
  echo "  TAP_IP=${TAP_IP}"
  echo "  FC_IP=${FC_IP}"
  echo "  DEFAULT_IFACE=${DEFAULT_IFACE}"
}

# Verify DEFAULT_IFACE exists and show its current state
sanity_check_iface() {
  ip link show "${DEFAULT_IFACE}" >/dev/null 2>&1 || die "DEFAULT_IFACE ${DEFAULT_IFACE} not found"
  echo "  DEFAULT_IFACE info:"
  ip -br addr show "${DEFAULT_IFACE}" | sed 's/^/    /'
}

# After TAP setup: verify TAP_IP is ONLY on TAP_DEV (not leaked elsewhere)
assert_tap_ip_scope() {
  local dev
  dev="$(ip -o addr show | awk -v ip="${TAP_IP}" '$0 ~ ip {print $2; exit}')"
  [[ "${dev}" == "${TAP_DEV}" ]] || die "TAP_IP ${TAP_IP} appears on ${dev} (expected ${TAP_DEV}). Refusing to continue."
}

# ARP safety check - detect the exact failure mode that got you banned
assert_no_arp_on_default_iface() {
  if [[ "${RUN_ARP_TEST}" != "1" ]]; then
    echo "  Skipping ARP test (RUN_ARP_TEST != 1)"
    return
  fi
  log "ARP safety check (10s) - checking for dangerous ARP on ${DEFAULT_IFACE}"
  # If we see ARP traffic mentioning TAP_IP on DEFAULT_IFACE, something is wrong
  if timeout 10 tcpdump -n -c 1 -i "${DEFAULT_IFACE}" "arp and host ${TAP_IP}" 2>/dev/null; then
    die "Saw ARP involving TAP_IP (${TAP_IP}) on ${DEFAULT_IFACE}. This is dangerous on CloudLab!"
  fi
  echo "  ARP check passed (no TAP_IP ARP seen on ${DEFAULT_IFACE})"
}

# Inline cleanup for trap - doesn't depend on cleanup.sh existing
inline_cleanup() {
  echo "ERROR: script failed; cleaning up networking state..."
  ip link del "${TAP_DEV}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j "${FC_NAT_CHAIN}" 2>/dev/null || true
  iptables -D FORWARD -j "${FC_FWD_CHAIN}" 2>/dev/null || true
  iptables -t nat -F "${FC_NAT_CHAIN}" 2>/dev/null || true
  iptables -t nat -X "${FC_NAT_CHAIN}" 2>/dev/null || true
  iptables -F "${FC_FWD_CHAIN}" 2>/dev/null || true
  iptables -X "${FC_FWD_CHAIN}" 2>/dev/null || true
  if [[ -f "${IPFWD_STATE_FILE}" ]]; then
    cat "${IPFWD_STATE_FILE}" > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    rm -f "${IPFWD_STATE_FILE}" || true
  fi
  echo "Cleanup attempted."
}

# Idempotent iptables: check before add
iptables_add_once() {
  # usage: iptables_add_once <table> <rule...>
  local table="$1"; shift
  if iptables -t "${table}" -C "$@" 2>/dev/null; then
    return
  fi
  iptables -t "${table}" -A "$@"
}

iptables_insert_once() {
  # usage: iptables_insert_once <table> <chain> <rule...>
  local table="$1"; local chain="$2"; shift 2
  if iptables -t "${table}" -C "${chain}" "$@" 2>/dev/null; then
    return
  fi
  iptables -t "${table}" -I "${chain}" 1 "$@"
}

ensure_iptables_chains() {
  # Create chains if missing
  iptables -t nat -N "${FC_NAT_CHAIN}" 2>/dev/null || true
  iptables -N "${FC_FWD_CHAIN}" 2>/dev/null || true

  # Ensure the main chains jump into ours exactly once (insert at top)
  iptables_insert_once nat POSTROUTING -j "${FC_NAT_CHAIN}"
  iptables_insert_once filter FORWARD -j "${FC_FWD_CHAIN}"
}

configure_nat_and_forwarding() {
  log "Configuring IP forwarding + iptables (idempotent, reversible)"

  # Save original ip_forward if not already saved
  if [[ ! -f "${IPFWD_STATE_FILE}" ]]; then
    cat /proc/sys/net/ipv4/ip_forward > "${IPFWD_STATE_FILE}" || true
  fi

  # Enable forwarding
  echo 1 > /proc/sys/net/ipv4/ip_forward

  ensure_iptables_chains

  # In our chains, set rules (only what we own)
  # NAT: masquerade guest traffic out DEFAULT_IFACE
  iptables_add_once nat "${FC_NAT_CHAIN}" -o "${DEFAULT_IFACE}" -j MASQUERADE

  # Forwarding: allow established and allow tap->egress (and optionally reverse)
  iptables_add_once filter "${FC_FWD_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables_add_once filter "${FC_FWD_CHAIN}" -i "${TAP_DEV}" -o "${DEFAULT_IFACE}" -j ACCEPT
  # (optional) allow host->tap; not strictly required for NAT, but helpful
  iptables_add_once filter "${FC_FWD_CHAIN}" -i "${DEFAULT_IFACE}" -o "${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

setup_tap() {
  log "Setting up TAP device ${TAP_DEV} with ${TAP_IP}/${SUBNET_CIDR#*/}"

  # Clean old TAP if exists
  ip link del "${TAP_DEV}" 2>/dev/null || true

  # Create TAP device
  ip tuntap add dev "${TAP_DEV}" mode tap
  ip addr add "${TAP_IP}/${SUBNET_CIDR#*/}" dev "${TAP_DEV}"
  ip link set dev "${TAP_DEV}" up
}

install_deps() {
  log "Installing dependencies"
  apt-get update
  apt-get install -y \
    curl wget jq iproute2 iptables acl ca-certificates util-linux \
    bc tcpdump
}

install_firecracker() {
  log "Installing Firecracker ${FC_VERSION} (${ARCH})"
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  curl -fsSL "${FC_RELEASE_URL}" -o firecracker.tgz
  tar -xzf firecracker.tgz

  # The release directory naming is: release-${version}-${arch}
  local rel_dir="release-${FC_VERSION}-${ARCH}"
  [[ -d "${rel_dir}" ]] || die "Unexpected release dir not found: ${rel_dir}"

  install -m 0755 "${rel_dir}/firecracker-${FC_VERSION}-${ARCH}" /usr/local/bin/firecracker
  install -m 0755 "${rel_dir}/jailer-${FC_VERSION}-${ARCH}" /usr/local/bin/jailer

  rm -rf "${rel_dir}" firecracker.tgz

  /usr/local/bin/firecracker --version || true
}

download_kernel_rootfs() {
  log "Downloading kernel + rootfs"
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  # Kernel
  curl -fsSL "${KERNEL_URL}" -o "${WORKDIR}/vmlinux.bin"

  # Rootfs base
  curl -fsSL "${ROOTFS_URL}" -o "${WORKDIR}/rootfs.ext4"

  # Working copy (VM-writable)
  cp -f "${WORKDIR}/rootfs.ext4" "${WORKDIR}/rootfs-vm.ext4"
}

write_vm_config() {
  log "Writing VM config + helper scripts"

  local prefix="${SUBNET_CIDR#*/}"
  local netmask_long
  # Convert /30 into dotted netmask (simple mapping for /30 default)
  # If you change prefix, set NETMASK_LONG explicitly via env or extend mapping.
  if [[ "${prefix}" == "30" ]]; then
    netmask_long="255.255.255.252"
  else
    die "Prefix /${prefix} not supported in dotted netmask mapping. Use /30 or extend mapping."
  fi

  cat > "${WORKDIR}/vm_config.json" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${WORKDIR}/vmlinux.bin",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=${FC_IP}::${TAP_IP}:${netmask_long}::eth0:off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${WORKDIR}/rootfs-vm.ext4",
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
    "vcpu_count": 2,
    "mem_size_mib": 1024
  }
}
EOF

  cat > "${WORKDIR}/start_vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/opt/firecracker"
SOCKET_PATH="/tmp/firecracker.socket"

# Fresh socket each run
rm -f "${SOCKET_PATH}"

# Optional: reset the VM rootfs for a clean boot each time.
# Comment this out if you want the VM disk to persist changes within the experiment.
cp -f "${WORKDIR}/rootfs.ext4" "${WORKDIR}/rootfs-vm.ext4"

echo
echo "Starting Firecracker VM..."
echo "  Console exit: Ctrl+A then X"
echo "  If networking works, guest should reach the internet via host NAT."
echo "  Note: DNS inside guest may still need /etc/resolv.conf configured."
echo

exec /usr/local/bin/firecracker --api-sock "${SOCKET_PATH}" --config-file "${WORKDIR}/vm_config.json"
EOF
  chmod +x "${WORKDIR}/start_vm.sh"

  # Network setup script for post-reboot / reruns
  cat > "${WORKDIR}/setup_network.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="${TAP_DEV}"
TAP_IP="${TAP_IP}"
SUBNET_CIDR="${SUBNET_CIDR}"
DEFAULT_IFACE="${DEFAULT_IFACE}"
FC_NAT_CHAIN="${FC_NAT_CHAIN}"
FC_FWD_CHAIN="${FC_FWD_CHAIN}"
IPFWD_STATE_FILE="${IPFWD_STATE_FILE}"

if [[ "\${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo \${0}"
  exit 1
fi

# Recompute DEFAULT_IFACE if empty or if the saved interface no longer exists
if [[ -z "\${DEFAULT_IFACE}" ]] || ! ip link show "\${DEFAULT_IFACE}" &>/dev/null; then
  DEFAULT_IFACE="\$(ip route list default | awk '{print \$5; exit}' || true)"
  [[ -n "\${DEFAULT_IFACE}" ]] || { echo "ERROR: Could not detect default interface"; exit 1; }
  echo "Detected DEFAULT_IFACE=\${DEFAULT_IFACE}"
fi

# Bring up TAP
ip link del "\${TAP_DEV}" 2>/dev/null || true
ip tuntap add dev "\${TAP_DEV}" mode tap
ip addr add "\${TAP_IP}/\${SUBNET_CIDR#*/}" dev "\${TAP_DEV}"
ip link set dev "\${TAP_DEV}" up

# Anti-ban safety check: verify TAP_IP is ONLY on TAP_DEV
echo "Running CloudLab safety checks..."
_tap_ip_dev="\$(ip -o addr show | awk -v ip="\${TAP_IP}" '\$0 ~ ip {print \$2; exit}')"
if [[ "\${_tap_ip_dev}" != "\${TAP_DEV}" ]]; then
  echo "ERROR: TAP_IP \${TAP_IP} appears on \${_tap_ip_dev} (expected \${TAP_DEV}). Refusing to continue."
  exit 1
fi
echo "  TAP_IP scope check passed (only on \${TAP_DEV})"

# Anti-ban safety check: ARP check on DEFAULT_IFACE
echo "  ARP safety check (10s) - checking for dangerous ARP on \${DEFAULT_IFACE}..."
if timeout 10 tcpdump -n -c 1 -i "\${DEFAULT_IFACE}" "arp and host \${TAP_IP}" 2>/dev/null; then
  echo "ERROR: Saw ARP involving TAP_IP (\${TAP_IP}) on \${DEFAULT_IFACE}. This is dangerous on CloudLab!"
  exit 1
fi
echo "  ARP check passed (no TAP_IP ARP seen on \${DEFAULT_IFACE})"

# Save + enable ip_forward
if [[ ! -f "\${IPFWD_STATE_FILE}" ]]; then
  cat /proc/sys/net/ipv4/ip_forward > "\${IPFWD_STATE_FILE}" || true
fi
echo 1 > /proc/sys/net/ipv4/ip_forward

# Ensure chains exist
iptables -t nat -N "\${FC_NAT_CHAIN}" 2>/dev/null || true
iptables -N "\${FC_FWD_CHAIN}" 2>/dev/null || true

# Ensure jump rules exist once
iptables -t nat -C POSTROUTING -j "\${FC_NAT_CHAIN}" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "\${FC_NAT_CHAIN}"
iptables -C FORWARD -j "\${FC_FWD_CHAIN}" 2>/dev/null || iptables -I FORWARD 1 -j "\${FC_FWD_CHAIN}"

# Rules in owned chains (add once)
iptables -t nat -C "\${FC_NAT_CHAIN}" -o "\${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || iptables -t nat -A "\${FC_NAT_CHAIN}" -o "\${DEFAULT_IFACE}" -j MASQUERADE

iptables -C "\${FC_FWD_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A "\${FC_FWD_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -C "\${FC_FWD_CHAIN}" -i "\${TAP_DEV}" -o "\${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null || iptables -A "\${FC_FWD_CHAIN}" -i "\${TAP_DEV}" -o "\${DEFAULT_IFACE}" -j ACCEPT
iptables -C "\${FC_FWD_CHAIN}" -i "\${DEFAULT_IFACE}" -o "\${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A "\${FC_FWD_CHAIN}" -i "\${DEFAULT_IFACE}" -o "\${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "Network setup complete."
echo "  TAP_DEV=\${TAP_DEV}"
echo "  TAP_IP=\${TAP_IP}"
echo "  DEFAULT_IFACE=\${DEFAULT_IFACE}"
EOF
  chmod +x "${WORKDIR}/setup_network.sh"

  # Cleanup script: removes only what we added
  cat > "${WORKDIR}/cleanup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="${TAP_DEV}"
FC_NAT_CHAIN="${FC_NAT_CHAIN}"
FC_FWD_CHAIN="${FC_FWD_CHAIN}"
IPFWD_STATE_FILE="${IPFWD_STATE_FILE}"

if [[ "\${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo \${0}"
  exit 1
fi

# Remove TAP
ip link del "\${TAP_DEV}" 2>/dev/null || true

# Remove jump rules (if present)
iptables -t nat -D POSTROUTING -j "\${FC_NAT_CHAIN}" 2>/dev/null || true
iptables -D FORWARD -j "\${FC_FWD_CHAIN}" 2>/dev/null || true

# Flush + delete our chains
iptables -t nat -F "\${FC_NAT_CHAIN}" 2>/dev/null || true
iptables -t nat -X "\${FC_NAT_CHAIN}" 2>/dev/null || true

iptables -F "\${FC_FWD_CHAIN}" 2>/dev/null || true
iptables -X "\${FC_FWD_CHAIN}" 2>/dev/null || true

# Restore ip_forward if we saved it
if [[ -f "\${IPFWD_STATE_FILE}" ]]; then
  prev=\$(cat "\${IPFWD_STATE_FILE}" || echo "0")
  echo "\${prev}" > /proc/sys/net/ipv4/ip_forward || true
  rm -f "\${IPFWD_STATE_FILE}" || true
fi

echo "Cleanup complete."
EOF
  chmod +x "${WORKDIR}/cleanup.sh"
}

print_summary() {
  echo
  echo "=========================================="
  echo "CloudLab-safe Firecracker setup complete"
  echo "=========================================="
  echo "WORKDIR:        ${WORKDIR}"
  echo
  echo "Network:"
  echo "  SUBNET_CIDR:   ${SUBNET_CIDR}"
  echo "  TAP_DEV:       ${TAP_DEV}"
  echo "  TAP_IP:        ${TAP_IP}"
  echo "  FC_IP:         ${FC_IP}"
  echo "  DEFAULT_IFACE: ${DEFAULT_IFACE}"
  echo
  echo "Commands:"
  echo "  Start VM:      sudo ${WORKDIR}/start_vm.sh"
  echo "  Re-setup net:  sudo ${WORKDIR}/setup_network.sh"
  echo "  Cleanup:       sudo ${WORKDIR}/cleanup.sh"
  echo
  echo "Note: Guest DNS might need /etc/resolv.conf configured depending on the rootfs."
  echo "=========================================="
  echo
}

# ---------------------------
# Main
# ---------------------------

require_root
require_kvm
derive_ips_from_cidr
cloudlab_safety_checks
install_deps
detect_default_iface

# Show preflight summary and validate interface
preflight_print
sanity_check_iface

# Dry run mode - exit before making changes
if [[ "${DRY_RUN}" == "1" ]]; then
  echo
  echo "DRY_RUN=1, exiting before making changes."
  echo "If the above looks correct, rerun without DRY_RUN."
  exit 0
fi

log "Plan:"
echo "  - Install Firecracker ${FC_VERSION} (${ARCH})"
echo "  - Download kernel/rootfs into ${WORKDIR}"
echo "  - Setup TAP ${TAP_DEV} at ${TAP_IP} on ${SUBNET_CIDR}"
echo "  - NAT guest ${FC_IP} to internet via ${DEFAULT_IFACE}"
echo
echo "If DEFAULT_IFACE looks wrong, abort now and rerun with:"
echo "  sudo DEFAULT_IFACE=<iface> $0"
echo

# Set up trap to cleanup on failure
trap inline_cleanup ERR

install_firecracker
download_kernel_rootfs
setup_tap

# Verify TAP_IP is only on our TAP device
assert_tap_ip_scope

configure_nat_and_forwarding

# ARP safety check - detect the failure mode that causes CloudLab bans
assert_no_arp_on_default_iface

# Disable trap now that we're past the dangerous part
trap - ERR

write_vm_config
print_summary

# =============================================================================
# EXPLANATIONS (what changed and why)
# =============================================================================
#
# 1) CloudLab-safe subnet by default (SUBNET_CIDR=192.168.100.0/30)
#    - Prevents the exact quarantine you hit: CloudLab reserves 172.16.0.0/12.
#    - Still allows a simple 2-host setup (host tap .1, guest .2).
#
# 2) Safety checks for IP ranges
#    - Hard-fails if TAP_IP or FC_IP falls in 172.16.0.0/12 or 169.254.0.0/16.
#    - This is a "guardrail" against LLM/tutorial defaults.
#
# 3) Idempotent iptables via dedicated chains (FC_NAT, FC_FWD)
#    - Instead of appending rules directly to POSTROUTING/FORWARD repeatedly,
#      we create our own chains and insert a single jump to them.
#    - Rerunning the script does NOT stack duplicates.
#    - Cleanup removes only these chains and their jump rules.
#
# 4) Reversible sysctl change (ip_forward)
#    - Enabling IP forwarding is a global host change.
#    - We save the previous value to /run/firecracker_ip_forward.prev and restore
#      it on cleanup.
#
# 5) DEFAULT_IFACE detection + override
#    - Auto-detects from default route (common case), but prints it and encourages
#      explicit override for reproducibility:
#        sudo DEFAULT_IFACE=ens3 ./install_firecracker.sh
#
# 6) Explicit "rerun after reboot" script
#    - setup_network.sh brings TAP + iptables back in a consistent way.
#    - Still idempotent.
#
# 7) Reproducibility notes (paper-quality considerations)
#    - For serious benchmarking later, consider:
#      a) Pin immutable kernel/rootfs artifacts AND verify SHA256 checksums
#      b) Record exact Firecracker version, kernel version, host kernel, BIOS, CPU model
#      c) Pin CloudLab site + hardware type + OS image + kernel version
#      d) Avoid "latest" downloads
#      e) Avoid running Claude/LLM tooling during measured runs (noise)
#      f) Consider network namespaces to avoid touching global iptables at all
#
# 8) Guest DNS caveat
#    - Static IP boot args set address/gateway; DNS may still need configuration
#      depending on the rootfs (e.g., /etc/resolv.conf).
#
# 9) Anti-ban safety features (CloudLab-specific)
#    - DRY_RUN=1: Preview what will be done without making changes
#    - preflight_print: Shows all network config before any changes
#    - sanity_check_iface: Verifies DEFAULT_IFACE exists
#    - assert_tap_ip_scope: Ensures TAP_IP is only on TAP_DEV (not leaked)
#    - assert_no_arp_on_default_iface: 10s tcpdump check for ARP involving
#      TAP_IP on the wrong interface - detects the exact failure mode that
#      caused the CloudLab quarantine
#    - trap inline_cleanup ERR: Auto-cleanup on failure to avoid leaving
#      partial networking state
#
# 10) Safe workflow for CloudLab
#    a) First run:  sudo DRY_RUN=1 ./install_firecracker.sh
#    b) Review output, verify DEFAULT_IFACE and IPs look correct
#    c) If OK:      sudo ./install_firecracker.sh
# =============================================================================
