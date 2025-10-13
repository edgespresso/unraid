#!/bin/bash
#
# UNRAID Remote Backup v2.3
# By: Edge
#
# Updated: Oct 13, 2025
# Notes:
# - Keep LAST N backups (count-based) for USB and Appdata on SSD and NAS
# - Write-readiness checks for SSD and NAS (clear Unraid notify if not usable)
# - Prune USB SOURCE to last N (plugin doesn’t auto-prune USB)
# - Appdata source remains plugin-managed (already prunes to ~7 folders)
# - Packaging: tar + zstd (multi-threaded) for Appdata+LIBVIRT
# - --test / -t: soft dry run (no file changes), still logs & sends notifications
# - Logs: rolling log + rotate dated logs, keep last N (default 7)
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

# Logging -> /mnt/disks/ssd/logs/remoteBackup.log
log_dir="${ssd_root}/logs"
log_file="${log_dir}/remoteBackup.log"

backup_date="$(date +%d-%b-%Y)"
appdata_archive="${ssd_appdata}/appdata_backup-${backup_date}.tar.zst"

###################################################################################
# Flags
TEST_MODE=false
[[ "${1-}" == "--test" || "${1-}" == "-t" ]] && TEST_MODE=true

notify_prefix=""
$TEST_MODE && notify_prefix="[TEST MODE] "

###################################################################################
# Target readiness check
require_target_ready () {
  local base="$1" label="$2"
  local subs=("" "/appdata_backups" "/usb_backups")

  if [[ ! -d "$base" ]]; then
    echo "ERROR: $label base path missing: $base"
    /usr/local/emhttp/webGui/scripts/notify \
      -i warning -e "UNRAID Remote Backup" \
      -s "${notify_prefix}${label} path missing" \
      -d "$base does not exist. Aborting backup."
    exit 1
  fi

  for s in "${subs[@]}"; do
    local d="${base}${s}"
    if [[ ! -d "$d" ]]; then
      if $TEST_MODE; then
        echo "[TEST] Would create directory: $d"
      else
        mkdir -p -- "$d" || {
          echo "ERROR: Failed to create directory: $d"
          /usr/local/emhttp/webGui/scripts/notify \
            -i warning -e "UNRAID Remote Backup" \
            -s "${notify_prefix}${label} not writable" \
            -d "Failed to create $d. Aborting backup."
          exit 1
        }
        echo "Created directory: $d"
      fi
    fi

    if $TEST_MODE; then
      echo "[TEST] $label path present: $d"
      continue
    fi

    local probe="$d/.remoteBackup_write_test.$$"
    if ! ( : > "$probe" ) 2>/dev/null; then
      echo "ERROR: $label not writable (likely not mounted): $d"
      /usr/local/emhttp/webGui/scripts/notify \
        -i warning -e "UNRAID Remote Backup" \
        -s "${notify_prefix}${label} not mounted or not writable" \
        -d "$d is not writable. Aborting backup."
      exit 1
    fi
    rm -f -- "$probe"
  done
}

require_target_ready "$ssd_root" "SSD"
require_target_ready "$nas_root" "Remote NAS"

###################################################################################
# Setup logging + rotation
mkdir -p "$log_dir"
today="$(date +%Y%m%d)"
rotated_log="${log_dir}/remoteBackup-${today}.log"
if [[ -f "$log_file" && ! -f "$rotated_log" ]]; then
  cp "$log_file" "$rotated_log"
fi

mapfile -t logfiles < <(ls -1t ${log_dir}/remoteBackup-*.log 2>/dev/null || true)
total_logs="${#logfiles[@]}"
if (( total_logs > RETAIN_COUNT )); then
  echo "Rotating logs: keeping $RETAIN_COUNT of $total_logs ..."
  for ((i=RETAIN_COUNT; i<total_logs; i++)); do
    echo "  - deleting old log ${logfiles[$i]}"
    rm -f -- "${logfiles[$i]}"
  done
fi

exec > >(tee -a "$log_file") 2>&1

###################################################################################
# Header output
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
      $TEST_MODE && echo "  [TEST] Would delete ${files[$i]}" \
        || { echo "  - deleting ${files[$i]}"; rm -f -- "${files[$i]}"; }
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
    $TEST_MODE && echo "  [TEST] Would copy $(basename "$f") -> $dst/" \
      || { echo "  - $(basename "$f")"; cp -u -- "$f" "$dst/"; }
  done
}

latest_appdata_folder () { ls -1dt "${appdata_src}"/ab_* 2>/dev/null | head -n1; }

tar_appdata_with_libvirt () {
  local ab_folder="$1" archive_path="$2"
  if $TEST_MODE; then
    echo "[TEST] Would tar+zstd $libvirt_file and $ab_folder into $archive_path"
    return 0
  fi
  tar -I "zstd -T0 -5" -cf "$archive_path" "$libvirt_file" "$ab_folder"
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

echo "[APPDATA] Creating daily archive on SSD: $appdata_archive"
if tar_appdata_with_libvirt "$latest_ab" "$appdata_archive"; then
  $TEST_MODE && echo "Archive simulation OK." || echo "Archive created (tar.zst)."
else
  echo "ERROR: Archive step failed. Terminating."
  /usr/local/emhttp/webGui/scripts/notify -i warning \
    -s "${notify_prefix}Remote Backup Failed" \
    -d "Tar+zstd of LIBVIRT + latest Appdata failed"
  exit 1
fi

echo "[APPDATA] Pruning SSD appdata_backups to last $RETAIN_COUNT archives..."
keep_last_n_files "$ssd_appdata" "*.tar.zst" "$RETAIN_COUNT"

###################################################################################
# 4) APPDATA → NAS
echo ""
echo "[APPDATA] Copying today's appdata archive to NAS..."
if cp_one "$appdata_archive" "$nas_appdata"; then
  $TEST_MODE && echo "NAS copy simulated OK." || echo "NAS copy successful."
else
  echo "ERROR: NAS copy failed."
  /usr/local/emhttp/webGui/scripts/notify -i warning \
    -s "${notify_prefix}Remote Backup Failed" \
    -d "Copy of Appdata archive to NAS failed"
  exit 1
fi

echo "[APPDATA] Pruning NAS appdata_backups to last $RETAIN_COUNT archives..."
keep_last_n_files "$nas_appdata" "*.tar.zst" "$RETAIN_COUNT"

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
