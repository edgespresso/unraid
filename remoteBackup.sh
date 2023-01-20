!/bin/bash

#
# UNRAID Remote Backup v1.1
# By: Edge
#
###################################################################################
#
# Path and file settings -- change accordingly!
#
# Where to temporarily store the new backup on your unassigned device (ie, ssd)
backup_path="/mnt/disks/ssd/unraid_backups"
#
# Name of the new backup file
backup_file="$backup_path/unraid_backup-$(date +%d-%b-%Y).zip"
#
# Path on the remote QNAP server to store the new backup
remote_path="/mnt/remotes/EDGENAS_unraid_backups"
#
# Source location of your UNRAID USB drive
usb_path="/boot"
#
# Source location of your UNRAID LIBVIRT image file
libvirt_file="/mnt/user/system/libvirt"
#
# Location of your UNRAID APPDATA CABackups
appdata_backup_path="/mnt/user/backups/appdata"
#
# Note: This script does not backup APPDATA from source.  
#       It grabs the last CABackup.
#       This script assumes CABackup has successfully completed backup of the appdata folder.
#       This script must run after CABackup is done. 
#
###################################################################################

echo ""
echo "[*] UNRAID Remote Backup v1.1"
echo "[*] Backup USB, LIBVIRT and APPDATA to remote server"
echo ""
echo "Backup Path     : $backup_path"
echo "Backup File     : $backup_file"
echo "Remote Path     : $remote_path"
echo "USB Path        : $usb_path"
echo "LIBVIRT File    : $libvirt_file"
echo "APPDATA Path    : $appdata_backup_path"
echo ""

# Capture start time
start_time=$(date)
echo "Start time      : $start_time"

# Determine latest backup from the CABackup APPDATA folder
latest_backup=$(ls -t $appdata_backup_path | head -n1)
echo "Latest CABackup : $latest_backup"
echo ""

# Zip the USB files, LIBVIRT image and APPDATA folder
echo "Zipping UNRAID USB files, LIBVIRT image and the latest APPDATA backup..."
zip -rq $backup_file $usb_path $libvirt_file $appdata_backup_path/$latest_backup/CA_backup.tar

echo "Copying today's backup to the remote backup server..."
cp $backup_file $remote_path

echo "Purging SSD backup files that are over 7 days old... "
find $backup_path -type f -name "*.zip" -mmin +$((60*24*7)) -delete

echo "Purging REMOTE backup files that are over 7 days old... "
find $remote_path -type f -name "*.zip" -mmin +$((60*24*7)) -delete

echo ""
end_time=$(date)
echo "End time        : $end_time"

# Calculate elapsed time
echo -n "Elapsed time    : "
date -u -d @$(($(date -d "$end_time" '+%s') - $(date -d "$start_time" '+%s'))) '+%T'

echo ""
echo "[*] UNRAID Remote Backup COMPLETE"
echo ""
