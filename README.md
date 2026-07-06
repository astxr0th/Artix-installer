
# Artix Linux Interactive Installer (Dinit)

Interactive bash script for quickly installing **Artix Linux** with the **dinit** init system. It automates partitioning, formatting, bootstrapping the base system, and configuring network settings (including wifi) directly from the command line.

## Features

* **Auto-Partitioning:** Automatically wipes the selected disk and creates a standard UEFI/GPT layout.
* **Wi-Fi Setup:** Automatically generates a NetworkManager profile during installation so your wifi is connected and ready immediately after the first reboot.
* **Essential Packages:** Bootstraps the base system along with `linux`, `networkmanager`, `grub`, `nano`, `vim`, and `git`.
* **Sudo User Creation:** Automatically creates a standard user in the `wheel` group and sets a unified password for both the user and root, and configures `sudo` privileges.

## Partition Scheme

The script automatically formats the selected disk using the following layout:
1. **EFI Partition:** 512 MiB (`fat32`) mounted at `/boot/efi`
2. **Swap Partition:** 4 GiB (`linux-swap`)
3. **Root Partition:** Remaining disk space (`ext4`) mounted at `/`

## Prerequisites

1. Boot into the official **Artix Linux Live ISO**.
2. Ensure you have an active internet connection on the live environment (via Ethernet or `iwctl` for Wi-Fi).
3. Identify the target disk you want to install Artix on using the `lsblk` command.

## Usage

1. **Download the script:**
   ```bash
   curl -O [https://raw.githubusercontent.com/astxr0th/Artix-install/main/installerv2.sh](https://raw.githubusercontent.com/astxr0th/Artix-install/main/installerv2.sh)
