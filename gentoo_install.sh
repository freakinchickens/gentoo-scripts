#!/bin/bash
# Host script to prepare the environment and download Stage 3

set -e

# Define targets (Adjust to match your actual partitions!)
ROOT_PART="/dev/sda3"
BOOT_PART="/dev/sda1"
TARGET_MNT="/mnt/gentoo"

echo "Formatting and mounting partitions..."
mkfs.ext4 -F "$ROOT_PART"
mkdir -p "$TARGET_MNT"
mount "$ROOT_PART" "$TARGET_MNT"

cd "$TARGET_MNT"

echo "Fetching latest Stage 3 tarball..."
# Automatically discovers and grabs the latest OpenRC tarball
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc/ | grep -oP 'stage3-amd64-openrc-\d{8}T\d{6}Z\.tar\.xz' | head -n 1)
wget "https://gentoo.org"

echo "Unpacking Stage 3..."
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3-*.tar.xz

echo "Copying DNS details..."
cp --dereference /etc/resolv.conf "$TARGET_MNT/etc/"

echo "Mounting system filesystems..."
mount --types proc /proc "$TARGET_MNT/proc"
mount --rbind /sys "$TARGET_MNT/sys"
mount --make-rslave "$TARGET_MNT/sys"
mount --rbind /dev "$TARGET_MNT/dev"
mount --make-rslave "$TARGET_MNT/dev"
mount --bind /run "$TARGET_MNT/run"
mount --make-private "$TARGET_MNT/run"

# Mount boot partition inside the target
mkdir -p "$TARGET_MNT/boot"
mkfs.vfat -F 32 "$BOOT_PART"
mount "$BOOT_PART" "$TARGET_MNT/boot"

echo "Copying internal configuration script..."
cat << 'EOF' > "$TARGET_MNT/chroot_install.sh"
#!/bin/bash
set -e

source /etc/profile
export PS1="(chroot) $PS1"

echo "Syncing Portage repository..."
emerge-webrsync

echo "Setting profile (Default OpenRC)..."
eselect profile set 1

echo "Configuring timezone and locale..."
echo "America/New_York" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8

echo "Installing distribution kernel and GRUB..."
# Installs a pre-compiled generic kernel to speed up installation
emerge --ask=n sys-kernel/gentoo-kernel-bin sys-boot/grub

echo "Installing bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

echo "Base system ready! Set your root password now:"
passwd

exit
EOF

chmod +x "$TARGET_MNT/chroot_install.sh"

echo "Entering chroot environment..."
chroot "$TARGET_MNT" /bin/bash /chroot_install.sh

echo "Done! Clean up the installation script, unmount, and reboot."
