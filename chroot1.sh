#!/bin/bash
set -e

# Configuration
CHROOT_PATH="/mnt/gentoo"

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root."
  exit 1
fi

echo "==> Preparing chroot environment at $CHROOT_PATH..."

# Copy DNS configuration so the chroot has internet access
cp --dereference /etc/resolv.conf "$CHROOT_PATH/etc/"

# Mount pseudo-filesystems
mount --types proc /proc "$CHROOT_PATH/proc"
mount --rbind /sys "$CHROOT_PATH/sys"
mount --make-rslave "$CHROOT_PATH/sys"
mount --rbind /dev "$CHROOT_PATH/dev"
mount --make-rslave "$CHROOT_PATH/dev"
mount --bind /run "$CHROOT_PATH/run"
mount --make-slave "$CHROOT_PATH/run"

# Optional: Mount shm explicitly if needed by some live media
if [ -d /dev/shm ] && [ ! -L /dev/shm ]; then
  mount --rbind /dev/shm "$CHROOT_PATH/dev/shm"
fi

echo "==> Entering chroot. Run './chroot_tasks.sh' inside if setup is needed."
echo "==> Type 'exit' when finished to return to the host."

# Enter the chroot using bash
chroot "$CHROOT_PATH" /bin/bash --login

# --- Clean up after exiting chroot ---
echo "==> Exited chroot. Cleaning up mounts..."
umount -l "$CHROOT_PATH/dev{/shm,/pts,}" || true
umount -R "$CHROOT_PATH/sys" || true
umount -R "$CHROOT_PATH/proc" || true
umount -R "$CHROOT_PATH/run" || true
echo "==> Clean up complete."
