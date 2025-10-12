#!/bin/bash
#
# UNRAID Remote Backup v2.3 (testable)
# By: Edge
#
# Updated: Oct 13, 2025
# Notes:
# - Keep LAST N backups (count-based) for USB and Appdata on SSD and NAS
# - Mount checks for SSD and NAS with Unraid notify if not mounted
# - Prune USB SOURCE to last N (plugin doesn’t auto-prune USB)
# - Appdata source remains plugin-managed (already prunes to ~7 folders)
# - --test / -t: soft dry run (no file changes), still logs & sends notifications
#
###################################################################################
# Tunables
RETAIN_COUNT=7

appdata_src="/mnt/user/backups/appdata"
usb_src="/mnt/user/backups/usb"

ssd_root="/mnt/disks/ssd"
ssd_appdata="${ssd_root}/appdata_backups"
ssd_usb="${ssd_root}/usb_backups"

nas_root="/mnt/remotes/EDGENAS_unraid_backups"
nas_appdata="${nas_root}/appdata_backups"
nas_usb="${nas_root}/usb_backups"

libvirt_file="/mnt/user/system/libvirt"

log_dir="${ssd_root}/unraid_backups"
log_file="${log_dir}/remoteBackup.log"

backup_date="$(date +%d-%b-%Y)"
appdata_zip="${ssd_appdata}/appdata_backup-${backup_date}.zip"

###################################################################################
# Flags
TEST_MODE=false
[[ "${1-}" == "--test" || "${1-}" == "-t" ]] && TEST_MODE=true

notify_prefix=""
$TEST_MODE && notify_prefix="[TEST MODE] "

###################################################################################
# Mount checks BEFORE doing anything
require_mount () {
  local path="$1" label="$2"
  if ! mountpoint -q -- "$path"; then
    echo "ERROR: $label not mounted: $path"
    /usr/local/emhttp/webGui/scripts/notify \
      -i warning -e "UNRAID Remote Backup" \
      -s "${notify_prefix}${label} not mounted" \
      -d "$path is not mounted. Aborting backup."
    exit 1
  fi
}
require_mount "$ssd_root" "SSD"
require_mount "$nas_root" "Remote NAS"

###################################################################################
# Setup logging
mkdir -p "$log_dir" "$ssd_appdata" "$ssd_usb" "$nas_appdata" "$nas_usb"
exec > >(tee -a "$log_file") 2>&1

echo ""
echo "[*] UNRAID Remote Backup v2.3"
echo "[*] Mirrors Appdata/USB to SSD & NAS, keeps last ${RETAIN_COUNT}"
if $TEST_MODE; then
  echo "=============================================="
  echo "[TEST MODE ENABLED] No files will be changed."
  echo "=============================================="
fi
echo ""
echo "-----------------------------------------"
echo "SOUCE - UNRAID:"
echo "  Appdata   : $appdata_src"
echo "  USB       : $usb_src"
echo "  LIBVIRT   : $libvirt_file"
echo "-----------------------------------------"
echo "TARGET - SSD:"
echo "  Appdata   : $ssd_appdata"
echo "  USB       : $ssd_usb"
echo "-----------------------------------------"
echo "TARGET - REMOTE NAS:"
echo "  Appdata   : $nas_appdata"
echo "  USB       : $nas_usb"
echo "-----------------------------------------"
echo ""

start_time="$(date)"
echo "Start time      : $start_time"

/usr/local/emhttp/webGui/scripts/notify \
  -i normal -e "UNRAID Remote Backup" \
  -s "${notify_prefix}Appdata & USB mirror started" \
  -d "Mirroring to SSD & NAS started at $start_time"

###################################################################################
# Helpers
keep_last_n_files () {
  local dir="$1" glob="$2" count="$3"
  [[ -d "$dir" ]] || { echo "WARN: $dir missing; nothing to prune."; return 0; }
  mapfile -t files < <(ls -1t ${dir}/${glob} 2>/dev/null || true)
  local total="${#files[@]}"
  if (( total > count )); then
    echo "Pruning in $dir (pattern: $glob): keep $count of $total, deleting $((total-count)) older..."
    for ((i=count; i<total; i++)); do
      $TEST_MODE && echo "  [TEST] Would delete ${files[$i]}" || { echo "  - deleting ${files[$i]}"; rm -f -- "${files[$i]}"; }
    done
  else
    echo "No prune needed in $dir (pattern: $glob): total $total <= keep $count"
  fi
}

copy_last_n_files () {
  local src="$1" dst="$2" glob="$3" count="$4"
  [[ -d "$src" ]] || { echo "WARN: source $src missing; skipping copy."; return 0; }
  mkdir -p "$dst"
  mapfile -t files < <(ls -1t ${src}/${glob} 2>/dev/null | head -n "$count" || true)
  (( ${#files[@]} == 0 )) && { echo "WARN: no files matching ${glob} in $src to copy."; return 0; }
  echo "Copying up to last $count from $src to $dst ..."
  for f in "${files[@]}"; do
    $TEST_MODE && echo "  [TEST] Would copy $(basename "$f") -> $dst/" || { echo "  - $(basename "$f")"; cp -u -- "$f" "$dst/"; }
  done
}

latest_appdata_folder () { ls -1dt "${appdata_src}"/ab_* 2>/dev/null | head -n1; }

zip_appdata_with_libvirt () {
  local ab_folder="$1" zip_path="$2"
  $TEST_MODE && { echo "[TEST] Would zip $libvirt_file and $ab_folder into $zip_path"; return 0; }
  zip -rq "$zip_path" "$libvirt_file" "$ab_folder"
}

cp_one () {
  local src="$1" dst="$2"
  $TEST_MODE && { echo "[TEST] Would copy $src -> $dst/"; return 0; }
  cp -u -- "$src" "$dst/"
}

###################################################################################
# 1) USB SOURCE prune
echo ""
echo "[USB] Pruning USB source to last $RETAIN_COUNT files..."
keep_last_n_files "$usb_src" "*.zip" "$RETAIN_COUNT"

###################################################################################
# 2) USB MIRROR
echo ""
echo "[USB] Mirroring last $RETAIN_COUNT zips to SSD..."
copy_last_n_files "$usb_src" "$ssd_usb" "*.zip" "$RETAIN_COUNT"
echo "[USB] Pruning SSD usb_backups to last $RETAIN_COUNT..."
keep_last_n_files "$ssd_usb" "*.zip" "$RETAIN_COUNT"

echo ""
echo "[USB] Mirroring last $RETAIN_COUNT zips to NAS..."
copy_last_n_files "$usb_src" "$nas_usb" "*.zip" "$RETAIN_COUNT"
echo "[USB] Pruning NAS usb_backups to last $RETAIN_COUNT..."
keep_last_n_files "$nas_usb" "*.zip" "$RETAIN_COUNT"

###################################################################################
# 3) APPDATA PACKAGE
echo ""
echo "[APPDATA] Locating latest appdata backup folder..."
latest_ab="$(latest_appdata_folder)"
if [[ -z "$latest_ab" ]]; then
  echo "ERROR: No appdata backup folders found in $appdata_src"
  /usr/local/emhttp/webGui/scripts/notify -i warning \
    -s "${notify_prefix}Remote Backup Failed" \
    -d "No appdata backup folders found in $appdata_src"
  exit 1
fi
echo "Latest Appdata Backup : $(basename "$latest_ab")"

echo "[APPDATA] Creating daily zip on SSD: $appdata_zip"
if zip_appdata_with_libvirt "$latest_ab" "$appdata_zip"; then
  $TEST_MODE && echo "Zip simulated OK." || echo "Zip successful."
else
  echo "ERROR: Zip failed. Terminating."
  /usr/local/emhttp/webGui/scripts/notify -i warning \
    -s "${notify_prefix}Remote Backup Failed" \
    -d "Zip of LIBVIRT + latest Appdata failed"
  exit 1
fi

echo "[APPDATA] Pruning SSD appdata_backups to last $RETAIN_COUNT zips..."
keep_last_n_files "$ssd_appdata" "*.zip" "$RETAIN_COUNT"

###################################################################################
# 4) APPDATA → NAS
echo ""
echo "[APPDATA] Copying today's appdata zip to NAS..."
if cp_one "$appdata_zip" "$nas_appdata"; then
  $TEST_MODE && echo "NAS copy simulated OK." || echo "NAS copy successful."
else
  echo "ERROR: NAS copy failed."
  /usr/local/emhttp/webGui/scripts/notify -i warning \
    -s "${notify_prefix}Remote Backup Failed" \
    -d "Copy of Appdata zip to NAS failed"
  exit 1
fi

echo "[APPDATA] Pruning NAS appdata_backups to last $RETAIN_COUNT zips..."
keep_last_n_files "$nas_appdata" "*.zip" "$RETAIN_COUNT"

###################################################################################
# Done
echo ""
end_time="$(date)"
echo "End time        : $end_time"
echo -n "Elapsed time    : "
date -u -d @$(($(date -d "$end_time" '+%s') - $(date -d "$start_time" '+%s'))) '+%T'

/usr/local/emhttp/webGui/scripts/notify \
  -i normal -e "UNRAID Remote Backup" \
  -s "${notify_prefix}Appdata & USB mirror completed" \
  -d "SSD & NAS mirrors updated. Kept last ${RETAIN_COUNT}."

echo ""
echo "[*] UNRAID Remote Backup COMPLETE"
echo ""
exit 0
