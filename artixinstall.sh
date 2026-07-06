#!/bin/bash
# Interactive Artix Linux (dinit) Install Script
# Features: Auto-Partitioning, Swap, Interactive Config, Auto Wi-Fi

set -e

# ==============================================================================
# 0. INTERACTIVE USER CONFIGURATION
# ==============================================================================
echo "====================================================================="
echo " Artix Linux Installer "
echo " Provide the required information to begin."
echo "====================================================================="

read -p "Target Disk (e.g., /dev/sda, /dev/nvme0n1): " DISK
read -p "Hostname (e.g., nuclearcore): " HOSTNAME
read -p "Username: " USERNAME
read -s -p "User & Root Password: " PASSWORD
echo "" # Prints a newline after the hidden password input
read -p "Timezone (e.g., Europe/Brussels): " TIMEZONE
read -p "Keyboard Map (e.g., fr-latin1, us): " KEYMAP

echo ""
read -p "Wi-Fi SSID (Leave blank if using wired Ethernet): " WIFI_SSID
if [ -n "$WIFI_SSID" ]; then
    read -s -p "Wi-Fi Password: " WIFI_PASSWORD
    echo ""
fi

# ==============================================================================
# FAILSAFE & AUTO-DETECT PARTITIONS
# ==============================================================================
if [ -z "$DISK" ]; then
    echo "ERROR: Disk selection cannot be empty! Exiting..."
    exit 1
fi

# Dynamically set partition names based on drive type (NVMe/eMMC vs SATA)
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    EFI_PART="${DISK}p1"
    SWAP_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"
else
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
fi

echo ""
echo "WARNING: This will DESTROY ALL DATA on $DISK."
echo "It will automatically create new efi, swap, and root partitions."
echo "Press Ctrl+C if you want to abort, you have 10 seconds..."
sleep 10

# ==============================================================================
# 1. PARTITIONING & FORMATTING
# ==============================================================================
echo "[1/6] Updating system clock..."
ntpd -q -g

echo "[2/6] Wiping drive and creating new partition table on $DISK..."
# Wipe any existing filesystem signatures to prevent conflicts
wipefs -a "$DISK"

# Create a new GPT partition table
parted -s "$DISK" mklabel gpt

# 1. EFI Partition (512MB)
parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on

# 2. Swap Partition (4GB)
parted -s "$DISK" mkpart primary linux-swap 513MiB 4609MiB

# 3. Root Partition (Rest of the drive)
parted -s "$DISK" mkpart primary ext4 4609MiB 100%

# Tell the kernel to reload the new partition table
partprobe "$DISK"
sleep 3

echo "[3/6] Formatting and mounting new partitions..."
mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
mkfs.ext4 -F "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
swapon "$SWAP_PART"

# ==============================================================================
# 2. BASE SYSTEM INSTALLATION
# ==============================================================================
echo "[4/6] Bootstrapping Artix base and dinit ecosystem..."
basestrap /mnt base base-devel linux linux-firmware \
    dinit elogind-dinit networkmanager networkmanager-dinit wpa_supplicant \
    grub efibootmgr nano vim git parted

echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab

# ==============================================================================
# 3. CHROOT CONFIGURATION
# ==============================================================================
echo "[5/6] Entering chroot to configure the system..."

artix-chroot /mnt /bin/bash <<EOF
set -e

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

# Automatic Wi-Fi Profile (Only if SSID was provided)
if [ -n "$WIFI_SSID" ]; then
    mkdir -p /etc/NetworkManager/system-connections/
    cat <<WIFI_PROFILE > /etc/NetworkManager/system-connections/"$WIFI_SSID".nmconnection
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
    chmod 600 /etc/NetworkManager/system-connections/"$WIFI_SSID".nmconnection
fi

# Initramfs
mkinitcpio -P

# Bootloader (GRUB)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Passwords and Users
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable NetworkManager in dinit
ln -sf /etc/dinit.d/NetworkManager /etc/dinit.d/boot.d/

EOF

# ==============================================================================
# 4. WRAP UP
# ==============================================================================
echo "[6/6] Unmounting and cleaning up..."
swapoff "$SWAP_PART"
umount -R /mnt

echo "✅ Fully automated Artix installation complete!"
echo "Type 'reboot', log in as '$USERNAME', and your network will be ready."
