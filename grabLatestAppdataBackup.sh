#!/bin/bash
echo ""
echo "Clearing out /mnt/user/backups/appdata_latest/"
rm /mnt/user/backups/appdata_latest/* -rf

echo ""
echo "Grabbing latest appdata backup for Duplicacy"

cd /mnt/user/backups/appdata

ls -t | head -n1 > /mnt/user/backups/appdata_latest/latest.txt

echo ""
echo Copying: "$(< /mnt/user/backups/appdata_latest/latest.txt)"

cp -r "$(< /mnt/user/backups/appdata_latest/latest.txt)" /mnt/user/backups/appdata_latest

cp /mnt/user/backups/appdata_latest/latest.txt /mnt/remote/EDGENAS_unraid_backups
rm /mnt/user/backups/appdata_latest/latest.txt

echo ""
echo "Done"
