#!/usr/bin/env bash
# =============================================================================
# CloudLab-safe Cloud Hypervisor bootstrap (install + networking)
#
# Goals:
#  - Install Cloud Hypervisor (pinned version), kernel, rootfs
#  - Bring up a TAP interface on a SAFE RFC1918 subnet (default 192.168.100.0/30)
#  - Enable NAT so the VM can reach the internet
#  - Be *idempotent*: rerunning should not stack iptables rules or break state
#  - Be *reversible*: provide cleanup that removes only what we added
#
# IMPORTANT CLOUDLAB NOTE:
#  - DO NOT use 172.16.0.0/12 on CloudLab; it overlaps their control network.
#  - This script defaults to 192.168.100.0/30.
#
# Run with: sudo ./install_cloud_hypervisor.sh
# =============================================================================

set -euo pipefail

# ---------------------------
# User-configurable settings
# ---------------------------

WORKDIR="${WORKDIR:-/opt/cloud-hypervisor}"

# Network config (safe defaults — identical to Firecracker setup)
TAP_DEV="${TAP_DEV:-tap0}"
SUBNET_CIDR="${SUBNET_CIDR:-192.168.100.0/30}"
TAP_IP="${TAP_IP:-}"
FC_IP="${FC_IP:-}"  # guest IP (kept as FC_IP for env compat with run scripts)
DEFAULT_IFACE="${DEFAULT_IFACE:-}"

# Cloud Hypervisor version + architecture
CH_VERSION="${CH_VERSION:-v43.0}"
ARCH="$(uname -m)"

# Download URLs
CH_RELEASE_URL="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/${CH_VERSION}/cloud-hypervisor-static"
ROOTFS_URL="${ROOTFS_URL:-https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.9/${ARCH}/ubuntu-22.04.ext4}"

# iptables chain names we own (so we can remove cleanly)
CH_NAT_CHAIN="CH_NAT"
CH_FWD_CHAIN="CH_FWD"

# State file to restore sysctls
IPFWD_STATE_FILE="/run/cloud_hypervisor_ip_forward.prev"

# Safety options
DRY_RUN="${DRY_RUN:-0}"
RUN_ARP_TEST="${RUN_ARP_TEST:-1}"

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n[cloud-hypervisor-setup] $*\n"; }

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

derive_ips_from_cidr() {
  if [[ -n "${TAP_IP}" && -n "${FC_IP}" ]]; then
    return
  fi

  local base="${SUBNET_CIDR%/*}"
  local prefix="${SUBNET_CIDR#*/}"

  [[ "${prefix}" == "30" ]] || die "This script currently expects /30 by default. Set TAP_IP and FC_IP explicitly if you want a different prefix."

  if [[ ! "${base}" =~ \.0$ ]]; then
    die "SUBNET_CIDR base should end in .0 for /30 (e.g., 192.168.100.0/30). Got: ${SUBNET_CIDR}"
  fi

  local base_prefix="${base%.0}."
  TAP_IP="${TAP_IP:-${base_prefix}1}"
  FC_IP="${FC_IP:-${base_prefix}2}"
}

cloudlab_safety_checks() {
  if [[ "${TAP_IP}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    die "TAP_IP=${TAP_IP} is in 172.16.0.0/12 which is NOT CloudLab-safe. Use 192.168.x.x or 10.x.x.x."
  fi
  if [[ "${FC_IP}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    die "FC_IP=${FC_IP} is in 172.16.0.0/12 which is NOT CloudLab-safe. Use 192.168.x.x or 10.x.x.x."
  fi
  if [[ "${TAP_IP}" =~ ^169\.254\. || "${FC_IP}" =~ ^169\.254\. ]]; then
    die "169.254.0.0/16 is link-local; do not use it here."
  fi
}

detect_default_iface() {
  if [[ -n "${DEFAULT_IFACE}" ]]; then
    return
  fi
  if has_cmd jq; then
    DEFAULT_IFACE="$(ip -j route list default | jq -r '.[0].dev' 2>/dev/null || true)"
  fi
  if [[ -z "${DEFAULT_IFACE}" || "${DEFAULT_IFACE}" == "null" ]]; then
    DEFAULT_IFACE="$(ip route list default | awk '{print $5; exit}' || true)"
  fi
  [[ -n "${DEFAULT_IFACE}" ]] || die "Could not auto-detect DEFAULT_IFACE. Set DEFAULT_IFACE=ens3 (or similar) and rerun."
}

preflight_print() {
  log "Preflight"
  echo "  TAP_DEV=${TAP_DEV}"
  echo "  SUBNET_CIDR=${SUBNET_CIDR}"
  echo "  TAP_IP=${TAP_IP}"
  echo "  FC_IP=${FC_IP}"
  echo "  DEFAULT_IFACE=${DEFAULT_IFACE}"
}

sanity_check_iface() {
  ip link show "${DEFAULT_IFACE}" >/dev/null 2>&1 || die "DEFAULT_IFACE ${DEFAULT_IFACE} not found"
  echo "  DEFAULT_IFACE info:"
  ip -br addr show "${DEFAULT_IFACE}" | sed 's/^/    /'
}

assert_tap_ip_scope() {
  local dev
  dev="$(ip -o addr show | awk -v ip="${TAP_IP}" '$0 ~ ip {print $2; exit}')"
  [[ "${dev}" == "${TAP_DEV}" ]] || die "TAP_IP ${TAP_IP} appears on ${dev} (expected ${TAP_DEV}). Refusing to continue."
}

assert_no_arp_on_default_iface() {
  if [[ "${RUN_ARP_TEST}" != "1" ]]; then
    echo "  Skipping ARP test (RUN_ARP_TEST != 1)"
    return
  fi
  log "ARP safety check (10s) - checking for dangerous ARP on ${DEFAULT_IFACE}"
  if timeout 10 tcpdump -n -c 1 -i "${DEFAULT_IFACE}" "arp and host ${TAP_IP}" 2>/dev/null; then
    die "Saw ARP involving TAP_IP (${TAP_IP}) on ${DEFAULT_IFACE}. This is dangerous on CloudLab!"
  fi
  echo "  ARP check passed (no TAP_IP ARP seen on ${DEFAULT_IFACE})"
}

inline_cleanup() {
  echo "ERROR: script failed; cleaning up networking state..."
  ip link del "${TAP_DEV}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j "${CH_NAT_CHAIN}" 2>/dev/null || true
  iptables -D FORWARD -j "${CH_FWD_CHAIN}" 2>/dev/null || true
  iptables -t nat -F "${CH_NAT_CHAIN}" 2>/dev/null || true
  iptables -t nat -X "${CH_NAT_CHAIN}" 2>/dev/null || true
  iptables -F "${CH_FWD_CHAIN}" 2>/dev/null || true
  iptables -X "${CH_FWD_CHAIN}" 2>/dev/null || true
  if [[ -f "${IPFWD_STATE_FILE}" ]]; then
    cat "${IPFWD_STATE_FILE}" > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    rm -f "${IPFWD_STATE_FILE}" || true
  fi
  echo "Cleanup attempted."
}

iptables_add_once() {
  local table="$1"; shift
  if iptables -t "${table}" -C "$@" 2>/dev/null; then
    return
  fi
  iptables -t "${table}" -A "$@"
}

iptables_insert_once() {
  local table="$1"; local chain="$2"; shift 2
  if iptables -t "${table}" -C "${chain}" "$@" 2>/dev/null; then
    return
  fi
  iptables -t "${table}" -I "${chain}" 1 "$@"
}

ensure_iptables_chains() {
  iptables -t nat -N "${CH_NAT_CHAIN}" 2>/dev/null || true
  iptables -N "${CH_FWD_CHAIN}" 2>/dev/null || true
  iptables_insert_once nat POSTROUTING -j "${CH_NAT_CHAIN}"
  iptables_insert_once filter FORWARD -j "${CH_FWD_CHAIN}"
}

configure_nat_and_forwarding() {
  log "Configuring IP forwarding + iptables (idempotent, reversible)"

  if [[ ! -f "${IPFWD_STATE_FILE}" ]]; then
    cat /proc/sys/net/ipv4/ip_forward > "${IPFWD_STATE_FILE}" || true
  fi

  echo 1 > /proc/sys/net/ipv4/ip_forward

  ensure_iptables_chains

  iptables_add_once nat "${CH_NAT_CHAIN}" -o "${DEFAULT_IFACE}" -j MASQUERADE
  iptables_add_once filter "${CH_FWD_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables_add_once filter "${CH_FWD_CHAIN}" -i "${TAP_DEV}" -o "${DEFAULT_IFACE}" -j ACCEPT
  iptables_add_once filter "${CH_FWD_CHAIN}" -i "${DEFAULT_IFACE}" -o "${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

setup_tap() {
  log "Setting up TAP device ${TAP_DEV} with ${TAP_IP}/${SUBNET_CIDR#*/}"
  ip link del "${TAP_DEV}" 2>/dev/null || true
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

install_cloud_hypervisor() {
  log "Installing Cloud Hypervisor ${CH_VERSION} (${ARCH})"
  mkdir -p "${WORKDIR}"

  curl -fsSL "${CH_RELEASE_URL}" -o "${WORKDIR}/cloud-hypervisor"
  chmod +x "${WORKDIR}/cloud-hypervisor"
  install -m 0755 "${WORKDIR}/cloud-hypervisor" /usr/local/bin/cloud-hypervisor

  /usr/local/bin/cloud-hypervisor --version || true
}

download_kernel_rootfs() {
  log "Setting up kernel + rootfs"
  mkdir -p "${WORKDIR}"

  # Use the host kernel (bzImage) — Cloud Hypervisor supports bzImage directly.
  # Ubuntu 22.04's kernel 5.15 has virtio-pci, ACPI, and all needed drivers.
  local host_kernel="/boot/vmlinuz-$(uname -r)"
  local host_initrd="/boot/initrd.img-$(uname -r)"

  if [[ -f "${host_kernel}" ]]; then
    cp -f "${host_kernel}" "${WORKDIR}/vmlinuz"
    log "Copied host kernel: ${host_kernel}"
  else
    die "Host kernel not found at ${host_kernel}. Install with: apt install linux-image-$(uname -r)"
  fi

  if [[ -f "${host_initrd}" ]]; then
    cp -f "${host_initrd}" "${WORKDIR}/initrd.img"
    log "Copied host initramfs: ${host_initrd}"
  else
    log "WARNING: No initramfs found at ${host_initrd}. Boot may fail if virtio modules aren't built-in."
  fi

  # Rootfs — same base image as Firecracker (raw ext4)
  log "Downloading base rootfs"
  curl -fsSL "${ROOTFS_URL}" -o "${WORKDIR}/rootfs.ext4"

  # Working copy
  cp -f "${WORKDIR}/rootfs.ext4" "${WORKDIR}/rootfs-vm.ext4"
}

write_helper_scripts() {
  log "Writing helper scripts"

  local prefix="${SUBNET_CIDR#*/}"
  local netmask_long
  if [[ "${prefix}" == "30" ]]; then
    netmask_long="255.255.255.252"
  else
    die "Prefix /${prefix} not supported in dotted netmask mapping. Use /30 or extend mapping."
  fi

  # Quick start VM script
  cat > "${WORKDIR}/start_vm.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR}"

# Reset rootfs for clean boot each time
cp -f "\${WORKDIR}/rootfs.ext4" "\${WORKDIR}/rootfs-vm.ext4"

echo
echo "Starting Cloud Hypervisor VM..."
echo "  Console exit: Ctrl+A then X"
echo

exec /usr/local/bin/cloud-hypervisor \\
  --kernel "\${WORKDIR}/vmlinuz" \\
  --initramfs "\${WORKDIR}/initrd.img" \\
  --disk path="\${WORKDIR}/rootfs-vm.ext4" \\
  --cmdline "console=ttyS0 root=/dev/vda rw ip=${FC_IP}::${TAP_IP}:${netmask_long}::eth0:off" \\
  --cpus boot=2 \\
  --memory size=1024M \\
  --net "tap=${TAP_DEV},mac=AA:CH:00:00:00:01" \\
  --serial tty \\
  --console off
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
CH_NAT_CHAIN="${CH_NAT_CHAIN}"
CH_FWD_CHAIN="${CH_FWD_CHAIN}"
IPFWD_STATE_FILE="${IPFWD_STATE_FILE}"

if [[ "\${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo \${0}"
  exit 1
fi

if [[ -z "\${DEFAULT_IFACE}" ]] || ! ip link show "\${DEFAULT_IFACE}" &>/dev/null; then
  DEFAULT_IFACE="\$(ip route list default | awk '{print \$5; exit}' || true)"
  [[ -n "\${DEFAULT_IFACE}" ]] || { echo "ERROR: Could not detect default interface"; exit 1; }
  echo "Detected DEFAULT_IFACE=\${DEFAULT_IFACE}"
fi

ip link del "\${TAP_DEV}" 2>/dev/null || true
ip tuntap add dev "\${TAP_DEV}" mode tap
ip addr add "\${TAP_IP}/\${SUBNET_CIDR#*/}" dev "\${TAP_DEV}"
ip link set dev "\${TAP_DEV}" up

echo "Running CloudLab safety checks..."
_tap_ip_dev="\$(ip -o addr show | awk -v ip="\${TAP_IP}" '\$0 ~ ip {print \$2; exit}')"
if [[ "\${_tap_ip_dev}" != "\${TAP_DEV}" ]]; then
  echo "ERROR: TAP_IP \${TAP_IP} appears on \${_tap_ip_dev} (expected \${TAP_DEV}). Refusing to continue."
  exit 1
fi
echo "  TAP_IP scope check passed (only on \${TAP_DEV})"

echo "  ARP safety check (10s)..."
if timeout 10 tcpdump -n -c 1 -i "\${DEFAULT_IFACE}" "arp and host \${TAP_IP}" 2>/dev/null; then
  echo "ERROR: Saw ARP involving TAP_IP (\${TAP_IP}) on \${DEFAULT_IFACE}. This is dangerous on CloudLab!"
  exit 1
fi
echo "  ARP check passed"

if [[ ! -f "\${IPFWD_STATE_FILE}" ]]; then
  cat /proc/sys/net/ipv4/ip_forward > "\${IPFWD_STATE_FILE}" || true
fi
echo 1 > /proc/sys/net/ipv4/ip_forward

iptables -t nat -N "\${CH_NAT_CHAIN}" 2>/dev/null || true
iptables -N "\${CH_FWD_CHAIN}" 2>/dev/null || true

iptables -t nat -C POSTROUTING -j "\${CH_NAT_CHAIN}" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "\${CH_NAT_CHAIN}"
iptables -C FORWARD -j "\${CH_FWD_CHAIN}" 2>/dev/null || iptables -I FORWARD 1 -j "\${CH_FWD_CHAIN}"

iptables -t nat -C "\${CH_NAT_CHAIN}" -o "\${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || iptables -t nat -A "\${CH_NAT_CHAIN}" -o "\${DEFAULT_IFACE}" -j MASQUERADE
iptables -C "\${CH_FWD_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A "\${CH_FWD_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -C "\${CH_FWD_CHAIN}" -i "\${TAP_DEV}" -o "\${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null || iptables -A "\${CH_FWD_CHAIN}" -i "\${TAP_DEV}" -o "\${DEFAULT_IFACE}" -j ACCEPT
iptables -C "\${CH_FWD_CHAIN}" -i "\${DEFAULT_IFACE}" -o "\${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A "\${CH_FWD_CHAIN}" -i "\${DEFAULT_IFACE}" -o "\${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "Network setup complete."
EOF
  chmod +x "${WORKDIR}/setup_network.sh"

  # Cleanup script
  cat > "${WORKDIR}/cleanup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="${TAP_DEV}"
CH_NAT_CHAIN="${CH_NAT_CHAIN}"
CH_FWD_CHAIN="${CH_FWD_CHAIN}"
IPFWD_STATE_FILE="${IPFWD_STATE_FILE}"

if [[ "\${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo \${0}"
  exit 1
fi

ip link del "\${TAP_DEV}" 2>/dev/null || true
iptables -t nat -D POSTROUTING -j "\${CH_NAT_CHAIN}" 2>/dev/null || true
iptables -D FORWARD -j "\${CH_FWD_CHAIN}" 2>/dev/null || true
iptables -t nat -F "\${CH_NAT_CHAIN}" 2>/dev/null || true
iptables -t nat -X "\${CH_NAT_CHAIN}" 2>/dev/null || true
iptables -F "\${CH_FWD_CHAIN}" 2>/dev/null || true
iptables -X "\${CH_FWD_CHAIN}" 2>/dev/null || true

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
  echo "CloudLab-safe Cloud Hypervisor setup complete"
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

preflight_print
sanity_check_iface

if [[ "${DRY_RUN}" == "1" ]]; then
  echo
  echo "DRY_RUN=1, exiting before making changes."
  echo "If the above looks correct, rerun without DRY_RUN."
  exit 0
fi

log "Plan:"
echo "  - Install Cloud Hypervisor ${CH_VERSION} (${ARCH})"
echo "  - Copy host kernel + initramfs into ${WORKDIR}"
echo "  - Download rootfs into ${WORKDIR}"
echo "  - Setup TAP ${TAP_DEV} at ${TAP_IP} on ${SUBNET_CIDR}"
echo "  - NAT guest ${FC_IP} to internet via ${DEFAULT_IFACE}"
echo

trap inline_cleanup ERR

install_cloud_hypervisor
download_kernel_rootfs
setup_tap

assert_tap_ip_scope

configure_nat_and_forwarding

assert_no_arp_on_default_iface

trap - ERR

write_helper_scripts
print_summary
