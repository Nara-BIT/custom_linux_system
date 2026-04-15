#!/bin/bash

# =============================================================================
#
#  Minimal Ubuntu Embedded System Builder
#
#  This script automates the creation of a custom, minimal Ubuntu image
#  for ARM64 devices using debootstrap.
#
# =============================================================================

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
readonly RELEASE="jammy"        # Ubuntu 22.04 LTS
readonly ARCH="arm64"
readonly VARIANT="minbase"
readonly IMAGE_SIZE="4G"
readonly IMAGE_NAME="ubuntu-custom.img"
readonly WORK_DIR=$(pwd)
readonly OUTPUT_DIR="${WORK_DIR}/output"
readonly ROOTFS_DIR="${OUTPUT_DIR}/rootfs"
readonly BOOT_PART_SIZE="+256M"

# --- Main Build Function ---
main() {
    echo "=== Starting Embedded Ubuntu Build ==="

    cleanup
    create_base_rootfs
    customize_rootfs
    create_disk_image
    compress_image

    echo "=== Build Complete! ==="
    echo "Final image available at: ${OUTPUT_DIR}/${IMAGE_NAME}.gz"
}

# --- Helper Functions ---

# Clean up previous build artifacts
cleanup() {
    echo "--- Cleaning up previous build artifacts... ---"
    # Unmount any lingering mounts, ignoring errors if they don't exist
    sudo umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true

    # Clean up loop devices
    sudo losetup -D

    # Remove the output directory
    sudo rm -rf "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    echo "Cleanup complete."
}

# Create the base root filesystem using debootstrap
create_base_rootfs() {
    echo "--- Creating base rootfs with debootstrap... ---"
    sudo debootstrap \
        --arch="${ARCH}" \
        --variant="${VARIANT}" \
        "${RELEASE}" \
        "${ROOTFS_DIR}" \
        http://ports.ubuntu.com/ubuntu-ports
    echo "Base rootfs created at ${ROOTFS_DIR}"
}

# Chroot into the rootfs to install packages and perform customizations
customize_rootfs() {
    echo "--- Customizing rootfs via chroot... ---"
    sudo cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"

    # Mount necessary filesystems for chroot
    sudo mount -t proc /proc "${ROOTFS_DIR}/proc"
    sudo mount -t sysfs /sys "${ROOTFS_DIR}/sys"
    sudo mount -o bind /dev "${ROOTFS_DIR}/dev"
    sudo mount -o bind /dev/pts "${ROOTFS_DIR}/dev/pts"

    # Chroot and execute customization commands
    sudo chroot "${ROOTFS_DIR}" /bin/bash << "CHROOT_EOF"
        set -e
        
        echo "Inside chroot..."

        # Set a default hostname
        echo "embedded-ubuntu" > /etc/hostname

        # Set a root password
        echo "Setting root password. Please enter a new password:"
        passwd root

        # Update package lists
        apt-get update

        # Install essential software
        apt-get install -y --no-install-recommends \
            nano \
            iputils-ping \
            openssh-server \
            net-tools \
            systemd-sysv

        # Clean up apt cache to save space
        apt-get clean
        rm -rf /var/lib/apt/lists/*

        echo "Chroot customization complete."
CHROOT_EOF

    # Unmount all the things
    echo "--- Unmounting chroot filesystems... ---"
    sudo umount -l "${ROOTFS_DIR}/dev/pts"
    sudo umount -l "${ROOTFS_DIR}/dev"
    sudo umount -l "${ROOTFS_DIR}/proc"
    sudo umount -l "${ROOTFS_DIR}/sys"
}

# Create a bootable disk image from the rootfs
create_disk_image() {
    echo "--- Creating final disk image... ---"
    local image_path="${OUTPUT_DIR}/${IMAGE_NAME}"
    local boot_mount="${OUTPUT_DIR}/mnt_boot"
    local root_mount="${OUTPUT_DIR}/mnt_root"

    # Create an empty image file
    dd if=/dev/zero of="${image_path}" bs=1M count=0 seek=4096 # 4G

    # Partition the image file using fdisk
    (
        echo g # Create a new empty GPT partition table
        echo n # Add a new partition (boot)
        echo   # Partition number 1
        echo   # First sector
        echo ${BOOT_PART_SIZE} # Last sector
        echo t # Change partition type
        echo 1 # Partition number 1
        echo 11 # Type: Microsoft basic data (FAT32)
        echo n # Add a new partition (root)
        echo   # Partition number 2
        echo   # First sector
        echo   # Last sector (use remaining space)
        echo w # Write table to disk and exit
    ) | sudo fdisk "${image_path}"

    # Set up loop device
    local loop_device=$(sudo losetup --find --show -P "${image_path}")
    echo "Image mounted to loop device: ${loop_device}"

    # Format partitions
    sudo mkfs.vfat -F 32 "${loop_device}p1"
    sudo mkfs.ext4 "${loop_device}p2"

    # Mount partitions
    mkdir -p "${boot_mount}" "${root_mount}"
    sudo mount "${loop_device}p2" "${root_mount}"
    sudo mount "${loop_device}p1" "${boot_mount}"

    # Copy rootfs contents
    echo "Copying rootfs to image..."
    sudo cp -a "${ROOTFS_DIR}/." "${root_mount}/"

    # IMPORTANT: The /boot directory on the root partition should be an
    # empty mount point. We also don't have a kernel yet, so we ensure
    # the boot partition is clean.
    # The user will need to add kernel/bootloader files here manually.
    sudo rm -rf "${root_mount}/boot"/*
    echo "Note: The boot partition is empty. A device-specific kernel and bootloader must be added manually."
    
    # Unmount and detach
    sudo umount "${boot_mount}" "${root_mount}"
    sudo losetup -d "${loop_device}"
    rmdir "${boot_mount}" "${root_mount}"
}

# Compress the final image
compress_image() {
    echo "--- Compressing final image... ---"
    gzip -f "${OUTPUT_DIR}/${IMAGE_NAME}"
}

# --- Script Entry Point ---
main
