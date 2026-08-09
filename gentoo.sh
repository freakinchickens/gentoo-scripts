#!/bin/bash
set -e

# Configuration Variables
TARGET_DISK="/dev/sda"
ROOT_MOUNT="/mnt/gentoo"
STAGE3_URL="https://gentoo.org"
TIMEZONE="UTC"

echo "==> Preparing partition layout on $TARGET_DISK..."
parted --script "$TARGET_DISK" \
  mklabel gpt \
  mkpart primary ext4 1MiB 2MiB \
  set 1 bios_grub on \
  mkpart primary ext4 2MiB 100%

echo "==> Formatting root partition..."
mkfs.ext4 -f "${TARGET_DISK}2"

echo "==> Mounting filesystems..."
mkdir -p "$ROOT_MOUNT"
mount "${TARGET_DISK}2" "$ROOT_MOUNT"

echo "==> Downloading and extracting Stage3 tarball..."
cd "$ROOT_MOUNT"
# Auto-fetch latest stage3 and extract
wget -O - $(curl -s https://gentoo.org | tail -n 1 | awk '{print $1}') | tar xJpf - --xattrs-include='*.*' --numeric-owner

echo "==> Copying resolv.conf for network access in chroot..."
cp --dereference /etc/resolv.conf "$ROOT_MOUNT/etc/"

echo "==> Mounting pseudo-filesystems and entering chroot..."
mount --types proc /proc "$ROOT_MOUNT/proc"
mount --rbind /sys "$ROOT_MOUNT/sys"
mount --make-rslave "$ROOT_MOUNT/sys"
mount --rbind /dev "$ROOT_MOUNT/dev"
mount --make-rslave "$ROOT_MOUNT/dev"

chroot "$ROOT_MOUNT" /bin/bash << 'CHROOT_EOF'
# Inside Chroot environment
source /etc/profile
export PS1="(chroot) $PS1"

echo "==> Updating Portage repository..."
emerge-webrsync

echo "==> Selecting profile and setting timezone..."
eselect profile set 1
ln -sf "../usr/share/zoneinfo/UTC" /etc/localtime

echo "==> Installing kernel (genkernel)..."
emerge --sync
emerge -uDN @world
emerge sys-kernel/gentoo-sources sys-kernel/genkernel
genkernel all

echo "==> Installing system bootloader (GRUB)..."
emerge sys-boot/grub
grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

echo "==> System base install complete inside chroot!"
CHROOT_EOF

echo "==> Installation complete! Unmount and reboot when ready."
