#!/bin/bash
#
# UNRAID Remote Backup v2.2 (testable)
# By: Edge
#
# Updated: Oct 12, 2025
# Notes:
# - Keep LAST N backups (count-based) for USB and Appdata on SSD and NAS
# - Prune USB SOURCE to last N (plugin doesn’t auto-prune USB)
# - Appdata source remains plugin-managed (already prunes to ~7 folders)
# - --test / -t: soft dry run (no file changes), still logs & sends notifications
#
###################################################################################
# Tunables

# How many most-recent backups to keep everywhere (count-based)
RETAIN_COUNT=7

# Sources (managed by Unraid backup plugin)
appdata_src="/mnt/user/backups/appdata"    # folders like ab_YYYYMMDD_HHMMSS
usb_src="/mnt/user/backups/usb"            # zip files (plugin output)

# Off-array SSD targets
ssd_root="/mnt/disks/ssd"
ssd_appdata="${ssd_root}/appdata_backups"
ssd_usb="${ssd_root}/usb_backups"
# reserved: ssd_vm="${ssd_root}/vm_backups"

# NAS (mounted) targets
nas_root="/mnt/remotes/EDGENAS_unraid_backups"
nas_appdata="${nas_root}/appdata_backups"
nas_usb="${nas_root}/usb_backups"

# LIBVIRT folder to include in the Appdata package
libvirt_file="/mnt/user/system/libvirt"

# Logging
log_dir="${ssd_root}/unraid_backups"
log_file="${log_dir}/remoteBackupv2.log"

# New appdata zip name (dated)
backup_date="$(date +%d-%b-%Y)"
appdata_zip="${ssd_appdata}/unraid_backup-${backup_date}.zip"

###################################################################################
# Flags

TEST_MODE=false
if [[ "${1-}" == "--test" || "${1-}" == "-t" ]]; then
  TEST_MODE=true
fi

###################################################################################
# Setup logging (append) and basic banner

mkdir -p "$log_dir" "$ssd_appdata" "$ssd_usb" "$nas_appdata" "$nas_usb"
exec > >(tee -a "$log_file") 2>&1

echo ""
echo "[*] UNRAID Remote Backup v2.2"
echo "[*] Mirrors Appdata/USB to SSD & NAS, keeps last ${RETAIN_COUNT}"
if $TEST_MODE; then
  echo "=============================================="
  echo "[TEST MODE ENABLED] No files will be changed."
  echo "=============================================="
fi
echo ""
echo "Appdata src     : $appdata_src"
echo "USB src         : $usb_src"
echo "SSD appdata     : $ssd_appdata"
echo "SSD usb         : $ssd_usb"
echo "NAS appdata     : $nas_appdata"
echo "NAS usb         : $nas_usb"
echo "LIBVIRT         : $libvirt_file"
echo ""

start_time="$(date)"
echo "Start time      : $start_time"

notify_prefix=""
$TEST_MODE && notify_prefix="[TEST MODE] "

/usr/local/emhttp/webGui/scripts/notify \
  -i normal -e "UNRAID Remote Backup" \
  -s "${notify_prefix}Appdata & USB mirror started" \
  -d "Mirroring to SSD & NAS started at $start_time"

###################################################################################
# Helpers

keep_last_n_files () {
  # $1 = directory, $2 = glob (e.g., '*.zip'), $3 = count
  local dir="$1" glob="$2" count="$3"
  [[ -d "$dir" ]] || { echo "WARN: $dir missing; nothing to prune."; return 0; }

  # shellcheck disable=SC2086
  mapfile -t files < <(ls -1t ${dir}/${glob} 2>/dev/null || true)
  local total="${#files[@]}"
  if (( total > count )); then
    echo "Pruning in $dir (pattern: $glob): keep $count of $total, deleting $((total-count)) older..."
    for ((i=count; i<total; i++)); do
      if $TEST_MODE; then
        echo "  [TEST] Would delete ${files[$i]}"
      else
        echo "  - deleting ${files[$i]}"
        rm -f -- "${files[$i]}"
      fi
    done
  else
    echo "No prune needed in $dir (pattern: $glob): total $total <= keep $count"
  fi
}

copy_last_n_files () {
  # $1 = src dir, $2 = dest dir, $3 = glob, $4 = count
  local src="$1" dst="$2" glob="$3" count="$4"
  [[ -d "$src" ]] || { echo "WARN: source $src missing; skipping copy."; return 0; }
  mkdir -p "$dst"
  # shellcheck disable=SC2086
  mapfile -t files < <(ls -1t ${src}/${glob} 2>/dev/null | head -n "$count" || true)
  if (( ${#files[@]} == 0 )); then
    echo "WARN: no files matching ${glob} in $src to copy."
    return 0
  fi
  echo "Copying up to last $count from $src to $dst ..."
  for f in "${files[@]}"; do
    if $TEST_MODE; then
      echo "  [TEST] Would copy $(basename "$f") -> $dst/"
    else
      echo "  - $(basename "$f")"
      cp -u -- "$f" "$dst/"
    fi
  done
}

latest_appdata_folder () {
  # echoes the newest ab_* folder path or empty if none
  ls -1dt "${appdata_src}"/ab_* 2>/dev/null | head -n1
}

zip_appdata_with_libvirt () {
  # $1 = appdata folder, $2 = zip path
  local ab_folder="$1" zip_path="$2"
  if $TEST_MODE; then
    echo "[TEST] Would zip $libvirt_file and $ab_folder into $zip_path"
    return 0
  fi
  zip -rq "$zip_path" "$libvirt_file" "$ab_folder"
}

cp_one () {
  # $1 = source file, $2 = dest dir
  local src="$1" dst="$2"
  if $TEST_MODE; then
    echo "[TEST] Would copy $src -> $dst/"
    return 0
  fi
  cp -u -- "$src" "$dst/"
}

###################################################################################
# 1) USB SOURCE: prune to last N

echo ""
echo "[USB] Pruning USB source to last $RETAIN_COUNT files..."
keep_last_n_files "$usb_src" "*.zip" "$RETAIN_COUNT"

###################################################################################
# 2) USB MIRROR: copy last N to SSD & NAS, then prune mirrors to last N

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
# 3) APPDATA PACKAGE: pick latest folder, zip with LIBVIRT, save on SSD

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
# 4) APPDATA → NAS: copy today’s zip, then prune NAS appdata to last N

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
