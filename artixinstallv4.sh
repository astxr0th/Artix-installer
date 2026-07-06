#!/bin/bash
# Interactive Artix Linux Advanced Install Script
# Features: Failsafes, HW Optimization, Init Choice, FS Choice, Auto-Wi-Fi, Paru, Ly (Dynamic Init), Wayland Compositors, Doas

set -e

trap 'echo "ERROR: Installation failed! Cleaning up..."; umount -R /mnt 2>/dev/null; swapoff -a 2>/dev/null; exit 1' ERR

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
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

echo "Select Wayland Compositor(s) (installed via Paru):"
echo "1) mangowm-git"
echo "2) halley-full"
echo "3) river"
echo "4) All three (mangowm-git, halley-full, river)"
echo "5) None"
read -p "Choice [5]: " COMP_CHOICE
case "$COMP_CHOICE" in
    1) COMPOSITOR="mangowm-git" ;;
    2) COMPOSITOR="halley-full" ;;
    3) COMPOSITOR="river" ;;
    4) COMPOSITOR="mangowm-git halley-full river" ;;
    *) COMPOSITOR="" ;;
esac

read -p "Hostname: " HOSTNAME
read -p "Username: " USERNAME
read -s -p "Root / User Password: " PASSWORD
echo ""

read -p "Wi-Fi SSID (leave blank to skip): " WIFI_SSID
if [ -n "$WIFI_SSID" ]; then
    read -s -p "Wi-Fi Password: " WIFI_PASS
    echo ""
fi

# 2. PARTITIONING & FORMATTING
echo "[1/6] Partitioning and formatting disk $DISK..."
umount -R /mnt 2>/dev/null || true
sgdisk -Z "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
sgdisk -n 2:0:+4G -t 2:8200 -c 2:"Linux swap" "$DISK"
sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux root filesystem" "$DISK"

if [[ "$DISK" == *nvme* ]] || [[ "$DISK" == *mmcblk* ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

mkfs.fat -F32 "${PART_PREFIX}1"
mkswap "${PART_PREFIX}2"
swapon "${PART_PREFIX}2"

if [ "$FS_CHOICE" == "btrfs" ]; then
    mkfs.btrfs -f "${PART_PREFIX}3"
    mount "${PART_PREFIX}3" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@pkg
    umount /mnt
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "${PART_PREFIX}3" /mnt
    mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg}
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "${PART_PREFIX}3" /mnt/home
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@log "${PART_PREFIX}3" /mnt/var/log
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@pkg "${PART_PREFIX}3" /mnt/var/cache/pacman/pkg
elif [ "$FS_CHOICE" == "xfs" ]; then
    mkfs.xfs -f "${PART_PREFIX}3"
    mount "${PART_PREFIX}3" /mnt
else
    mkfs.ext4 -F "${PART_PREFIX}3"
    mount "${PART_PREFIX}3" /mnt
fi

mkdir -p /mnt/boot/efi
mount "${PART_PREFIX}1" /mnt/boot/efi

# 3. BASE INSTALLATION
echo "[2/6] Installing Base System..."
basestrap /mnt base base-devel linux linux-firmware artix-keyring "$INIT_SYS" "elogind-$INIT_SYS" nano networkmanager "networkmanager-$INIT_SYS" grub efibootmgr git rust zig pam xcb-util libxcb opendoas mesa polkit foot
fstabgen -U /mnt >> /mnt/etc/fstab

# 4. CHROOT CONFIGURATION
echo "[4/6] Configuring system inside chroot..."
cat <<'EOF' > /mnt/setup_chroot.sh
#!/bin/bash
set -e
HOSTNAME="$1"; USERNAME="$2"; PASSWORD="$3"; INIT_SYS="$4"; COMPOSITOR="$5"; WIFI_SSID="$6"; WIFI_PASS="$7"
WIFI_PASS="${WIFI_PASS//\"/\\\"}"

# Locale & Timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Users
chpasswd <<< "root:$PASSWORD"
useradd -m -G wheel -s /bin/bash "$USERNAME"
chpasswd <<< "$USERNAME:$PASSWORD"

# Doas setup
echo "permit nopass :wheel" > /etc/doas.conf
chown root:root /etc/doas.conf
chmod 0400 /etc/doas.conf
echo "PACMAN_AUTH=(doas)" >> /etc/makepkg.conf

# Paru & Compositors
su - "$USERNAME" -c "git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin && cd /tmp/paru-bin && makepkg -si --noconfirm"
sed -i 's/^#Sudo = sudo/Sudo = doas/' /etc/paru.conf 2>/dev/null || echo -e "[bin]\nSudo = doas" >> /etc/paru.conf

# Ly
git clone https://codeberg.org/fairyglade/ly.git /tmp/ly
cd /tmp/ly && zig build install --prefix /usr -Dinit_system="$INIT_SYS"
case "$INIT_SYS" in
    dinit) cp res/*dinit* /etc/dinit.d/ly 2>/dev/null || true; ln -sf /etc/dinit.d/ly /etc/dinit.d/boot.d/ ;;
    openrc) cp res/*openrc* /etc/init.d/ly 2>/dev/null || true; chmod +x /etc/init.d/ly; rc-update add ly default ;;
    runit) mkdir -p /etc/runit/sv/ly; cp res/*runit* /etc/runit/sv/ly/run 2>/dev/null || true; ln -sf /etc/runit/sv/ly /etc/runit/runsvdir/default/ ;;
esac

# Cleanup & Finalize
[ -n "$WIFI_SSID" ] && { echo -e "[wifi]\nssid=$WIFI_SSID\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=$WIFI_PASS" > /etc/NetworkManager/system-connections/"$WIFI_SSID.nmconnection"; chmod 600 /etc/NetworkManager/system-connections/"$WIFI_SSID.nmconnection"; }
[ -n "$COMPOSITOR" ] && su - "$USERNAME" -c "paru -Sy --noconfirm $COMPOSITOR"
mkinitcpio -P && grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB && grub-mkconfig -o /boot/grub/grub.cfg
pacman -Scc --noconfirm
echo "permit persist :wheel" > /etc/doas.conf
chown root:root /etc/doas.conf && chmod 0400 /etc/doas.conf
EOF

chmod +x /mnt/setup_chroot.sh
artix-chroot /mnt /setup_chroot.sh "$HOSTNAME" "$USERNAME" "$PASSWORD" "$INIT_SYS" "$COMPOSITOR" "$WIFI_SSID" "$WIFI_PASS"
rm /mnt/setup_chroot.sh

# 6. WRAP UP
trap - ERR
umount -R /mnt 2>/dev/null
swapoff -a 2>/dev/null
echo "Installation Complete!"
