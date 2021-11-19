#!/bin/bash

# Exit if the user did not specify the desktop
[[ -n "$1" ]] || { echo "No desktop specified"; exit; }
[[ -n "$2" ]] || { echo "No distro specified, using Ubuntu"; set -- $1 "ubuntu"; }

# Sync Progress Function
function syncStorage {

  echo "Writing storage, may take more than 5 minutes."
  echo "Although it seems slow, consider this process like flashing an ISO to a USB Drive."
  echo "Below is an innacurate indicator of mB left to write. It may decrease hundreds of megabytes in seconds."

  # shellcheck disable=SC2016
  sync & {
    # If the unsynced data (in kB) is greater than 50MB, then show the sync progress
    while [[ $(grep -e Dirty: /proc/meminfo | grep --color=never -o '[0-9]\+') -gt 5000 ]]; do
      SYNC_MB=$(grep -e Dirty: /proc/meminfo | grep --color=never -o '[0-9]\+' | awk '{$1/=1024;printf "%.2fMB\n",$1}')
      echo -en "\r${SYNC_MB}"
      sleep 1
    done
  }

  echo

  #watch -n 1 'grep -e Dirty: /proc/meminfo | grep --color=never -o '\''[0-9]\+'\'' | awk '\''{$1/=1024;printf "%.2fMB\n",$1}'\'''
  #grep -e Dirty: /proc/meminfo | grep --color=never -o '[0-9]\+' | awk '{$1/=1024;printf "%.2fMB\n",$1}'
}

# Distro and desktop variables
DESKTOP=$1
DISTRO=$2
ORIGINAL_DIR=$(pwd)

# Exit on errors
set -e

# Many much importance
which toilet > /dev/null || sudo apt-get install -qq -y toilet

# Show title message - I told you it was important
toilet -f mono12 "Breath"    -F gay

# Ask for username
echo "What would you like your username to be?"
read -r BREATH_USER

# Make a directory and CD into it
mkdir -p ~/linux-build
cd ~/linux-build

# If the ChromeOS firmware utility doesn't exist, install it and other packages
echo "Installing Dependencies"
which futility > /dev/null || sudo apt install -y vboot-kernel-utils arch-install-scripts git wget linux-firmware

# Download the kernel bzImage and the kernel modules (wget)
wget https://github.com/MilkyDeveloper/cb-linux/releases/latest/download/bzImage -O bzImage -q --show-progress
wget https://github.com/MilkyDeveloper/cb-linux/releases/latest/download/modules.tar.xz -O modules.tar.xz -q --show-progress

# Download the rootfs based on the distribution
case $DISTRO in

  ubuntu)
    # Download the Ubuntu rootfs if it doesn't exist
    DISTRO_ROOTFS="ubuntu-rootfs.tar.xz"
    [[ ! -f $DISTRO_ROOTFS ]] && {
      wget http://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64-root.tar.xz -O ubuntu-rootfs.tar.xz -q --show-progress
    }
    ;;

  arch)
    # Download the Arch Bootstrap rootfs if it doesn't exist
    DISTRO_ROOTFS="arch-rootfs.tar.gz"
    [[ ! -f $DISTRO_ROOTFS ]] && {
      wget https://mirror.rackspace.com/archlinux/iso/2021.10.01/archlinux-bootstrap-2021.10.01-x86_64.tar.gz -O arch-rootfs.tar.gz -q --show-progress
    }
    ;;

  *)
    echo "Unknown Distribution supplied, only arch and ubuntu (case-sensitive) are valid distros"
    exit
    ;;
esac

# Only do the below if the second stage has not been completed (format/write rootfs to USB)
# For debugging purposes
if [[ $STAGE != 2 ]]; then

# Write kernel parameters
wget https://raw.githubusercontent.com/MilkyDeveloper/cb-linux/main/kernel/kernel.flags -O kernel.flags

# Sign the kernel
# After this, the kernel can no longer be booted on non-depthcharge devices
futility vbutil_kernel \
	 --arch x86_64 --version 1 \
	 --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
	 --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
	 --bootloader kernel.flags \
	 --config kernel.flags \
	 --vmlinuz bzImage \
	 --pack bzImage.signed

# Check if a USB Drive is plugged in
USBCOUNTER=1
while true; do
	if ! lsblk -o name,model,tran | grep -q "usb"; then
		echo -en "\rPlease plug in a USB Drive (Try ${USBCOUNTER}, trying every 5 seconds)"
		sleep 5
    (( USBCOUNTER++ ))
else
		break
	fi
done
echo

# Ask user which USB Device they would like to use
echo "Which USB Drive would you like to use (e.g. /dev/sda)? All data on the drive will be wiped!"
lsblk -o name,model,tran | grep --color=never "usb"
read USB
echo "Ok, using $USB to install Linux"

# Unmount all partitions on the USB and /mnt
# This command will fail, so use set +e
set +e; sudo umount ${USB}*; sudo umount /mnt; set -e

# Format the USB with GPT
# READ: https://wiki.gentoo.org/wiki/Creating_bootable_media_for_depthcharge_based_devices
sudo parted $USB mklabel gpt
syncStorage

# Create a 65 Mb kernel partition
# Our kernels are only ~10 Mb though
sudo parted -a optimal $USB unit mib mkpart Kernel 1 65

# Add a root partition
sudo parted -a optimal $USB unit mib mkpart Root 65 100%

# Make depthcharge know that this is a real kernel partition
sudo cgpt add -i 1 -t kernel -S 1 -T 5 -P 15 $USB

# Flash the kernel partition
sudo dd if=bzImage.signed of=${USB}1

# Format the root partition as ext4 and mount it to /mnt
sudo mkfs.ext4 ${USB}2
syncStorage
set +e; sudo umount /mnt; set -e
sudo rm -rf /mnt/*
sudo mount ${USB}2 /mnt

# Extract the rootfs
case $DISTRO in

  arch)
    # Extract the Arch Bootstrap rootfs to /tmp/arch
    # We need an absolute path (/home/user/thing) instead
    # of a relative path (cd ~; thing) since we won't be in
    # ~/linux-build anymore.
    DISTRO_ROOTFS_ABSOLUTE=$(readlink -f $DISTRO_ROOTFS)
    sudo rm -rf /tmp/arch || true
    sudo mkdir /tmp/arch
    cd /tmp/arch # The -c option doesn't work when using the command below
    sudo tar xvpfz $DISTRO_ROOTFS_ABSOLUTE root.x86_64/ --strip-components=1
    cd ~/linux-build
    ;;

  *)
    # Assume any other distro has all the root files in the root of the archive
    # Extract the Ubuntu rootfs to the USB Drive
    sudo tar xvpf $DISTRO_ROOTFS -C /mnt
    ;;
    
esac
syncStorage

fi

# Post-install steps
case $DISTRO in

  ubuntu)

    # Setup internet
    sudo cp --remove-destination /etc/resolv.conf /mnt/etc/resolv.conf

    # Add universe to /etc/apt/sources.list so we can install normal packages
    cat > sources.list << EOF
    deb http://us.archive.ubuntu.com/ubuntu  focal          main universe multiverse 
    deb http://us.archive.ubuntu.com/ubuntu  focal-security main universe multiverse 
    deb http://us.archive.ubuntu.com/ubuntu  focal-updates  main universe multiverse
EOF

    sudo cp sources.list /mnt/etc/apt/

    case $DESKTOP in
      cli)
        BASECMD="apt install -y network-manager tasksel software-properties-common"
        ;;

      *)
        BASECMD="apt install -y network-manager lightdm lightdm-gtk-greeter fonts-roboto yaru-theme-icon materia-gtk-theme budgie-wallpapers-focal tasksel software-properties-common; fc-cache"
        ;;
    esac

    # Chroot into the rootfs to install some packages
    sudo mount --bind /dev /mnt/dev
    sudo chroot /mnt /bin/bash -c "apt update; $BASECMD"
    sudo umount /mnt/dev || sudo umount -lf /mnt/dev
    syncStorage

    if [ $DESKTOP != "cli" ]; then
      # Rice LightDM
      # Use the Materia GTK theme, Yaru Icon theme, and Budgie Wallpapers
      sudo tee -a /mnt/etc/lightdm/lightdm-gtk-greeter.conf > /dev/null <<EOT
      theme-name=Materia
      icon-theme-name=Yaru
      font-name=Roboto
      xft-dpi=120
      background=/usr/share/backgrounds/budgie/blue-surface_by_gurjus_bhasin.jpg
EOT
    fi

    # We need to load the iwlmvm module at startup for WiFi
    sudo sh -c 'echo '\''iwlmvm'\'' >> /mnt/etc/modules'

    # Desktop installation fails without this
    sudo chroot /mnt /bin/sh -c "apt update -y"

    # Download the desktop that the user has selected
    case $DESKTOP in

      minimal)
        export DESKTOP_PACKAGE="apt install -y xfce4 xfce4-terminal --no-install-recommends"
        ;;

      gnome)
        export DESKTOP_PACKAGE="apt install -y ubuntu-desktop"
        ;;

      budgie)
        export DESKTOP_PACKAGE="apt install -y ubuntu-budgie-desktop"
        ;;
      
      deepin)
        export DESKTOP_PACKAGE="add-apt-repository ppa:ubuntudde-dev/stable; apt update; apt install -y ubuntudde-dde"
        ;;

      mate)
        export DESKTOP_PACKAGE="apt install -y ubuntu-mate-desktop"
        ;;

      xfce)
        export DESKTOP_PACKAGE="apt install -y xubuntu-desktop"
        ;;

      lxqt)
        export DESKTOP_PACKAGE="apt install -y lubuntu-desktop"
        ;;

      openbox)
        # For debugging purposes
        export DESKTOP_PACKAGE="apt install -y openbox xfce4-terminal"
        ;;

      cli)
        export DESKTOP_PACKAGE="echo 'Using CLI, no need to install any desktop packages.'"
        ;;

    esac

    set +e
    sudo chroot /mnt /bin/sh -c "$DESKTOP_PACKAGE"
    echo "Ignore libfprint-2-2 fprintd libpam-fprintd errors"

    # GDM3 installs minimal GNOME
    # This makes the default session in LightDM GNOME,
    # instead of whatever the user chose.
    # We can fix this by removing the GNOME session and deleting the shell.
    if [[ $DESKTOP != "gnome" ]]; then
      sudo rm /mnt/usr/share/xsessions/ubuntu.desktop || true
      sudo chroot /mnt /bin/sh -c "apt remove gnome-shell -y; apt autoremove -y" || true
    fi

    sudo chroot /mnt /bin/sh -c "apt remove gdm3 pulseaudio"
    echo "Ignore libfprint-2-2 fprintd libpam-fprintd errors"
    syncStorage
    set -e

    # Only create a new user and add it to the sudo group if the user doesn't already exist
    if sudo chroot /mnt /bin/bash -c "id $BREATH_USER &>/dev/null"; then
      true
    else
      sudo chroot /mnt /bin/sh -c "adduser $BREATH_USER && usermod -aG sudo $BREATH_USER"
    fi

    # At the moment, suspending to ram (mem) doesn't work,
    # depthcharge says "Secure NVRAM (TPM) initialization error"
    # Instead, we can use freeze which doesn't have great power savings,
    # but for the user it functions the same.
    # This is a stopgap solution. Suspend to RAM is the best when working.
    # READ: https://www.kernel.org/doc/html/v4.18/admin-guide/pm/sleep-states.html
    # READ: https://www.freedesktop.org/software/systemd/man/systemd-sleep.conf.html
    # TODO: Find text modification command instead of redirecting echo
    sudo chroot /mnt /bin/sh -c "echo 'SuspendState=freeze' >> /etc/systemd/sleep.conf"
    # Hibernating shouldn't work, but fake it anyways
    sudo chroot /mnt /bin/sh -c "echo 'HibernateState=freeze' >> /etc/systemd/sleep.conf"

  ;;

  arch)

    # Setup internet
    sudo cp --remove-destination /etc/resolv.conf /tmp/arch/etc/resolv.conf

    # Fixes pacman
    sudo mount --bind /tmp/arch /tmp/arch

    # We don't need nmtui since Arch has wifi-menu
    # TODO: Add desktop functionality

    # Change the Arch Mirror
    sudo tee -a /tmp/arch/etc/pacman.d/mirrorlist > /dev/null <<EOT
    Server = http://mirror.rackspace.com/archlinux/\$repo/os/\$arch
EOT

    # Generate the Pacman Keys
    sudo arch-chroot /tmp/arch bash -c "pacman-key --init; pacman-key --populate archlinux"

    # Pacstrap /mnt
    sudo mount --bind /mnt /tmp/arch/mnt
    sudo arch-chroot /tmp/arch bash -c "pacstrap /mnt base base-devel nano" # Vim is bad
    sudo umount -f /tmp/arch/mnt || true

    # We're done with our bootstrap arch install in /tmp/arch!
    # NOTE: Use arch-chroot when installed packages, otherwise 

    # Clean up the mess made in /tmp (if possible)
    sudo umount -f /tmp/arch || true
    sudo rm -rf /tmp/arch || true
    
    # Create a new user that isn't root
    if sudo chroot /mnt /bin/bash -c "id $BREATH_USER &>/dev/null"; then
      true
    else
      sudo chroot /mnt /bin/bash -c "useradd -m -G wheel -s /bin/bash $BREATH_USER"
    fi

    # Add the user to the sudoers group
    sudo tee -a /mnt/etc/sudoers > /dev/null <<EOT
    %wheel ALL=(ALL) ALL
EOT

    # Install nmcli for wifi
    sudo arch-chroot /mnt bash -c "pacman -S networkmanager"

  ;;
    
esac

# The heredoc (<<EOT) method of running commands in a chroot isn't interactive,
# but luckily passwd has an option to chroot
echo "What would you like the root user's password to be?"
until sudo chroot /mnt bash -c "passwd root"; do echo "Retrying Password"; sleep 1; done

# Copy (hopefully up-to-date) firmware from the host to the USB
sudo mkdir -p /mnt/lib/firmware
sudo cp -Rv /lib/firmware/* /mnt/lib/firmware
syncStorage

# Extract the modules to /mnt
sudo mkdir -p /mnt/lib/modules
mkdir -p modules || sudo rm -rf modules; sudo mkdir -p modules
sudo tar xvpf modules.tar.xz -C modules
sudo cp -rv modules/lib/modules/* /mnt/lib/modules
syncStorage

# Install all utility files in the bin directory
cd $ORIGINAL_DIR
sudo chmod +x bin/*
sudo cp bin/* /mnt/usr/local/bin
syncStorage

sudo umount /mnt
echo "Done!"

# Getting sound working:
# 
# setup-audio
