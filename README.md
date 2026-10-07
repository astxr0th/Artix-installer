# Artix-installer

An interactive script that installs [Artix Linux](https://artixlinux.org) from the live ISO. It asks
a few questions, wipes the disk you pick, and gives you a bootable system with a user, networking,
a display manager and an AUR helper already set up.

> [!WARNING]
> This erases the whole target disk. It asks you to type `YES` before it touches anything, but
> double-check the disk name with `lsblk` first.

## What you get

- **Init system:** dinit (default), openrc, runit or s6
- **Root filesystem:** ext4 (default), xfs, or btrfs with `@`, `@home`, `@log` and `@pkg` subvolumes
  (zstd compression)
- **Boot:** GRUB on UEFI
- **Login:** [ly](https://codeberg.org/fairyglade/ly), built from source for your init system
- **Privileges:** `doas` instead of sudo, with `persist` for the wheel group
- **AUR:** `paru`, configured to use doas
- **Compositor (optional):** mangowm, halley, river, or all three
- **Wi-Fi (optional):** saves a NetworkManager profile so you're online right after the first boot

## Disk layout

| partition | size | type |
|---|---|---|
| 1 | 512 MiB | EFI, FAT32, mounted at `/boot/efi` |
| 2 | 4 GiB | swap |
| 3 | rest of the disk | root (ext4 / xfs / btrfs) |

## Usage

Boot the Artix live ISO, get online (ethernet, or `connmanctl`/`iwctl` for Wi-Fi), log in as root, then:

```sh
curl -O https://raw.githubusercontent.com/astxr0th/Artix-installer/main/install.sh
chmod +x install.sh
./install.sh
```

When it finishes, reboot and remove the install media.

## Things to know

- The timezone is set to UTC and the locale to `en_US.UTF-8`. Change them after install, or edit the
  chroot section of the script.
- Root and your user get the same password.
- UEFI only. Legacy BIOS isn't supported.
- With s6, ly is installed but not enabled as a service; you'll have to enable it yourself.
- If something fails, the script unmounts `/mnt` and turns off swap so you can run it again.
