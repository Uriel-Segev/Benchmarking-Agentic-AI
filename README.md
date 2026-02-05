# Benchmarking-Agentic-AI

This repo runs terminal-bench tasks inside Firecracker microVMs and measures how long each phase takes.

## Files

- **install_firecracker.sh** — Downloads the Firecracker binary and a Linux kernel. Creates a TAP network device (tap0) and configures iptables for VM internet access.

- **setup_base_rootfs.sh** — Creates a 2GB ext4 disk image and installs Ubuntu 22.04 into it using debootstrap. Configures systemd and serial console for Firecracker boot.

- **prepare_task_rootfs.sh** — Copies the base rootfs, installs Python and pytest inside it, copies task files (task.yaml, solution.sh, test files) into /app, and creates an autorun.sh script that runs on VM boot.

- **run_task.sh** — Launches a single Firecracker VM with a prepared rootfs. Waits for the VM to shut itself down. Mounts the rootfs afterward and extracts results.json and timing data.

- **run_parallel.sh** — Creates N copies of a rootfs, creates N TAP devices, launches N run_task.sh processes in parallel, waits for all to finish, and aggregates the results into parallel_results.json with timing statistics.

- **commands_to_run.txt** — Notes and example commands.

- **after_install_commands.sh** — Unused. Superseded by setup_base_rootfs.sh.

## Commands

```bash
# One-time setup
sudo ./install_firecracker.sh
sudo ./setup_base_rootfs.sh

# Get task files
mkdir -p terminal-bench/original-tasks/hello-world
cd terminal-bench/original-tasks/hello-world
curl -O https://raw.githubusercontent.com/laude-institute/terminal-bench/main/original-tasks/hello-world/task.yaml
curl -O https://raw.githubusercontent.com/laude-institute/terminal-bench/main/original-tasks/hello-world/solution.sh
curl -O https://raw.githubusercontent.com/laude-institute/terminal-bench/main/original-tasks/hello-world/test_outputs.py
cd ../../..

# Run 4 VMs in parallel
sudo ./run_parallel.sh terminal-bench/original-tasks/hello-world 4
```

Results are written to parallel_results.json.
