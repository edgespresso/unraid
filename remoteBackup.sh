#!/bin/bash

echo ""
echo "[*] UNRAID Remote Backup v1.0"
echo "[*] Backup USB, LIBVIRT and APPDATA to remote server"
echo ""

start_time=$(date)
echo "Start time   : $start_time"

# Move to the UNRAID backup directory on the mounted SSD
backup_path="/mnt/disks/ssd/unraid_backups"
echo "Backup Path  : $backup_path"

backup_file="$backup_path/unraid_backup-$(date +%d-%b-%Y).zip"
echo "Backup File  : $backup_file"

usb_path="/boot"
echo "USB Path     : $usb_path"

libvirt_file="/mnt/user/system/libvirt"
echo "LIBVIRT File : $libvirt_file"

appdata_path="/mnt/user/appdata"
echo "APPDATA Path : $appdata_path"

remote_path="/mnt/remotes/EDGENAS_unraid_backups"
echo "Remote Path  : $remote_path"

# Change to the new directory and start zipping
cd $backup_path

echo ""
# Zip the USB files, LIBVIRT image and APPDATA folder
echo "Zipping UNRAID USB files, LIBVIRT image and APPDATA folder..."
zip -rq $backup_path/unraid_backup-$(date +%d-%b-%Y).zip $usb_path $libvirt_file $appdata_path

echo "Copying today's backup to the remote backup server..."
cp $backup_file $remote_path

echo "Removing backup files that are over 7 days old... "
find $backup_path -type f -name "*.zip" -mtime +7 -delete

echo""
end_time=$(date)
echo "End time     : $end_time"

# Calculate elapsed time
echo -n "Elapsed time : "
date -u -d @$(($(date -d "$end_time" '+%s') - $(date -d "$start_time" '+%s'))) '+%T'

echo ""
echo "[*] UNRAID Remote Backup COMPLETE"
echo ""
