#!/bin/bash

#
# UNRAID Remote Backup v2.0
# By: Edge
#
# Updated: February 13, 2024
# Notes:   Updated to work with Unraid 6.12.x (new appdata backup plugin)
#
###################################################################################
#
# Path and file settings -- change accordingly!
#
# Path where the script logs will be stored
log_file="/mnt/disks/ssd/unraid_backups/remoteBackupv2.log"
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
# DEPRECATED: Source location of your UNRAID LIBVIRT image file
libvirt_file="/mnt/user/system/libvirt"
#
# Location of your UNRAID APPDATA CABackups
appdata_backup_path="/mnt/user/backups/"
#
# Boolean for zip error
error_zip=false
#
# Boolean remote copy error
error_copy=false
#
#
# Note: This script does not backup APPDATA from source.  
#       It grabs the lastest backup from the "appdata backup" plugin.
#       This script assumes "appdata backup" plugin has successfully completed.
#       This script must run after "appdata backup" plugin is done. 
#
###################################################################################

# Redirect stdout and stderr to tee, appending to the log file.
exec > >(tee -a "$log_file") 2>&1

echo ""
echo "[*] UNRAID Remote Backup v2.0"
echo "[*] Backup USB, LIBVIRT, VM and APPDATA to remote server"
echo ""
echo "Backup Path     : $backup_path"
echo "Backup File     : $backup_file"
echo "Remote Path     : $remote_path"
echo "LIBVIRT File    : $libvirt_file"
echo "APPDATA Path    : $appdata_backup_path"
echo ""

# Capture start time
start_time=$(date)
echo "Start time      : $start_time"

# Log start to UNRAID notifications
/usr/local/emhttp/webGui/scripts/notify -i normal -e "UNRAID Remote Backup" -s "USB, LIBVIRT, VM and APPDATA Remote backup started" -d "Remote backup started $start_time"

# Determine latest backup in the "appdata backup" plugin directory
latest_backup=$(ls -t $appdata_backup_path | head -n1)
echo "Latest Appdata Backup : $latest_backup"
echo ""

# Zip the LIBVIRT image and APPDATA folder (which contains the USB and VM metadata). If error, then exit.
echo "Zipping the latest USB/LIBVIRT/VM/APPDATA backup..."
if zip -rq $backup_file $libvirt_file $appdata_backup_path/$latest_backup; then
    echo "Zip successful..."
else
    echo "ERROR: Zip failed."
    echo "UNRAID Remote Backup terminated."
        /usr/local/emhttp/webGui/scripts/notify -i warning -s "Remote Backup Failed" -d "Zip of USB, LIBVIRT, VM and APPDATA failed"
    exit 1
fi

echo "Copying today's backup to the remote backup server..."
if cp $backup_file $remote_path; then
        echo "Remote backup successful..."
else
    echo "ERROR: Remote copy failed."
    echo "UNRAID Remote Backup terminated."
        /usr/local/emhttp/webGui/scripts/notify -i warning -s "Remote Backup Failed" -d "Remote copy failed"
    exit 1
fi

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

# Log successful completion to UNRAID notifications
/usr/local/emhttp/webGui/scripts/notify -i normal -e "UNRAID Remote Backup" -s "USB, LIBVIRT, VM and APPDATA remote backup completed" -d "Successful backup to $remote_path"

echo ""
echo "[*] UNRAID Remote Backup COMPLETE"
echo ""
exit 0
