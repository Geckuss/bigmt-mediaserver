#!/usr/bin/env bash
# dock-hdd.sh - helpers for mounting/unmounting/powering-off any drive in the USB dock.
#
# The dock exposes a fixed USB serial for the whole disk (the bridge's serial),
# so /dev/sdX and /dev/disk/by-id/usb-* are ambiguous when drives are swapped.
# These functions locate the docked drive live by USB transport and mount it to a
# fixed mountpoint (/mnt/backup), regardless of which drive is in the dock.
#
# Usage - source once (e.g. from ~/.bashrc):
#   source scripts/dock-hdd.sh
#   mountdock      mount whatever drive is in the dock to /mnt/backup
#   unmountdock    unmount /mnt/backup
#   pwoffdock      power off the docked drive (udisksctl, hdparm -Y fallback)
#
# If an NTFS volume was left unclean by Windows, mountdock offers to run ntfsfix
# and remount. All prompts are interactive; non-interactive runs skip the cleanup.

mountdock() {
    local mp=/mnt/backup
    local d part fs opts ans
    d=$(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1; exit}')
    if [[ -z "$d" ]]; then
        echo "mountdock: no USB drive in dock" >&2
        return 1
    fi
    part=$(lsblk -nro PATH,FSTYPE "/dev/$d" | awk 'NR>1 && $2{print $1; exit}')
    if [[ -z "$part" ]]; then
        echo "mountdock: no filesystem partition on /dev/$d" >&2
        return 1
    fi
    fs=$(lsblk -nro FSTYPE "$part")
    if mountpoint -q "$mp"; then
        echo "mountdock: $mp already mounted" >&2
        return 0
    fi
    sudo mkdir -p "$mp"
    if ! sudo mount "$part" "$mp" 2>/tmp/mountdock.err; then
        if grep -Eqi "unclean file system|unsafe state|read-only" /tmp/mountdock.err; then
            echo "mountdock: filesystem on $part is unclean" >&2
            read -r -p "Run ntfsfix to clean it and remount? [y/N] " ans
            if [[ "${ans,,}" == "y" ]]; then
                sudo ntfsfix "$part" && sudo mount "$part" "$mp" && echo "mounted $part -> $mp"
                return $?
            fi
        fi
        cat /tmp/mountdock.err >&2
        return 1
    fi
    echo "mounted $part -> $mp"
    opts=$(findmnt -n -r -o OPTIONS "$mp")
    if [[ "$fs" == ntfs* || "$fs" == fuseblk ]] && [[ "$opts" == ro* ]]; then
        echo "mountdock: WARNING: $mp mounted read-only (unclean filesystem)" >&2
        read -r -p "Run ntfsfix and remount read-write? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            sudo umount "$mp" && sudo ntfsfix "$part" && sudo mount "$part" "$mp" && echo "mounted $part -> $mp (rw)"
        fi
    fi
}

unmountdock() {
    if ! mountpoint -q /mnt/backup; then
        echo "unmountdock: nothing mounted at /mnt/backup" >&2
        return 1
    fi
    if sudo umount /mnt/backup; then
        echo "unmounted /mnt/backup"
    else
        echo "unmountdock: busy - something is using /mnt/backup" >&2
        return 1
    fi
}

pwoffdock() {
    local d
    d=$(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1; exit}')
    if [[ -z "$d" ]]; then
        echo "pwoffdock: no USB drive in dock" >&2
        return 1
    fi
    if mountpoint -q /mnt/backup; then
        sudo umount /mnt/backup || { echo "pwoffdock: busy - unmount /mnt/backup first" >&2; return 1; }
    fi
    if udisksctl power-off -b "/dev/$d"; then
        echo "pwoffdock: /dev/$d powered off"
    else
        echo "pwoffdock: udisksctl failed, spinning down via hdparm" >&2
        sudo hdparm -Y "/dev/$d"
    fi
}
