#!/bin/zsh
#set -x

############################################################################################
##
## Unified onboarding bootstrap with LaunchDaemon persistence
## Replaces both bootstrap variants (standard + VPN client)
##
## This file is pushed to the Mac via Intune. It writes the onboarding script
## and LaunchDaemon, then loads the daemon for immediate execution.
##
## VER 2.0.0
## Your Organization IT
############################################################################################

# User Defined variables

SCRIPT_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
SCRIPT_PATH="$SCRIPT_DIR/onboarding.zsh"
PLIST_PATH="/Library/LaunchDaemons/com.yourcompany.intune.onboarding.plist"

# Ensure directory exists
mkdir -p "$SCRIPT_DIR"

# --- Write the onboarding script ---
cat > "$SCRIPT_PATH" <<'ONBOARDING_SCRIPT'
#!/bin/zsh
#set -x

############################################################################################
##
## Onboarding coordinator -- two-phase execution with state-based resume
##
## VER 2.0.0
## Your Organization IT
############################################################################################

# ========== Configuration ==========

# Set to true to include the optional VPN client in the onboarding app list
INCLUDE_VPN_CLIENT=false

appname="onBoarding"
logandmetadir="/Library/Application Support/Microsoft/IntuneScripts/$appname"
enrollmentWindowHours=1
checkEnrollmentTime=true
PLIST=/Library/LaunchDaemons/com.yourcompany.intune.onboarding.plist
FLAG="/Library/Application Support/Microsoft/IntuneScripts/$appname/onboardingcompleted.flag"
IN_PROGRESS_FLAG="/Library/Application Support/Microsoft/IntuneScripts/$appname/onboarding_inprogress.flag"
STATE_DIR="/Library/Application Support/Microsoft/IntuneScripts/$appname/state"
CONSOLIDATED_LOG="/Library/Application Support/Microsoft/IntuneScripts/$appname/onboarding-consolidated.log"

# Generated variables
tempdir=$(mktemp -d)
log="$logandmetadir/$appname.log"
metafile="$logandmetadir/$appname.meta"
ONBOARDING_START=$SECONDS

# ========== Logging ==========

mkdir -p "$logandmetadir"
mkdir -p "$STATE_DIR"

echo "$(date) | INFO  | bootstrap | Starting logging to [$logandmetadir/onboard.log]"
exec > >(tee -a "$logandmetadir/onboard.log") 2>&1

# Structured logging functions for the bootstrap
log_bs() { echo "$(date) | $1 | bootstrap | $2"; echo "$(date) | $1 | bootstrap | $2" >> "$CONSOLIDATED_LOG" 2>/dev/null; }
log_info() { log_bs "INFO " "$1"; }
log_warn() { log_bs "WARN " "$1"; }
log_error() { log_bs "ERROR" "$1"; }

# Atomic write helper
atomic_write() {
    local target="$1"
    local content="$2"
    local tmpfile="${target}.tmp"
    echo "$content" > "$tmpfile"
    mv -f "$tmpfile" "$target"
}

# Network check (inline version for bootstrap)
wait_for_network() {
    local max_wait=300
    local waited=0
    local check_interval=5
    while (( waited < max_wait )); do
        if curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "https://yourstorageaccount.blob.core.windows.net" 2>/dev/null | grep -qE '^[234]'; then
            log_info "Network connectivity confirmed"
            return 0
        fi
        log_warn "No network connectivity, waiting ${check_interval}s (${waited}s elapsed)..."
        sleep $check_interval
        waited=$(( waited + check_interval ))
        check_interval=$(( check_interval < 30 ? check_interval * 2 : 30 ))
    done
    log_error "Network not available after ${max_wait}s"
    return 1
}

log_info "Starting Enroll tasks..."
cd "$tempdir"

# ========== Enrollment Window Check ==========

if [[ $checkEnrollmentTime == true ]]; then

    log_info "Checking if we've run before..."
    if [ -e "$FLAG" ]; then

        log_info "Script has already launched onboarding flow before. Cleaning up and exiting."

        log_info "Deleting launchdaemon"
        rm -f "$PLIST"

        log_info "Deleting onboarding script"
        rm -f "$logandmetadir/onboarding.zsh"

        log_info "launchctl bootout launchdaemon"
        launchctl bootout system/com.yourcompany.intune.onboarding 2>/dev/null

        exit 0

    else

        log_info "Checking how long ago this device was enrolled..."

        profile_output=$(profiles -P -v | grep -A 10 "Management Profile")
        install_date=$(echo "$profile_output" | grep -oE 'installationDate:.*' | cut -d' ' -f2-)
        install_date_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$install_date" "+%s")
        log_info "MDM Profile install time [$install_date_seconds]"

        current_time_seconds=$(date "+%s")
        log_info "Current time [$current_time_seconds]"

        time_difference_hours=$(( (current_time_seconds - install_date_seconds) / 3600 ))
        log_info "Time difference [$time_difference_hours] hours"

        if [ "$time_difference_hours" -gt $enrollmentWindowHours ]; then
            log_info "Device was enrolled more than [$enrollmentWindowHours] hour(s) ago, skipping onboarding."

            mkdir -p "$(dirname "$FLAG")"
            atomic_write "$FLAG" "$(date +%s)"

            log_info "Deleting launchdaemon"
            rm -f "$PLIST"

            log_info "Deleting onboarding script"
            rm -f "$logandmetadir/onboarding.zsh"

            log_info "launchctl bootout launchdaemon"
            launchctl bootout system/com.yourcompany.intune.onboarding 2>/dev/null

            exit 0
        else
            log_info "Device was enrolled less than [$enrollmentWindowHours] hour(s) ago, continuing onboarding."
        fi

    fi
fi

# ========== Mark In-Progress ==========

log_info "Creating in-progress flag"
atomic_write "$IN_PROGRESS_FLAG" "$(date +%s)"

# ========== System Info Header ==========

hw_model=$(system_profiler SPHardwareDataType | awk -F': ' '/Model Name/{print $2}')
macos_ver=$(sw_vers -productVersion)
macos_build=$(sw_vers -buildVersion)
serial=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $NF}')
ram=$(system_profiler SPHardwareDataType | awk -F': ' '/Memory/{print $2}')
disk_free=$(df -H / | awk 'NR==2{print $4}' | sed 's/\([0-9]\)\([GMTK]\)/\1 \2B/')
disk_total=$(df -H / | awk 'NR==2{print $2}' | sed 's/\([0-9]\)\([GMTK]\)/\1 \2B/')
ARCH=$(uname -m)

{
    echo "========== ONBOARDING SESSION START =========="
    echo "Date:    $(date)"
    echo "Model:   $hw_model"
    echo "macOS:   $macos_ver (Build $macos_build)"
    echo "Serial:  $serial"
    echo "RAM:     $ram"
    echo "Disk:    ${disk_free} free of ${disk_total}"
    echo "Arch:    $ARCH"
    echo "VPN Client: $INCLUDE_VPN_CLIENT"
    echo "==============================================="
} >> "$CONSOLIDATED_LOG" 2>/dev/null

log_info "System: $hw_model | macOS $macos_ver | $ram | $ARCH"

# ========== Device Naming (Provisioning Status) ==========

log_info "Setting device name to [CMM_PS-$serial] during onboarding"
sudo scutil --set ComputerName "CMM_PS-$serial"
sudo scutil --set LocalHostName "CMM-PS-$serial"
sudo scutil --set HostName "CMM_PS-$serial"

# ========== Rosetta 2 ==========

log_info "Checking if we need Rosetta 2 or not"

if [ "$ARCH" = "arm64" ]; then
    log_info "Apple Silicon Mac detected."

    attempt_counter=0
    max_attempts=10

    until /usr/bin/pgrep oahd || [ $attempt_counter -eq $max_attempts ]; do
        attempt_counter=$(($attempt_counter+1))
        log_info "Attempting to install Rosetta, attempt number: $attempt_counter"
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        sleep 1
    done

    if [ $attempt_counter -eq $max_attempts ]; then
        log_warn "Reached max attempts to install Rosetta, moving on..."
    fi
else
    log_info "This is not an Apple Silicon Mac. No action needed."
fi

# ========== Download & Extract Onboarding Scripts ==========

# Single zip for all variants — VPN client inclusion controlled by INCLUDE_VPN_CLIENT at runtime
onboardingScriptsUrl="https://yourstorageaccount.blob.core.windows.net/your-container/onboarding/OnboardingScripts.zip?YOUR_SAS_TOKEN_HERE"

unzipExitCode=1
downloadattempts=0
while [[ $unzipExitCode -ne 0 ]]; do
    downloadattempts=$((downloadattempts + 1))
    log_info "Attempting to download scripts [$downloadattempts]..."

    # Wait for network before each attempt
    wait_for_network || {
        log_warn "Network not available, will retry..."
    }

    # Fresh download each attempt (no -C - to avoid corrupt partial files)
    rm -f "${tempdir}/OnboardingScripts.zip" 2>/dev/null
    DownloadResult=$(/usr/bin/curl -fL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 5 --retry-all-errors ${onboardingScriptsUrl} -o ${tempdir}/OnboardingScripts.zip -w "%{http_code}")
    log_info "Download HTTP status: $DownloadResult"

    if [[ $DownloadResult -eq 200 ]]; then
        # Validate the zip before attempting extraction
        local zip_size=$(stat -f%z "${tempdir}/OnboardingScripts.zip" 2>/dev/null || echo 0)
        if (( zip_size < 1024 )); then
            log_warn "Downloaded zip too small (${zip_size} bytes), likely corrupt"
            rm -f "${tempdir}/OnboardingScripts.zip"
        else
            log_info "Unzipping scripts ($(( zip_size / 1024 )) KB)..."
            cd "$tempdir"
            unzip -qq -o OnboardingScripts.zip
            unzipExitCode=$?
            if [[ $unzipExitCode -ne 0 ]]; then
                log_warn "Unzip failed, deleting corrupt zip and retrying..."
                rm -f "${tempdir}/OnboardingScripts.zip"
            fi
        fi
    fi

    if [[ $unzipExitCode -ne 0 ]]; then
        # Exponential backoff: 2, 4, 8, 16, 32
        local delay=$(( 2 ** downloadattempts ))
        (( delay > 32 )) && delay=32
        log_info "Retrying in ${delay}s..."
        sleep $delay
    fi

    if [[ $downloadattempts -gt 5 ]]; then
        log_error "Failed to download and unzip onboarding scripts after 5 attempts, exiting..."
        exit 1
    fi
done

SCRIPTS_DIR="$tempdir/OnboardingScripts"

# ========== Move Icons + JSON ==========

swiftdialogfolder="/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog"
log_info "Moving icons and json file to $swiftdialogfolder"
mkdir -p "$swiftdialogfolder"
rm -rf "$swiftdialogfolder/icons" 2>/dev/null
mv "$SCRIPTS_DIR/icons" "$swiftdialogfolder/icons"
mv -f "$SCRIPTS_DIR/swiftdialog.json" "$swiftdialogfolder/swiftdialog.json"

# Ensure Swift Dialog assets are world-readable
chmod 644 "$swiftdialogfolder/swiftdialog.json"
chmod -R a+rX "$swiftdialogfolder/icons"

# ========== Wait for Desktop ==========

log_info "Waiting for user to reach the desktop (Dock process)..."
local dock_waited=0
until ps aux | grep /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -v grep &>/dev/null; do
    if (( dock_waited % 30 == 0 )); then
        log_info "Dock not running yet, user likely in Setup Assistant... (${dock_waited}s elapsed)"
    fi
    sleep 5
    dock_waited=$(( dock_waited + 5 ))
done
log_info "Dock is running (waited ${dock_waited}s) — user is at the desktop"

# ========== Install & Launch Swift Dialog ==========

log_info "Starting Swift Dialog installation script"
xattr -d com.apple.quarantine "$SCRIPTS_DIR/install-dialog.zsh" 2>/dev/null
chmod +x "$SCRIPTS_DIR/install-dialog.zsh"
nice -n -5 "$SCRIPTS_DIR/install-dialog.zsh" &

START=$(date +%s)
log_info "Waiting for Swift Dialog to Start..."
until ps aux | grep /usr/local/bin/dialog | grep -v grep &>/dev/null; do
    if [[ $(($(date +%s) - $START)) -ge 300 ]]; then
        log_error "Failed: Swift Dialog did not start within 5 minutes"
        exit 1
    fi
    sleep 5
done
log_info "Swift Dialog is running"

# ========== Sleep Prevention ==========

log_info "Starting caffeinate to prevent sleep during onboarding"
caffeinate -d -i -s &
CAFFEINATE_PID=$!

log_info "Starting display keep-alive loop (every 60s)"
(while true; do caffeinate -u -t 2; sleep 60; done) &
DISPLAY_KEEP_ALIVE_PID=$!

# ========== Health Check Loop ==========

log_info "Starting periodic health check (every 120s)"
(while true; do
    sleep 120
    # Re-assert user activity to prevent sleep
    caffeinate -u -t 2
    # Check network is still alive
    if ! curl -s --connect-timeout 5 -o /dev/null "https://yourstorageaccount.blob.core.windows.net" 2>/dev/null; then
        echo "$(date) | WARN  | health-check | Network connectivity lost, waiting for recovery..." >> "$CONSOLIDATED_LOG"
    fi
done) &
HEALTH_CHECK_PID=$!

# Give Swift Dialog a chance to fully render
sleep 10

# ========== Populate Infobox with Device Info ==========

log_info "Updating Swift Dialog infobox with device info"
printf '%s\n' "infobox: **Model:** ${hw_model}\\n**macOS:** ${macos_ver}\\n**Serial:** ${serial}\\n**RAM:** ${ram}\\n**Disk Free:** ${disk_free}" >> /var/tmp/dialog.log

# ========== Power Check ==========

if system_profiler SPHardwareDataType 2>/dev/null | grep -qi "MacBook"; then
    local charging=$(pmset -g batt 2>/dev/null | grep -c "AC Power")
    if [[ "$charging" -eq 0 ]]; then
        log_warn "Running on battery power — recommending user connect to power"
        printf '%s\n' "infobox: **Model:** ${hw_model}\\n**macOS:** ${macos_ver}\\n**Serial:** ${serial}\\n**RAM:** ${ram}\\n**Disk Free:** ${disk_free}\\n\\n⚠️ **Please connect to power** for reliable onboarding." >> /var/tmp/dialog.log
    else
        log_info "AC power connected"
    fi
fi

# ========== Read App Manifest ==========

APPS_CONF="$SCRIPTS_DIR/config/apps.conf"
log_info "Reading app manifest from [$APPS_CONF]"

# Make all scripts executable
chmod +x "$SCRIPTS_DIR"/install-*.zsh 2>/dev/null
# Remove quarantine from all scripts
find "$SCRIPTS_DIR" -name "*.zsh" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null

# Parse apps.conf into parallel and sequential arrays
typeset -a PARALLEL_APPS
typeset -a SEQUENTIAL_APPS

# Also build display name and bundle lookups for the summary
typeset -A APP_DISPLAY_NAMES
typeset -A APP_BUNDLES

while IFS='|' read -r cfg_id cfg_display cfg_bundle cfg_urlkey cfg_process cfg_terminate cfg_autoupdate cfg_phase cfg_handler cfg_icon; do
    [[ "$cfg_id" == \#* ]] && continue
    [[ -z "$cfg_id" ]] && continue

    # Skip VPN client unless INCLUDE_VPN_CLIENT is true
    if [[ "$cfg_id" == "AppTen" && "$INCLUDE_VPN_CLIENT" != "true" ]]; then
        log_info "Skipping VPN client (INCLUDE_VPN_CLIENT=$INCLUDE_VPN_CLIENT)"
        continue
    fi

    APP_DISPLAY_NAMES[$cfg_id]="$cfg_display"
    APP_BUNDLES[$cfg_id]="$cfg_bundle"

    if [[ "$cfg_phase" == "parallel" ]]; then
        PARALLEL_APPS+=("${cfg_id}|${cfg_handler}")
    elif [[ "$cfg_phase" == "after_parallel" ]]; then
        SEQUENTIAL_APPS+=("${cfg_id}|${cfg_handler}")
    fi
done < "$APPS_CONF"

TOTAL_APPS=$(( ${#PARALLEL_APPS[@]} + ${#SEQUENTIAL_APPS[@]} ))
COMPLETED=0
PHASE1_TOTAL=${#PARALLEL_APPS[@]}
PHASE1_COMPLETED=0

log_info "Found $TOTAL_APPS apps: ${#PARALLEL_APPS[@]} parallel, ${#SEQUENTIAL_APPS[@]} sequential"

# Phase-aware progress update helper
update_phase_progress() {
    local pct=$(( (COMPLETED * 100) / TOTAL_APPS ))
    local remaining=$(( TOTAL_APPS - COMPLETED ))
    echo "progress: $pct" >> /var/tmp/dialog.log
    if [[ $remaining -gt 0 ]]; then
        echo "progresstext: ${COMPLETED} of ${TOTAL_APPS} installed — ${remaining} remaining" >> /var/tmp/dialog.log
    else
        echo "progresstext: All ${TOTAL_APPS} applications installed" >> /var/tmp/dialog.log
    fi
}

echo "progress: 1" >> /var/tmp/dialog.log
echo "progresstext: 0 of ${TOTAL_APPS} installed — ${TOTAL_APPS} remaining" >> /var/tmp/dialog.log

# ========== Helper: Launch an app install ==========

launch_app_install() {
    local app_id="$1"
    local handler="$2"

    # Check if already completed (reboot resilience)
    if [[ -f "$STATE_DIR/${app_id}.done" ]]; then
        local result
        result=$(cat "$STATE_DIR/${app_id}.done")
        if [[ "$result" == "success" ]]; then
            log_info "[$app_id] already completed, skipping"
            return 0
        fi
    fi

    local script_path
    case "$handler" in
        standard)        script_path="$SCRIPTS_DIR/install-standard.zsh" ;;
        chunked)         script_path="$SCRIPTS_DIR/install-chunked.zsh" ;;
        mdm-enrollment)  script_path="$SCRIPTS_DIR/install-mdm-enrollment.zsh" ;;
        licensed)        script_path="$SCRIPTS_DIR/install-licensed.zsh" ;;
        *)
            log_error "Unknown handler [$handler] for [$app_id]"
            return 1
            ;;
    esac

    log_info "Launching [$app_id] via handler [$handler]"

    if [[ "$handler" == "standard" ]]; then
        nice -n 10 "$script_path" "$app_id"
    else
        nice -n 10 "$script_path"
    fi
    return $?
}

# ========== Phase 1: Parallel Apps ==========

log_info "=== PHASE 1: Launching ${#PARALLEL_APPS[@]} parallel apps ==="

typeset -A APP_PIDS
typeset -A APP_START_TIMES

for entry in "${PARALLEL_APPS[@]}"; do
    local app_id="${entry%%|*}"
    local handler="${entry##*|}"

    # Skip already completed apps
    if [[ -f "$STATE_DIR/${app_id}.done" ]] && [[ "$(cat "$STATE_DIR/${app_id}.done")" == "success" ]]; then
        log_info "[$app_id] already completed, skipping"
        COMPLETED=$((COMPLETED + 1))
        PHASE1_COMPLETED=$((PHASE1_COMPLETED + 1))
        continue
    fi

    APP_START_TIMES[$app_id]=$SECONDS
    launch_app_install "$app_id" "$handler" &
    _bg_pid=$!
    APP_PIDS[$app_id]=$_bg_pid
    log_info "Started [$app_id] with PID $_bg_pid"
done

# Update progress for already-completed apps
if [[ $COMPLETED -gt 0 ]]; then
    update_phase_progress
fi

# Wait for parallel apps using polling loop (updates progress as each finishes)
typeset -A APP_RESULTS
typeset -A APP_ELAPSED
typeset -A APP_COUNTED

while [[ $PHASE1_COMPLETED -lt ${#APP_PIDS[@]} ]]; do
    for app_id in ${(k)APP_PIDS}; do
        [[ -n "${APP_COUNTED[$app_id]}" ]] && continue

        if ! kill -0 ${APP_PIDS[$app_id]} 2>/dev/null; then
            wait ${APP_PIDS[$app_id]}
            local exit_code=$?
            APP_COUNTED[$app_id]=1
            APP_RESULTS[$app_id]=$exit_code

            local app_elapsed=$(( SECONDS - APP_START_TIMES[$app_id] ))
            APP_ELAPSED[$app_id]=$app_elapsed

            if [[ $exit_code -eq 0 ]]; then
                atomic_write "$STATE_DIR/${app_id}.done" "success"
                log_info "[$app_id] completed successfully (exit 0) in ${app_elapsed}s"
            else
                atomic_write "$STATE_DIR/${app_id}.done" "fail:$exit_code"
                log_error "[$app_id] FAILED (exit $exit_code) after ${app_elapsed}s"
            fi

            COMPLETED=$((COMPLETED + 1))
            PHASE1_COMPLETED=$((PHASE1_COMPLETED + 1))
            update_phase_progress
        fi
    done

    if [[ $PHASE1_COMPLETED -lt ${#APP_PIDS[@]} ]]; then
        sleep 3
    fi
done

log_info "=== PHASE 1 COMPLETE: All parallel apps finished ==="

# ========== Phase 2: Sequential Apps (after_parallel) ==========

if [[ ${#SEQUENTIAL_APPS[@]} -gt 0 ]]; then
    log_info "=== PHASE 2: Running ${#SEQUENTIAL_APPS[@]} sequential apps ==="
    local PHASE2_TOTAL=${#SEQUENTIAL_APPS[@]}
    local PHASE2_COMPLETED=0

    for entry in "${SEQUENTIAL_APPS[@]}"; do
        local app_id="${entry%%|*}"
        local handler="${entry##*|}"

        # Skip already completed
        if [[ -f "$STATE_DIR/${app_id}.done" ]] && [[ "$(cat "$STATE_DIR/${app_id}.done")" == "success" ]]; then
            log_info "[$app_id] already completed, skipping"
            COMPLETED=$((COMPLETED + 1))
            PHASE2_COMPLETED=$((PHASE2_COMPLETED + 1))
            update_phase_progress
            continue
        fi

        log_info "Running sequential app [$app_id]"
        APP_START_TIMES[$app_id]=$SECONDS
        launch_app_install "$app_id" "$handler"
        local exit_code=$?
        APP_RESULTS[$app_id]=$exit_code

        local app_elapsed=$(( SECONDS - APP_START_TIMES[$app_id] ))
        APP_ELAPSED[$app_id]=$app_elapsed

        if [[ $exit_code -eq 0 ]]; then
            atomic_write "$STATE_DIR/${app_id}.done" "success"
            log_info "[$app_id] completed successfully (exit 0) in ${app_elapsed}s"
        else
            atomic_write "$STATE_DIR/${app_id}.done" "fail:$exit_code"
            log_error "[$app_id] FAILED (exit $exit_code) after ${app_elapsed}s"
        fi

        COMPLETED=$((COMPLETED + 1))
        PHASE2_COMPLETED=$((PHASE2_COMPLETED + 1))
        update_phase_progress
    done

    log_info "=== PHASE 2 COMPLETE ==="
fi

# ========== Stop Sleep Prevention & Health Check ==========

log_info "Stopping caffeinate, display keep-alive, and health check"
kill "$CAFFEINATE_PID" 2>/dev/null
kill "$DISPLAY_KEEP_ALIVE_PID" 2>/dev/null
kill "$HEALTH_CHECK_PID" 2>/dev/null

log_info "All onboarding scripts finished."

# ========== Results Summary ==========

FAILED_APPS=()
SUCCEEDED_APPS=()
TOTAL_ELAPSED=$(( SECONDS - ONBOARDING_START ))

for app_id exit_code in ${(kv)APP_RESULTS}; do
    if [[ $exit_code -eq 0 ]]; then
        SUCCEEDED_APPS+=("$app_id")
    else
        FAILED_APPS+=("$app_id")
    fi
done

# Verify: reclassify false failures where app actually installed
local verified_failed=()
for app_id in "${FAILED_APPS[@]}"; do
    local bundle="${APP_BUNDLES[$app_id]}"
    if [[ -n "$bundle" && -d "/Applications/$bundle" ]]; then
        log_warn "[$app_id] exit code indicated failure but app exists in /Applications — reclassifying as success"
        atomic_write "$STATE_DIR/${app_id}.done" "success"
        echo "listitem: title: ${APP_DISPLAY_NAMES[$app_id]}, status: success, statustext: Installed" >> /var/tmp/dialog.log
        SUCCEEDED_APPS+=("$app_id")
    else
        verified_failed+=("$app_id")
    fi
done
FAILED_APPS=("${verified_failed[@]}")

log_info "=== RESULTS ==="
log_info "Succeeded: ${SUCCEEDED_APPS[*]:-none}"
log_info "Failed: ${FAILED_APPS[*]:-none}"

# Write formatted summary table to consolidated log
{
    echo ""
    echo "============ ONBOARDING SUMMARY ============"
    printf "%-30s %-10s %s\n" "App" "Status" "Time"
    echo "---------------------------------------------"

    # Iterate through all apps in manifest order
    for entry in "${PARALLEL_APPS[@]}" "${SEQUENTIAL_APPS[@]}"; do
        local app_id="${entry%%|*}"
        local display="${APP_DISPLAY_NAMES[$app_id]:-$app_id}"
        local app_status="SKIPPED"
        local elapsed_str="-"

        if [[ -n "${APP_RESULTS[$app_id]+x}" ]]; then
            if [[ ${APP_RESULTS[$app_id]} -eq 0 ]]; then
                app_status="SUCCESS"
            else
                app_status="FAILED"
            fi
        fi

        if [[ -n "${APP_ELAPSED[$app_id]+x}" ]]; then
            elapsed_str="${APP_ELAPSED[$app_id]}s"
        fi

        printf "%-30s %-10s %s\n" "$display" "$app_status" "$elapsed_str"
    done

    echo "---------------------------------------------"
    local total_min=$(( TOTAL_ELAPSED / 60 ))
    local total_sec=$(( TOTAL_ELAPSED % 60 ))
    echo "Total elapsed: ${total_min}m ${total_sec}s  |  ${#SUCCEEDED_APPS[@]} succeeded, ${#FAILED_APPS[@]} failed"
    echo "============================================="
    echo ""
} >> "$CONSOLIDATED_LOG" 2>/dev/null

# ========== Device Rename (Onboarding Complete) ==========

serial=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $NF}')
log_info "Setting device name to [CMM-$serial] to indicate onboarding complete"
sudo scutil --set ComputerName "CMM-$serial"
sudo scutil --set LocalHostName "CMM-$serial"
sudo scutil --set HostName "CMM-$serial"

# ========== Completion ==========

mkdir -p "$(dirname "$FLAG")"
atomic_write "$FLAG" "$(date +%s)"
rm -f "$IN_PROGRESS_FLAG"

# Dismiss Swift Dialog
log_info "Closing Swift Dialog"
echo "quit:" >> /var/tmp/dialog.log

# Build comma-delimited display name lists for the completion dialog
local succeeded_names=()
for app_id in "${SUCCEEDED_APPS[@]}"; do
    succeeded_names+=("${APP_DISPLAY_NAMES[$app_id]:-$app_id}")
done
local failed_names=()
for app_id in "${FAILED_APPS[@]}"; do
    failed_names+=("${APP_DISPLAY_NAMES[$app_id]:-$app_id}")
done

# Show completion dialog via Swift Dialog (if available) or AppleScript
if [[ -x "/usr/local/bin/dialog" ]]; then
    if [[ ${#FAILED_APPS[@]} -gt 0 ]]; then
        /usr/local/bin/dialog \
            --title "Onboarding Complete!" \
            --titlefont "size=26" \
            --message "**Welcome to the Cloud Managed macOS (CMM)**\n\nOnboarding has finished with some issues.\n\n**Succeeded:** ${(j:, :)succeeded_names:-none}\n\n**Failed:** ${(j:, :)failed_names}\n\nFailed applications will be retried on next login or can be installed manually.\n\n_Optional applications may be installed from the MDM enrollment client found in your Applications folder._" \
            --messagefont "size=14" \
            --icon "/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog/icons/logo.png" \
            --iconsize 100 \
            --button1text "Get Started" \
            --button1symbol "checkmark.circle.fill" \
            --buttonstyle center \
            --button1textsize 20 \
            --width 650 --height 450 \
            --centreicon
    else
        /usr/local/bin/dialog \
            --title "Onboarding Complete!" \
            --titlefont "size=26" \
            --message "**Welcome to the Cloud Managed macOS (CMM)**\n\n_Optional applications may be installed from the MDM enrollment client found in your Applications folder._" \
            --messagefont "size=14" \
            --icon "/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog/icons/logo.png" \
            --iconsize 100 \
            --button1text "Get Started" \
            --button1symbol "checkmark.circle.fill" \
            --buttonstyle center \
            --button1textsize 20 \
            --width 650 --height 350 \
            --centreicon
    fi
else
    osascript -e 'display dialog "Onboarding Complete! Welcome to the Cloud Managed macOS (CMM). Optional applications may be installed from the MDM enrollment client found in your Applications folder." buttons {"Get Started"} default button "Get Started"'
fi

# Cleanup
log_info "Deleting launchdaemon"
rm -f "$PLIST"

log_info "Deleting onboarding script"
rm -f "$logandmetadir/onboarding.zsh"

log_info "launchctl bootout launchdaemon"
launchctl bootout system/com.yourcompany.intune.onboarding 2>/dev/null

exit 0
ONBOARDING_SCRIPT

chmod 755 "$SCRIPT_PATH"

# --- Write the launchd plist ---
cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yourcompany.intune.onboarding</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboarding.zsh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Relaunch only if it fails -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"

# --- Load the launchd job immediately ---
# First check if LaunchDaemon is already loaded and unload it
if launchctl print system/com.yourcompany.intune.onboarding &>/dev/null; then
    echo "LaunchDaemon already loaded, unloading first..."
    launchctl bootout system/com.yourcompany.intune.onboarding 2>/dev/null
    sleep 1
fi

launchctl bootstrap system "$PLIST_PATH"
launchctl enable system/com.yourcompany.intune.onboarding
