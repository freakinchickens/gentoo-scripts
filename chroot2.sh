#!/bin/bash
set -e

echo "==> Initializing environment variables..."
source /etc/profile
export PS1="(chroot) $PS1"

echo "==> Synchronizing Portage snapshot..."
emerge-webrsync

echo "==> Setting up local timezone..."
# Adjust to your region (e.g., America/New_York)
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "==> Setting up locale..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set $(eselect locale list | grep "en_US.utf8" | awk '{print $1}' | tr -d '[]')

echo "==> Environment ready for package compilation!"
