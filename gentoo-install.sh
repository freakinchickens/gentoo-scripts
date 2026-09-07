#!/bin/bash
#
# gentoo-install.sh
#
# An automated Gentoo installer, structured after the workflow popularized by
# oddlama/gentoo-install (https://github.com/oddlama/gentoo-install):
#   - single config block up top, rest of the script just executes it
#   - UEFI + GPT layout
#   - optional full-disk LUKS2 encryption
#   - btrfs root with subvolumes (@, @home, @log, @snapshots) or plain ext4
#   - systemd-boot as the bootloader
#   - runs from a Gentoo minimal install / live CD
#
# This is an ORIGINAL script written to follow that project's general
# approach and layout choices. It is not a copy of oddlama's code, and it
# doesn't have the TUI/menuconfig interface or the OpenRC/mdraid/zfs paths
# that project supports -- it's a leaner, systemd + btrfs/ext4 + LUKS only
# variant you can extend.
#
# USAGE:
#   1. Boot the Gentoo minimal/live ISO, connect to the network.
#   2. Edit the CONFIG section below (or export the same variables before
#      running, they'll be respected either way).
#   3. bash gentoo-install.sh
#
# The script is idempotent-ish but NOT safe to re-run blindly against a disk
# that already has data you care about. It will wipe $DISK.

set -uo pipefail

################################################################################
# CONFIG -- edit this block
################################################################################

: "${DISK:=/dev/sda}"                 # whole disk to install to, e.g. /dev/nvme0n1
: "${HOSTNAME:=gentoo}"
: "${TIMEZONE:=UTC}"                  # e.g. Europe/Berlin
: "${KEYMAP:=us}"
: "${LOCALE:=en_US.UTF-8 UTF-8}"
: "${USERNAME:=user}"
: "${USE_ENCRYPTION:=yes}"            # yes/no -- LUKS2 on the root partition
: "${ROOT_FS:=btrfs}"                 # btrfs or ext4
: "${SWAP_SIZE:=4G}"                  # 0 to disable swap (swapfile on btrfs, or partition on ext4)
: "${ESP_SIZE:=512M}"
: "${STAGE3_VARIANT:=stage3-amd64-systemd}"
: "${GENTOO_MIRROR:=https://distfiles.gentoo.org}"
: "${GENTOO_ARCH_PATH:=releases/amd64/autobuilds}"
: "${PORTAGE_MAKE_PARALLELISM:=$(nproc)}"

# Derived partition names get set once we know if $DISK is nvme-style
ESP_PART=""
ROOT_PART=""

################################################################################
# helpers
################################################################################

c_red="\e[31m"; c_green="\e[32m"; c_yellow="\e[33m"; c_reset="\e[0m"

log()   { echo -e "${c_green}[*]${c_reset} $*"; }
warn()  { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()   { echo -e "${c_red}[FATAL]${c_reset} $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this as root from the Gentoo live/install environment."
}

require_uefi() {
    [[ -d /sys/firmware/efi ]] || die "System is not booted in UEFI mode. This script only does UEFI + systemd-boot."
}

confirm_wipe() {
    warn "This will COMPLETELY ERASE ${DISK}. All data on it will be lost."
    read -r -p "Type 'yes' to continue: " reply
    [[ $reply == "yes" ]] || die "Aborted by user."
}

partname() {
    # nvme/mmc devices need a 'p' before the partition number
    local disk=$1 num=$2
    if [[ $disk =~ (nvme|mmcblk) ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

chroot_run() {
    chroot /mnt/gentoo /bin/bash -c "$1"
}

################################################################################
# 1. partitioning
################################################################################

do_partition() {
    log "Partitioning ${DISK} (GPT: ESP + root)..."
    parted -s "$DISK" -- \
        mklabel gpt \
        mkpart ESP fat32 1MiB "$ESP_SIZE" \
        set 1 esp on \
        mkpart primary "$ESP_SIZE" 100%

    partprobe "$DISK"
    sleep 2

    ESP_PART=$(partname "$DISK" 1)
    ROOT_PART=$(partname "$DISK" 2)

    log "ESP:  $ESP_PART"
    log "ROOT: $ROOT_PART"

    mkfs.fat -F32 -n EFI "$ESP_PART"
}

################################################################################
# 2. encryption
################################################################################

setup_encryption() {
    if [[ $USE_ENCRYPTION == yes ]]; then
        log "Setting up LUKS2 on ${ROOT_PART}..."
        cryptsetup luksFormat --type luks2 --label gentoo_crypt "$ROOT_PART"
        cryptsetup open "$ROOT_PART" gentoo_root
        MAPPED_ROOT=/dev/mapper/gentoo_root
    else
        MAPPED_ROOT=$ROOT_PART
    fi
}

################################################################################
# 3. filesystems + mounting
################################################################################

setup_filesystems() {
    if [[ $ROOT_FS == btrfs ]]; then
        log "Creating btrfs on ${MAPPED_ROOT} with subvolumes..."
        mkfs.btrfs -f -L gentoo "$MAPPED_ROOT"
        mount "$MAPPED_ROOT" /mnt/gentoo

        for sv in @ @home @log @snapshots; do
            btrfs subvolume create "/mnt/gentoo/$sv"
        done
        umount /mnt/gentoo

        local opts="noatime,compress=zstd,ssd"
        mount -o "${opts},subvol=@" "$MAPPED_ROOT" /mnt/gentoo
        mkdir -p /mnt/gentoo/{home,var/log,.snapshots,boot}
        mount -o "${opts},subvol=@home" "$MAPPED_ROOT" /mnt/gentoo/home
        mount -o "${opts},subvol=@log" "$MAPPED_ROOT" /mnt/gentoo/var/log
        mount -o "${opts},subvol=@snapshots" "$MAPPED_ROOT" /mnt/gentoo/.snapshots
    else
        log "Creating ext4 on ${MAPPED_ROOT}..."
        mkfs.ext4 -F -L gentoo "$MAPPED_ROOT"
        mount "$MAPPED_ROOT" /mnt/gentoo
        mkdir -p /mnt/gentoo/boot
    fi

    mkdir -p /mnt/gentoo/boot/efi
    mount "$ESP_PART" /mnt/gentoo/boot/efi

    if [[ $SWAP_SIZE != 0 ]]; then
        if [[ $ROOT_FS == btrfs ]]; then
            log "Creating ${SWAP_SIZE} swapfile on btrfs..."
            btrfs filesystem mkswapfile --size "$SWAP_SIZE" /mnt/gentoo/swapfile 2>/dev/null \
                || { truncate -s 0 /mnt/gentoo/swapfile; chattr +C /mnt/gentoo/swapfile; \
                     fallocate -l "$SWAP_SIZE" /mnt/gentoo/swapfile; \
                     chmod 600 /mnt/gentoo/swapfile; mkswap /mnt/gentoo/swapfile; }
        else
            fallocate -l "$SWAP_SIZE" /mnt/gentoo/swapfile
            chmod 600 /mnt/gentoo/swapfile
            mkswap /mnt/gentoo/swapfile
        fi
        swapon /mnt/gentoo/swapfile || warn "Could not swapon now, will still be enabled via fstab."
    fi
}

################################################################################
# 4. stage3
################################################################################

fetch_stage3() {
    log "Locating latest ${STAGE3_VARIANT} stage3..."
    local list_url="${GENTOO_MIRROR}/${GENTOO_ARCH_PATH}/latest-${STAGE3_VARIANT}.txt"
    local rel_path
    rel_path=$(curl -fsSL "$list_url" | grep -v '^#' | awk '{print $1}' | head -n1)
    [[ -n $rel_path ]] || die "Could not resolve latest stage3 path from $list_url"

    local tarball_url="${GENTOO_MIRROR}/${GENTOO_ARCH_PATH}/${rel_path}"
    log "Downloading $tarball_url"
    curl -fL --progress-bar -o /mnt/gentoo/stage3.tar.xz "$tarball_url"

    log "Extracting stage3..."
    tar xpf /mnt/gentoo/stage3.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
    rm -f /mnt/gentoo/stage3.tar.xz
}

################################################################################
# 5. chroot prep
################################################################################

prepare_chroot() {
    log "Configuring portage and mounting pseudo-filesystems..."
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /mnt/gentoo/usr/share/portage/config/repos.conf \
        /mnt/gentoo/etc/portage/repos.conf/gentoo.conf 2>/dev/null || true

    cat >> /mnt/gentoo/etc/portage/make.conf <<EOF

COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${PORTAGE_MAKE_PARALLELISM}"
EMERGE_DEFAULT_OPTS="--jobs=2 --load-average=$(nproc)"
ACCEPT_LICENSE="*"
GRUB_PLATFORMS="efi-64"
EOF

    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run
}

################################################################################
# 6. base system config (inside chroot)
################################################################################

configure_base_system() {
    log "Syncing portage tree (this can take a while)..."
    chroot_run "emerge-webrsync"

    log "Setting timezone, locale, keymap..."
    chroot_run "echo '${TIMEZONE}' > /etc/timezone && emerge --config sys-libs/timezone-data"
    echo "$LOCALE" >> /mnt/gentoo/etc/locale.gen
    chroot_run "locale-gen"
    chroot_run "eselect locale list | grep -qi '${LOCALE%% *}' && eselect locale set '${LOCALE%% *}' || true"
    echo "keymap=\"${KEYMAP}\"" > /mnt/gentoo/etc/conf.d/keymaps

    log "Installing kernel + firmware + core tools..."
    chroot_run "emerge --quiet-build sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware \
        sys-boot/systemd-boot sys-apps/systemd sys-fs/btrfs-progs cryptsetup \
        net-misc/dhcpcd sys-apps/pciutils sudo vim"

    log "Writing fstab..."
    write_fstab

    log "Setting hostname..."
    echo "$HOSTNAME" > /mnt/gentoo/etc/hostname

    log "Configuring bootloader (systemd-boot)..."
    configure_bootloader

    log "Creating user '${USERNAME}' and setting passwords..."
    chroot_run "useradd -m -G wheel,users,audio,video -s /bin/bash ${USERNAME}"
    echo "%wheel ALL=(ALL:ALL) ALL" >> /mnt/gentoo/etc/sudoers

    echo "Set the ROOT password:"
    chroot /mnt/gentoo /bin/passwd
    echo "Set the password for ${USERNAME}:"
    chroot /mnt/gentoo /bin/passwd "$USERNAME"

    chroot_run "systemctl enable systemd-networkd systemd-resolved dhcpcd 2>/dev/null || rc-update add dhcpcd default 2>/dev/null || true"
}

write_fstab() {
    local root_uuid esp_uuid crypt_uuid fstab=/mnt/gentoo/etc/fstab
    esp_uuid=$(blkid -s UUID -o value "$ESP_PART")

    {
        echo "# <fs>            <mountpoint>  <type>  <opts>                          <dump/pass>"
        echo "UUID=${esp_uuid}  /boot/efi     vfat    defaults,noatime                0 2"

        if [[ $ROOT_FS == btrfs ]]; then
            root_uuid=$(blkid -s UUID -o value "$MAPPED_ROOT")
            echo "UUID=${root_uuid}  /            btrfs   noatime,compress=zstd,subvol=@         0 0"
            echo "UUID=${root_uuid}  /home        btrfs   noatime,compress=zstd,subvol=@home     0 0"
            echo "UUID=${root_uuid}  /var/log     btrfs   noatime,compress=zstd,subvol=@log      0 0"
            echo "UUID=${root_uuid}  /.snapshots  btrfs   noatime,compress=zstd,subvol=@snapshots 0 0"
        else
            root_uuid=$(blkid -s UUID -o value "$MAPPED_ROOT")
            echo "UUID=${root_uuid}  /            ext4    noatime                          0 1"
        fi

        if [[ $SWAP_SIZE != 0 ]]; then
            echo "/swapfile          none         swap    sw                               0 0"
        fi
    } > "$fstab"
}

configure_bootloader() {
    chroot_run "bootctl install --path=/boot/efi"

    local kernel_cmdline
    if [[ $USE_ENCRYPTION == yes ]]; then
        crypt_uuid=$(blkid -s UUID -o value "$ROOT_PART")
        kernel_cmdline="rd.luks.uuid=${crypt_uuid} root=${MAPPED_ROOT} rootflags=subvol=@ rw"
    else
        root_uuid=$(blkid -s UUID -o value "$MAPPED_ROOT")
        kernel_cmdline="root=UUID=${root_uuid} rootflags=subvol=@ rw"
    fi
    [[ $ROOT_FS == ext4 ]] && kernel_cmdline=${kernel_cmdline//rootflags=subvol=@ /}

    local kver
    kver=$(chroot_run "ls /boot | grep -m1 '^vmlinuz-'" | sed 's/vmlinuz-//')

    mkdir -p /mnt/gentoo/boot/efi/loader/entries
    cat > /mnt/gentoo/boot/efi/loader/loader.conf <<EOF
default gentoo.conf
timeout 3
console-mode max
editor no
EOF

    cat > "/mnt/gentoo/boot/efi/loader/entries/gentoo.conf" <<EOF
title   Gentoo Linux
linux   /vmlinuz-${kver}
initrd  /initramfs-${kver}.img
options ${kernel_cmdline}
EOF
}

################################################################################
# 7. cleanup
################################################################################

finish() {
    log "Unmounting..."
    umount -R /mnt/gentoo || warn "Some mounts may still be busy; reboot should still be fine."
    [[ $USE_ENCRYPTION == yes ]] && cryptsetup close gentoo_root 2>/dev/null || true
    log "Done. Review /mnt/gentoo before rebooting if you want to double check anything."
    log "Reboot into your new system with: reboot"
}

################################################################################
# main
################################################################################

main() {
    require_root
    require_uefi
    confirm_wipe

    do_partition
    setup_encryption
    setup_filesystems
    fetch_stage3
    prepare_chroot
    configure_base_system
    finish
}

main "$@"
