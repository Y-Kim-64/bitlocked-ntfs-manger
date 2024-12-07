#!/bin/bash
# set -x # for logging

BITLOCKER_MOUNT="/mnt/bitlocker"
NTFS_MOUNT="/mnt/ntfs"
MEMORY_FILE="$HOME/.pssd_memory"
ENCRYPTED_MEMORY_FILE="$HOME/.pssd_memory.gpg"

if ! command -v gpg &>/dev/null; then
  echo -e "\e[31mError: gpg is not installed. Please install it and try again.\e[0m"
  exit 1
fi

cleanup() {
  if [ -f "$MEMORY_FILE" ]; then
    echo -e "\n\e[33mEncrypting memory file before exit...\e[0m"
    gpg --quiet --batch --yes --symmetric --cipher-algo AES256 --passphrase "$MEMORY_PASSWORD" --output "$ENCRYPTED_MEMORY_FILE" "$MEMORY_FILE"
    rm -f "$MEMORY_FILE"
    echo -e "\e[32mMemory file encrypted. Goodbye!\e[0m"
  fi
  exit
}

trap cleanup SIGINT SIGTERM

secure_read_password() {
  echo -e "\e[36mEnter password for PSSD memory\e[0m"
  read -sp $'\e[33mMemory Password: \e[0m' MEMORY_PASSWORD
  echo
}

set_new_password() {
  echo -e "\e[36mSet a new password for PSSD memory\e[0m"
  read -sp $'\e[33mNew Memory Password: \e[0m' MEMORY_PASSWORD
  echo
}

decrypt_memory() {
  if [ -f "$ENCRYPTED_MEMORY_FILE" ]; then
    secure_read_password
    gpg --quiet --batch --yes --decrypt --passphrase "$MEMORY_PASSWORD" --output "$MEMORY_FILE" "$ENCRYPTED_MEMORY_FILE" 2>/dev/null
    if [ $? -ne 0 ]; then
      echo -e "\e[31mError: Failed to decrypt the memory file. Exiting.\e[0m"
      exit 1
    fi
  else
    set_new_password
    touch "$MEMORY_FILE"
  fi
}

encrypt_memory() {
  if [ -f "$MEMORY_FILE" ]; then
    if [ -z "$MEMORY_PASSWORD" ]; then
      echo -e "\e[31mError: MEMORY_PASSWORD is empty. The memory file will be deleted immediately.\e[0m"
      rm -f "$MEMORY_FILE"
      exit 1
    fi
    gpg --quiet --batch --yes --symmetric --cipher-algo AES256 --passphrase "$MEMORY_PASSWORD" --output "$ENCRYPTED_MEMORY_FILE" "$MEMORY_FILE"
    rm -f "$MEMORY_FILE"
  fi
}

add_pssd_info() {
  echo -e "\e[36mEnter USB ID (format: 0000:0000):\e[0m"
  read USB_ID
  if grep -q "$USB_ID" "$MEMORY_FILE"; then
    echo -e "\e[33mUSB ID $USB_ID already exists in memory.\e[0m"
    return
  fi
  echo -e "\e[36mEnter nickname for this PSSD:\e[0m"
  read NICKNAME
  echo -e "\e[36mEnter BitLocker password for this PSSD:\e[0m"
  read -sp $'\e[33mPSSD BitLocker Password: \e[0m' PASSWORD
  echo
  if [ -z "$PASSWORD" ]; then
    echo -e "\e[31mError: Password cannot be empty. Aborting.\e[0m"
    return
  fi
  echo "$USB_ID|$NICKNAME|$PASSWORD" >> "$MEMORY_FILE"
  echo -e "\e[32mPSSD information saved successfully.\e[0m"
}

unlock_and_mount_pssd() {
  echo -e "\e[36mAvailable PSSDs:\e[0m"
  awk -F'|' '{print NR ") " $2 " (" $1 ")"}' "$MEMORY_FILE"
  echo -e "\e[36mEnter the number corresponding to the PSSD you want to mount:\e[0m"
  read CHOICE
  PSSD_INFO=$(sed -n "${CHOICE}p" "$MEMORY_FILE")
  if [ -z "$PSSD_INFO" ]; then
    echo -e "\e[31mInvalid choice. Please try again.\e[0m"
    return
  fi
  USB_ID=$(echo "$PSSD_INFO" | awk -F'|' '{print $1}')
  NICKNAME=$(echo "$PSSD_INFO" | awk -F'|' '{print $2}')
  PASSWORD=$(echo "$PSSD_INFO" | awk -F'|' '{print $3}')
  if [ -z "$PASSWORD" ]; then
    echo -e "\e[31mError: Password is empty. Cannot proceed.\e[0m"
    return
  fi
  echo -e "\e[33mAttempting to unlock and mount PSSD: $NICKNAME (USB ID: $USB_ID)\e[0m"

  sudo mkdir -p $BITLOCKER_MOUNT
  sudo mkdir -p $NTFS_MOUNT

  USB_DEVICE=$(lsusb | grep "$USB_ID" | awk '{print $2":"$4}' | sed 's/://g' | head -n 1)
  if [ -z "$USB_DEVICE" ]; then
    echo -e "\e[31mError: PSSD with USB ID $USB_ID not found. Please connect the device and try again.\e[0m"
    return
  fi

  DEVICE_PATH=$(lsblk -lnpo NAME,TRAN | grep usb | awk '{print $1}' | head -n 1)
  if [ -z "$DEVICE_PATH" ]; then
    echo -e "\e[31mError: Could not determine the correct block device. Please ensure the PSSD is connected.\e[0m"
    return
  fi

  PARTITION_PATH="${DEVICE_PATH}1"
  sudo umount $NTFS_MOUNT 2>/dev/null || echo -e "\e[33mNTFS already unmounted.\e[0m"
  sudo umount $BITLOCKER_MOUNT 2>/dev/null || echo -e "\e[33mBitLocker already unmounted.\e[0m"
  sudo rm -rf $BITLOCKER_MOUNT/dislocker-file

  sudo dislocker -V $PARTITION_PATH --user-password="$PASSWORD" --force -- $BITLOCKER_MOUNT &> /tmp/dislocker.log
  if [ $? -ne 0 ]; then
    echo -e "\e[31mError: Failed to unlock the BitLocker-encrypted PSSD. Check /tmp/dislocker.log for details.\e[0m"
    return
  fi

  sudo mount -o loop,rw $BITLOCKER_MOUNT/dislocker-file $NTFS_MOUNT
  if [ $? -eq 0 ]; then
    echo -e "\e[32mPSSD successfully mounted at $NTFS_MOUNT.\e[0m"
    ls $NTFS_MOUNT
  else
    echo -e "\e[31mError: Failed to mount the NTFS file system.\e[0m"
    sudo umount $BITLOCKER_MOUNT
  fi
}

unmount_pssd() {
  sudo umount $NTFS_MOUNT
  if [ $? -eq 0 ]; then
    echo -e "\e[32mNTFS file system unmounted successfully.\e[0m"
  else
    echo -e "\e[31mError: Failed to unmount NTFS file system or it was not mounted.\e[0m"
  fi

  sudo umount $BITLOCKER_MOUNT
  if [ $? -eq 0 ]; then
    echo -e "\e[32mBitLocker mount point unmounted successfully.\e[0m"
  else
    echo -e "\e[31mError: Failed to unmount BitLocker mount point or it was not mounted.\e[0m"
  fi

  sudo rmdir $NTFS_MOUNT $BITLOCKER_MOUNT 2>/dev/null || echo -e "\e[32mCleanup complete.\e[0m"
}

decrypt_memory
while true; do
  echo -e "\e[36m<Choose an option>\e[0m"
  echo -e "\e[36m1) Add PSSD information\e[0m"
  echo -e "\e[36m2) Unlock and mount a PSSD\e[0m"
  echo -e "\e[36m3) Unmount PSSD\e[0m"
  echo -e "\e[36m4) Exit\e[0m"
  read -p $'\e[33mEnter your choice: \e[0m' OPTION
  case $OPTION in
    1) add_pssd_info ;;
    2) unlock_and_mount_pssd ;;
    3) unmount_pssd ;;
    4) encrypt_memory; echo -e "\e[32mGoodbye!\e[0m"; exit ;;
    *) echo -e "\e[31mInvalid option. Please try again.\e[0m" ;;
  esac
done