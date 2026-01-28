sudo apt-get update
sudo apt-get install -y debootstrap e2fsprogs

sudo mkdir -p /opt/firecracker /mnt/fc-rootfs
cd /opt/firecracker

sudo dd if=/dev/zero of=rootfs-ubuntu22.ext4 bs=1M count=2048
sudo mkfs.ext4 -F rootfs-ubuntu22.ext4
sudo mount -o loop rootfs-ubuntu22.ext4 /mnt/fc-rootfs
sudo debootstrap --arch=amd64 jammy /mnt/fc-rootfs http://archive.ubuntu.com/ubuntu
sudo umount /mnt/fc-rootfs