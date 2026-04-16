# Minimal Ubuntu Embedded System Builder

This repository contains the scripts and configuration to build a minimal, custom Ubuntu Server image for ARM64-based embedded devices (e.g., Raspberry Pi 4).

The entire system is built using `debootstrap` to assemble pre-compiled Ubuntu packages. This approach is significantly faster and more space-efficient than full source-based systems like Yocto, making it ideal for rapid prototyping and development on machines with limited disk space.


## Project Philosophy

-   **Reproducible:** The build process is fully scripted to ensure anyone can create an identical image.
-   **Minimal:** Starts with `minbase` to ensure no unnecessary packages are included.
-   **Understandable:** The entire workflow is contained in a single, heavily commented script.
-   **Self-Contained:** This `README.md` serves as the primary documentation, including all necessary code.

## Project File Structure

This is the recommended structure for the project. The build script will create the `output/` and temporary directories as needed.

```
.
├── build-image.sh      # The main, all-in-one build script.
├── configs/              # (Optional) Place custom config files here.
│   └── sshd_config     # Example: A hardened SSH config.
├── .gitignore            # Specifies files to be ignored by Git.
└── README.md             # This documentation file.
```

## Prerequisites

This build process must be run on a Debian-based host system (e.g., Ubuntu 20.04+).

Install the required tools before starting:
```bash
sudo apt update
sudo apt install -y debootstrap qemu-user-static binfmt-support
```

## The Build Script (`build-image.sh`)

Create a file named `build-image.sh` and paste the entire contents of the code block below into it. This script automates every step of the process.

```bash
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

    # Partition the image file
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

```

## How to Build the Image

1.  **Save the Script:** Create a file named `build-image.sh` and paste the code from the block above into it.

2.  **Make the Script Executable:**
    ```bash
    chmod +x build-image.sh
    ```

3.  **Run the Build Script:**
    This script handles everything. It must be run with `sudo` because it performs system-level operations like creating device nodes and mounting filesystems.

    ```bash
    sudo ./build-image.sh
    ```
    The script will pause and ask you to enter and confirm a password for the `root` user.

4.  **Find the Final Image:**
    Upon successful completion, the final compressed image will be located at:
    `output/ubuntu-custom.img.gz`

## Flashing the Image

You can write the generated `.img.gz` file to an SD card using a tool like Raspberry Pi Imager or Balena Etcher. They can handle compressed images directly.

Alternatively, use the command-line `dd` utility.

**WARNING:** Using `dd` is powerful but dangerous. Ensure you have the correct device name for your SD card (e.g., `/dev/sdb`). Using the wrong device name **WILL DESTROY DATA** on that disk.

1.  **Find your SD card device:**
    ```bash
    lsblk
    ```
2.  **Flash the image (example for `/dev/sdX`):**
    ```bash
    # Decompress and flash in one command
    gzip -dc output/ubuntu-custom.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
    ```

## Next Steps: Making the Image Bootable

The generated image contains a complete root filesystem but **lacks a kernel and bootloader**. These components are specific to the target hardware.

To make this image bootable on a **Raspberry Pi**, for example, you would need to:

1.  Mount the first partition (the FAT32 one) of the `.img` file.
2.  Download the official Raspberry Pi firmware/bootloader files (`start*.elf`, `fixup*.dat`).
3.  Download a compatible ARM64 kernel (`kernel8.img`) and Device Tree Blobs (`*.dtb`).
4.  Copy all these files onto the mounted boot partition.
5.  Create a `cmdline.txt` file to tell the kernel where to find the root filesystem (e.g., `root=/dev/mmcblk0p2`).

This process is left as a hardware-specific step.

## `.gitignore`

To keep the repository clean, create a `.gitignore` file with the following content. This prevents build artifacts from being committed.

```
# Build artifacts and generated files
output/
*.img
*.gz
*.iso

# Temporary mount points
boot/
root/

# System and editor files
.DS_Store
*.swp
*.swo

# Local secrets (if you ever use them)
.env
```
