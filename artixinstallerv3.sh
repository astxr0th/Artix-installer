#!/bin/bash
# Interactive Artix Linux Advanced Install Script
# Features: Failsafes, HW Optimization, Init Choice, FS Choice, Auto-Wi-Fi

set -e

# Error handling: automatically unmount partitions if a command fails
trap 'echo "ERROR: Installation failed! Cleaning up..."; umount -R /mnt 2>/dev/null; swapoff -a 2>/dev/null; exit 1' ERR


# 0. PRE-INSTALL CHECKS

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root. (e.g., sudo ./installerv2.sh)"
    exit 1
fi

echo "====================================================================="
echo " Artix Linux Advanced Installer "
echo "====================================================================="


# 1. USER CONFIGURATION

read -p "Target Disk (e.g., /dev/sda, /dev/nvme0n1): " DISK
if [ ! -b "$DISK" ]; then
    echo "ERROR: Disk $DISK does not exist!"
    exit 1
fi

read -p "Filesystem for root (ext4, xfs, btrfs) [ext4]: " FS_CHOICE
FS_CHOICE=${FS_CHOICE:-ext4}
case "$FS_CHOICE" in
    ext4|xfs|btrfs) ;;
    *) echo "ERROR: Invalid filesystem choice."; exit 1 ;;
esac

read -p "Init System (dinit, openrc, runit, s6) [dinit]: " INIT_SYS
INIT_SYS=${INIT_SYS:-dinit}
case "$INIT_SYS" in
    dinit|openrc|runit|s6) ;;
    *) echo "ERROR: Invalid init system choice."; exit 1 ;;
esac

echo ""
echo "Select GPU Driver:"
echo "1) AMD (Open Source)"
echo "2) Intel (Open Source)"
echo "3) NVIDIA (Proprietary)"
echo "4) None / Virtual Machine"
read -p "Choice [1-4]: " GPU_CHOICE

echo ""
read -p "Hostname (e.g., myartix): " HOSTNAME
read -p "Username: " USERNAME
read -rs -p "User & Root Password: " PASSWORD
echo ""

read -p "Timezone (e.g., Europe/Brussels): " TIMEZONE
if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    echo "ERROR: Timezone /usr/share/zoneinfo/$TIMEZONE does not exist!"
    exit 1
fi

read -p "Keyboard Map (e.g., fr-latin1, us): " KEYMAP

echo ""
read -p "Wi-Fi SSID (Leave blank if using wired Ethernet): " WIFI_SSID
if [ -n "$WIFI_SSID" ]; then
    read -rs -p "Wi-Fi Password: " WIFI_PASSWORD
    echo ""
fi


# 2. AUTO-DETECT PARTITIONS & HARDWARE

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    EFI_PART="${DISK}p1"
    SWAP_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"
else
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
fi

EXTRA_PKGS="base base-devel linux linux-firmware $INIT_SYS elogind-$INIT_SYS networkmanager networkmanager-$INIT_SYS wpa_supplicant grub efibootmgr nano vim git parted"

if [ "$FS_CHOICE" == "btrfs" ]; then EXTRA_PKGS+=" btrfs-progs"; fi
if [ "$FS_CHOICE" == "xfs" ]; then EXTRA_PKGS+=" xfsprogs"; fi

if grep -q "AuthenticAMD" /proc/cpuinfo; then EXTRA_PKGS+=" amd-ucode"; fi
if grep -q "GenuineIntel" /proc/cpuinfo; then EXTRA_PKGS+=" intel-ucode"; fi

case "$GPU_CHOICE" in
    1) EXTRA_PKGS+=" mesa xf86-video-amdgpu" ;;
    2) EXTRA_PKGS+=" mesa xf86-video-intel" ;;
    3) EXTRA_PKGS+=" nvidia-dkms dkms libva-nvidia-driver nvidia-utils linux-headers" ;;
    *) echo "No specific GPU drivers selected. Using kernel defaults." ;;
esac

echo ""
echo "WARNING: This will DESTROY ALL DATA on $DISK."
echo "It will automatically create new efi, swap, and root ($FS_CHOICE) partitions."
echo "Press Ctrl+C to abort. You have 10 seconds..."
sleep 10

# Start Logging
echo "Starting automated installation... (Logging to /var/log/artix-install.log)"
exec > >(tee -a /var/log/artix-install.log) 2>&1


# 3. PARTITIONING & FORMATTING

echo "[1/6] Updating system clock..."
ntpd -q -g

echo "[2/6] Wiping drive and creating new partition table on $DISK..."
# Disable swap just in case the live ISO auto-mounted it, which blocks wipefs
swapoff -a || true
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary linux-swap 513MiB 4609MiB
parted -s "$DISK" mkpart primary "$FS_CHOICE" 4609MiB 100%
partprobe "$DISK"
sleep 3

echo "[3/6] Formatting and mounting new partitions..."
mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

if [ "$FS_CHOICE" == "btrfs" ]; then
    mkfs.btrfs -f "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@pkg
    umount /mnt
    
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "$ROOT_PART" /mnt
    mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,boot/efi}
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "$ROOT_PART" /mnt/home
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@log "$ROOT_PART" /mnt/var/log
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg
elif [ "$FS_CHOICE" == "xfs" ]; then
    mkfs.xfs -f "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
else
    mkfs.ext4 -F "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
fi

mount "$EFI_PART" /mnt/boot/efi


# 4. BASE SYSTEM INSTALLATION

echo "[4/6] Bootstrapping Artix base, kernel, and extra packages..."
basestrap /mnt $EXTRA_PKGS

echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab


# 5. CHROOT CONFIGURATION

echo "[5/6] Entering chroot to configure the system..."

# Ensure optional variables are at least defined as empty strings so declare -p doesn't fail
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

# Safely serialize variables to prevent script injection/corruption via special characters
declare -p HOSTNAME USERNAME PASSWORD TIMEZONE KEYMAP WIFI_SSID WIFI_PASSWORD INIT_SYS > /mnt/root/install_vars.sh

# Quoted 'EOF' ensures variables are evaluated SAFELY by the chroot, not the parent shell
artix-chroot /mnt /bin/bash <<'EOF'
set -e

# Load the safely serialized variables and clean up
source /root/install_vars.sh
rm /root/install_vars.sh

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Network configuration
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Automatic Wi-Fi Profile
if [ -n "$WIFI_SSID" ]; then
    mkdir -p /etc/NetworkManager/system-connections/
    cat <<WIFI_PROFILE > /etc/NetworkManager/system-connections/"${WIFI_SSID}.nmconnection"
[connection]
id=$WIFI_SSID
type=wifi
[wifi]
mode=infrastructure
ssid=$WIFI_SSID
[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASSWORD
[ipv4]
method=auto
[ipv6]
addr-gen-mode=stable-privacy
method=auto
WIFI_PROFILE
    chmod 600 /etc/NetworkManager/system-connections/"${WIFI_SSID}.nmconnection"
fi

# Initramfs
mkinitcpio -P

# Bootloader (GRUB)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Passwords and Users (Using here-strings to safely pipe passwords with special characters)
chpasswd <<< "root:$PASSWORD"
useradd -m -G wheel -s /bin/bash "$USERNAME"
chpasswd <<< "$USERNAME:$PASSWORD"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable NetworkManager dynamically based on Init System choice
if [ "$INIT_SYS" == "dinit" ]; then
    ln -sf /etc/dinit.d/NetworkManager /etc/dinit.d/boot.d/
elif [ "$INIT_SYS" == "openrc" ]; then
    rc-update add NetworkManager default
elif [ "$INIT_SYS" == "runit" ]; then
    ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/
elif [ "$INIT_SYS" == "s6" ]; then
    touch /etc/s6/adminsv/default/contents.d/NetworkManager
fi
EOF


# 6. WRAP UP

echo "[6/6] Unmounting and cleaning up..."

# Disable the error trap so a busy unmount doesn't falsely flag an installation failure
trap - ERR 

# Save the install log to the newly installed root filesystem
cp /var/log/artix-install.log /mnt/var/log/artix-install.log || true

# Turn off swap and unmount partitions securely
swapoff "$SWAP_PART" || true
umount -R /mnt || true

echo "Artix installation complete!"
echo "A log of this installation has been saved to /var/log/artix-install.log on your new system."
echo "Type 'reboot', log in as '$USERNAME'."