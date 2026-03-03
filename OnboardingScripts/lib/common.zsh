#!/bin/zsh
############################################################################################
##
## common.zsh -- Shared function library for all onboarding install scripts
##
## VER 2.0.0
##
## Replaces ~8,500 lines of duplicated code across 9 scripts with a single ~600 line file.
## Every installer sources this file:
##   source "${0:A:h}/../lib/common.zsh"   # when script is in OnboardingScripts/
##   source "${0:A:h}/lib/common.zsh"       # when script is at OnboardingScripts/ level
##
## Your Organization IT
############################################################################################

# Paths
CONSOLIDATED_LOG="/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboarding-consolidated.log"
STATE_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding/state"
DIALOG_LOG="/var/tmp/dialog.log"
DIALOG_BIN="/usr/local/bin/dialog"

# Prevent SIGPIPE from killing install scripts (tee logging pipe can break)
trap '' PIPE

# Ensure state directory exists
mkdir -p "$STATE_DIR" 2>/dev/null

###############################################################
## Logging
###############################################################

log_info() {
    local msg="$(date) | INFO  | ${appname:-unknown} | $*"
    echo "$msg"
    echo "$msg" >> "$CONSOLIDATED_LOG" 2>/dev/null
}

log_warn() {
    local msg="$(date) | WARN  | ${appname:-unknown} | $*"
    echo "$msg"
    echo "$msg" >> "$CONSOLIDATED_LOG" 2>/dev/null
}

log_error() {
    local msg="$(date) | ERROR | ${appname:-unknown} | $*"
    echo "$msg"
    echo "$msg" >> "$CONSOLIDATED_LOG" 2>/dev/null
}

function startLog() {
    if [[ ! -d "$logandmetadir" ]]; then
        log_info "Creating [$logandmetadir] to store logs"
        mkdir -p "$logandmetadir"
    fi
    exec > >(tee -a "$log") 2>&1
}

###############################################################
## Utility Functions
###############################################################

humanize_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then printf "%.1f GB" $(( bytes / 1073741824.0 ))
    elif (( bytes >= 1048576 )); then printf "%.0f MB" $(( bytes / 1048576.0 ))
    elif (( bytes >= 1024 )); then printf "%.0f KB" $(( bytes / 1024.0 ))
    else printf "%d B" $bytes; fi
}

get_download_size() {
    local url="$1"
    local content_length=$(curl -sI -L --connect-timeout 5 "$url" | grep -i 'content-length' | tail -1 | awk '{print $2}' | tr -d '\r')
    if [[ -n "$content_length" && "$content_length" -gt 0 ]] 2>/dev/null; then
        humanize_bytes "$content_length"
    fi
}

retry_delay() {
    local attempt=$1
    local base=5
    local max=60
    local delay=$(( base * (2 ** (attempt - 1)) ))
    (( delay > max )) && delay=$max
    # Add jitter: ±25%
    local jitter=$(( RANDOM % (delay / 2 + 1) - delay / 4 ))
    delay=$(( delay + jitter ))
    (( delay < 1 )) && delay=1
    echo $delay
}

###############################################################
## Power & Sleep Checks
###############################################################

check_power_status() {
    # Only relevant for laptops (MacBooks)
    if system_profiler SPHardwareDataType 2>/dev/null | grep -qi "MacBook"; then
        local charging=$(pmset -g batt 2>/dev/null | grep -c "AC Power")
        if [[ "$charging" -eq 0 ]]; then
            log_warn "Running on battery power — please connect to power for reliable onboarding"
            return 1  # on battery
        else
            log_info "AC power connected"
            return 0  # on AC
        fi
    fi
    return 0  # desktop, always "powered"
}

###############################################################
## Network & Download Validation
###############################################################

wait_for_network() {
    local max_wait=300  # 5 minutes
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
        # Exponential backoff capped at 30s
        check_interval=$(( check_interval < 30 ? check_interval * 2 : 30 ))
    done
    log_error "Network not available after ${max_wait}s"
    return 1
}

validate_download() {
    local file="$1"
    local expected_type="$2"  # optional: "pkg", "dmg", "zip", etc.

    # Check file exists and is non-empty
    if [[ ! -s "$file" ]]; then
        log_error "Downloaded file is missing or empty: $file"
        return 1
    fi

    # Check minimum size (anything < 1KB is likely an error page)
    local size=$(stat -f%z "$file" 2>/dev/null || echo 0)
    if (( size < 1024 )); then
        log_error "Downloaded file too small (${size} bytes), likely corrupt: $file"
        return 1
    fi

    # Validate file magic bytes match expected type
    local file_type=$(file -b "$file")
    if [[ -n "$expected_type" ]]; then
        case "$expected_type" in
            pkg) [[ "$file_type" == *"xar archive"* ]] || { log_warn "File doesn't look like a PKG: $file_type"; } ;;
            dmg) [[ "$file_type" == *"Apple"* || "$file_type" == *"DOS/MBR"* ]] || { log_warn "File doesn't look like a DMG: $file_type"; } ;;
            zip) [[ "$file_type" == *"Zip archive"* ]] || { log_warn "File doesn't look like a ZIP: $file_type"; } ;;
        esac
    fi

    log_info "Download validated: $(humanize_bytes $size)"
    return 0
}

###############################################################
## Timing
###############################################################

APP_TIMER_START=0
DOWNLOAD_TIMER_START=0

start_app_timer()      { APP_TIMER_START=$SECONDS; }
start_download_timer() { DOWNLOAD_TIMER_START=$SECONDS; }

log_download_time() {
    local elapsed=$(( SECONDS - DOWNLOAD_TIMER_START ))
    log_info "Download completed in ${elapsed}s"
}

log_app_time() {
    local elapsed=$(( SECONDS - APP_TIMER_START ))
    log_info "[$appname] total time: ${elapsed}s"
}

###############################################################
## Per-Step State Tracking
###############################################################

mark_step() {
    local id="${APP_ID}"
    local step="$1"  # "downloaded" or "installing"
    local tmpfile="${STATE_DIR}/.${id}_step.tmp"
    echo "$step" > "$tmpfile"
    mv -f "$tmpfile" "${STATE_DIR}/${id}.step"
}

get_step() {
    local id="${APP_ID}"
    if [[ -f "${STATE_DIR}/${id}.step" ]]; then
        cat "${STATE_DIR}/${id}.step"
    fi
}

###############################################################
## Atomic State Writes
###############################################################

atomic_write() {
    local target="$1"
    local content="$2"
    local tmpfile="${target}.tmp"
    echo "$content" > "$tmpfile"
    mv -f "$tmpfile" "$target"
}

###############################################################
## Config Loading
###############################################################

# Parse apps.conf for a given APP_ID and set all variables
# Usage: load_app_config "Edge"
load_app_config() {
    local target_id="$1"
    local config_file="${COMMON_LIB_DIR}/../config/apps.conf"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    local line
    while IFS='|' read -r cfg_id cfg_display cfg_bundle cfg_urlkey cfg_process cfg_terminate cfg_autoupdate cfg_phase cfg_handler cfg_icon; do
        # Skip comments and empty lines
        [[ "$cfg_id" == \#* ]] && continue
        [[ -z "$cfg_id" ]] && continue

        if [[ "$cfg_id" == "$target_id" ]]; then
            appname="$cfg_display"
            app="$cfg_bundle"
            APP_URL_KEY="$cfg_urlkey"
            processpath="$cfg_process"
            terminateprocess="$cfg_terminate"
            autoUpdate="$cfg_autoupdate"
            APP_PHASE="$cfg_phase"
            APP_HANDLER="$cfg_handler"
            APP_ICON="$cfg_icon"
            APP_ID="$cfg_id"

            # Resolve the actual URL from the URL key variable
            weburl="${(P)APP_URL_KEY}"

            # Set up per-app logging directory
            logandmetadir="/Library/Application Support/Microsoft/IntuneScripts/install${APP_ID}"
            tempdir=$(mktemp -d)
            log="$logandmetadir/$appname.log"
            metafile="$logandmetadir/$appname.meta"

            log_info "Loaded config for [$appname] (handler=$APP_HANDLER, phase=$APP_PHASE)"
            return 0
        fi
    done < "$config_file"

    log_error "App ID [$target_id] not found in $config_file"
    return 1
}

###############################################################
## Process Management
###############################################################

waitForProcess() {
    local processName="$1"
    local fixedDelay="$2"
    local terminate="$3"

    # Skip if no process to wait for
    if [[ -z "$processName" || "$processName" == "none" ]]; then
        log_info "No process to wait for, continuing"
        return 0
    fi

    log_info "Waiting for other [$processName] processes to end"
    updateSplashScreen wait "Waiting for process..."
    while ps aux | grep "$processName" | grep -v grep &>/dev/null; do
        if [[ "$terminate" == "true" ]]; then
            local pid
            pid=$(ps -fe | grep "$processName" | grep -v grep | awk '{print $2}')
            log_info "[$appname] running, terminating [$processName] at pid [$pid]"
            kill -9 $pid
            return
        fi

        local delay
        if [[ -z "$fixedDelay" ]]; then
            delay=$(( $RANDOM % 50 + 10 ))
        else
            delay=$fixedDelay
        fi

        log_info "Another instance of $processName is running, waiting [$delay] seconds"
        sleep $delay
    done

    log_info "No instances of [$processName] found, safe to proceed"
}

waitForDesktop() {
    local waited=0
    until ps aux | grep /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -v grep &>/dev/null; do
        if (( waited % 30 == 0 )); then
            log_info "Dock not running, waiting... (${waited}s elapsed)"
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    log_info "Dock is running (waited ${waited}s)"
}

###############################################################
## System Checks
###############################################################

checkForRosetta2() {
    log_info "Checking if we need Rosetta 2 or not"

    waitForProcess "/usr/sbin/softwareupdate"

    OLDIFS=$IFS
    IFS='.' read osvers_major osvers_minor osvers_dot_version <<< "$(/usr/bin/sw_vers -productVersion)"
    IFS=$OLDIFS

    if [[ ${osvers_major} -ge 11 ]]; then
        local processor
        processor=$(/usr/sbin/sysctl -n machdep.cpu.brand_string | grep -o "Intel")

        if [[ -n "$processor" ]]; then
            log_info "$processor processor installed. No need to install Rosetta."
        else
            if /usr/bin/pgrep oahd >/dev/null 2>&1; then
                log_info "Rosetta is already installed and running. Nothing to do."
            else
                /usr/sbin/softwareupdate --install-rosetta --agree-to-license
                if [[ $? -eq 0 ]]; then
                    log_info "Rosetta has been successfully installed."
                else
                    log_error "Rosetta installation failed!"
                fi
            fi
        fi
    else
        log_info "Mac is running macOS $osvers_major.$osvers_minor.$osvers_dot_version."
        log_info "No need to install Rosetta on this version of macOS."
    fi
}

###############################################################
## Update Check
###############################################################

fetchLastModifiedDate() {
    if [[ ! -d "$logandmetadir" ]]; then
        log_info "Creating [$logandmetadir] to store metadata"
        mkdir -p "$logandmetadir"
    fi

    lastmodified=$(curl -sIL "$weburl" | grep -i "last-modified" | awk '{$1=""; print $0}' | awk '{ sub(/^[ \t]+/, ""); print }' | tr -d '\r')

    if [[ "$1" == "update" ]]; then
        log_info "Writing last modifieddate [$lastmodified] to [$metafile]"
        atomic_write "$metafile" "$lastmodified"
    fi
}

function updateCheck() {
    log_info "Checking if we need to install or update [$appname]"
    updateSplashScreen wait "Checking for updates..."

    if [ -d "/Applications/$app" ]; then
        if [[ "$autoUpdate" == "true" ]]; then
            log_info "[$appname] is already installed and handles updates itself, exiting"
            updateSplashScreen success Installed
            exit 0
        fi

        log_info "[$appname] already installed, let's see if we need to update"
        fetchLastModifiedDate

        if [[ -d "$logandmetadir" ]]; then
            if [ -f "$metafile" ]; then
                previouslastmodifieddate=$(cat "$metafile")
                if [[ "$previouslastmodifieddate" != "$lastmodified" ]]; then
                    log_info "Update found, previous [$previouslastmodifieddate] and current [$lastmodified]"
                    update="update"
                else
                    log_info "No update between previous [$previouslastmodifieddate] and current [$lastmodified]"
                    updateSplashScreen success Installed
                    log_info "Exiting, nothing to do"
                    exit 0
                fi
            else
                log_warn "Meta file [$metafile] not found"
                log_warn "Unable to determine if update required, updating [$appname] anyway"
            fi
        fi
    else
        log_info "[$appname] not installed, need to download and install"
    fi
}

###############################################################
## Download
###############################################################

function downloadApp() {
    # Check for resume — skip download if already completed
    local current_step=$(get_step)
    if [[ "$current_step" == "downloaded" && -n "$(ls -A "$tempdir" 2>/dev/null)" ]]; then
        log_info "Resuming from downloaded state, skipping download"
        cd "$tempdir"
        for f in *; do
            tempfile=$f
        done
        # Re-detect package type on resume
        _detectPackageType
        return 0
    fi

    log_info "Starting downloading of [$appname]"

    # Get download size for display
    local DOWNLOAD_SIZE_HUMAN=$(get_download_size "$weburl")

    if [[ -n "$DOWNLOAD_SIZE_HUMAN" ]]; then
        updateSplashScreen progress "Downloading ($DOWNLOAD_SIZE_HUMAN)"
    else
        updateSplashScreen progress "Downloading"
    fi
    log_info "Downloading $appname [$weburl]"

    # Wait for network before starting
    wait_for_network || {
        updateSplashScreen fail "No network"
        exit 1
    }

    cd "$tempdir"
    start_download_timer

    local max_attempts=3
    local attempt=1
    local success=false

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Download attempt $attempt of $max_attempts..."
        if [[ -n "$DOWNLOAD_SIZE_HUMAN" ]]; then
            updateSplashScreen progress "Downloading ($DOWNLOAD_SIZE_HUMAN) — attempt $attempt"
        fi

        curl -f -s --connect-timeout 10 --retry 15 --retry-delay 5 --retry-all-errors -L -O "$weburl"
        if [[ $? -eq 0 ]]; then
            success=true
            break
        else
            log_warn "Download attempt $attempt failed"
            # Delete partial file to prevent corruption on retry
            rm -f "$tempdir"/* 2>/dev/null
            attempt=$((attempt + 1))
            if [[ $attempt -le $max_attempts ]]; then
                local delay=$(retry_delay $attempt)
                log_info "Retrying in ${delay}s..."
                sleep $delay
                wait_for_network
            fi
        fi
    done

    if [[ "$success" == true ]]; then
        local dl_elapsed=$(( SECONDS - DOWNLOAD_TIMER_START ))
        log_info "Download completed in ${dl_elapsed}s"
        updateSplashScreen progress "Downloaded (${dl_elapsed}s)"

        cd "$tempdir"
        for f in *; do
            tempfile=$f
            log_info "Found downloaded tempfile [$tempfile]"
        done

        # Validate the download
        validate_download "$tempdir/$tempfile" || {
            log_error "Download validation failed for [$tempfile]"
            updateSplashScreen fail "Download corrupt"
            rm -rf "$tempdir"
            exit 1
        }

        # Mark download step complete for resume
        mark_step "downloaded"

        _detectPackageType
    else
        log_error "Failure to download [$weburl] after $max_attempts attempts"
        updateSplashScreen fail Failed
        exit 1
    fi
}

# Internal helper to detect package type from downloaded file
_detectPackageType() {
    case $tempfile in
        *.pkg|*.PKG|*.mpkg|*.MPKG)
            packageType="PKG"
            ;;
        *.zip|*.ZIP)
            packageType="ZIP"
            ;;
        *.tbz2|*.TBZ2|*.bz2|*.BZ2)
            packageType="BZ2"
            ;;
        *.dmg|*.DMG)
            packageType="DMG"
            ;;
        *)
            log_info "Unknown file type [$tempfile], analysing metadata"
            local metadata
            metadata=$(file -z "$tempfile")
            log_info "[DEBUG] File metadata [$metadata]"

            if [[ "$metadata" == *"Zip archive data"* ]]; then
                packageType="ZIP"
                mv "$tempfile" "$tempdir/install.zip"
                tempfile="$tempdir/install.zip"
            fi
            if [[ "$metadata" == *"xar archive"* ]]; then
                packageType="PKG"
                mv "$tempfile" "$tempdir/install.pkg"
                tempfile="$tempdir/install.pkg"
            fi
            if [[ "$metadata" == *"DOS/MBR boot sector, extended partition table"* ]] || [[ "$metadata" == *"Apple Driver Map"* ]]; then
                packageType="DMG"
                mv "$tempfile" "$tempdir/install.dmg"
                tempfile="$tempdir/install.dmg"
            fi
            if [[ "$metadata" == *"POSIX tar archive (bzip2 compressed data"* ]]; then
                packageType="BZ2"
                mv "$tempfile" "$tempdir/install.tar.bz2"
                tempfile="$tempdir/install.tar.bz2"
            fi
            ;;
    esac

    # If DMG, probe contents to distinguish DMG (app inside) vs DMGPKG (pkg inside)
    if [[ "$packageType" == "DMG" ]]; then
        log_info "Found DMG, looking inside..."
        volume="$tempdir/$appname"
        log_info "Mounting Image [$volume] [$tempfile]"
        hdiutil attach -quiet -nobrowse -mountpoint "$volume" "$tempfile"
        if [[ "$?" = "0" ]]; then
            log_info "Mounted successfully to [$volume]"
        else
            log_error "Failed to mount [$tempfile]"
        fi

        if [[ $(ls "$volume" | grep -i .app) ]] && [[ $(ls "$volume" | grep -i .pkg) ]]; then
            log_warn "Detected both APP and PKG in same DMG, exiting gracefully"
        else
            if [[ $(ls "$volume" | grep -i .app) ]]; then
                log_info "Detected APP, setting PackageType to DMG"
                packageType="DMG"
            fi
            if [[ $(ls "$volume" | grep -i .pkg) ]]; then
                log_info "Detected PKG, setting PackageType to DMGPKG"
                packageType="DMGPKG"
            fi
            if [[ $(ls "$volume" | grep -i .mpkg) ]]; then
                log_info "Detected MPKG, setting PackageType to DMGPKG"
                packageType="DMGPKG"
            fi
        fi

        log_info "Un-mounting [$volume]"
        hdiutil detach -quiet "$volume"
    fi

    if [[ -z "$packageType" ]]; then
        log_error "Failed to determine temp file type"
        rm -rf "$tempdir"
    else
        log_info "Downloaded [$app] to [$tempfile]"
        log_info "Detected install type as [$packageType]"
    fi
}

###############################################################
## Installation Functions
###############################################################

function installPKG() {
    waitForProcess "$processpath" "300" "$terminateprocess"

    log_info "Installing $appname"
    updateSplashScreen progress "Installing..."

    if [[ -d "/Applications/$app" ]]; then
        rm -rf "/Applications/$app"
    fi

    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempting installation (attempt $attempt of $max_attempts)..."
        updateSplashScreen progress "Installing (attempt $attempt of $max_attempts)"
        installer -pkg "$tempfile" -target /

        if [ "$?" = "0" ]; then
            log_info "$appname Installed"
            log_info "Cleaning Up"
            rm -rf "$tempdir"
            # Clean up step file on success
            rm -f "${STATE_DIR}/${APP_ID}.step" 2>/dev/null

            log_info "Application [$appname] successfully installed"
            fetchLastModifiedDate update
            updateSplashScreen success Installed
            return 0
        else
            log_warn "Failed to install $appname, attempt $attempt of $max_attempts"
            updateSplashScreen error "Failed, retrying $attempt of $max_attempts"
            attempt=$((attempt + 1))
            if [[ $attempt -le $max_attempts ]]; then
                local delay=$(retry_delay $attempt)
                log_info "Retrying install in ${delay}s..."
                sleep $delay
            fi
        fi
    done

    log_error "Installation failed after $max_attempts attempts. Exiting."
    updateSplashScreen fail "Failed, after $max_attempts retries"
    rm -rf "$tempdir"
    exit 1
}

function installDMG() {
    waitForProcess "$processpath" "300" "$terminateprocess"

    log_info "Installing [$appname]"
    updateSplashScreen progress "Installing..."

    volume="$tempdir/$appname"
    log_info "Mounting Image [$volume] [$tempfile]"
    hdiutil attach -quiet -nobrowse -mountpoint "$volume" "$tempfile"

    if [[ -d "/Applications/$app" ]]; then
        log_info "Removing existing files"
        rm -rf "/Applications/$app"
    fi

    log_info "Copying app files to /Applications/$app"
    rsync -a "$volume"/*.app/ "/Applications/$app"

    log_info "Fix up permissions"
    dot_clean "/Applications/$app"

    log_info "Un-mounting [$volume]"
    hdiutil detach -quiet "$volume"

    if [[ -a "/Applications/$app" ]]; then
        log_info "[$appname] Installed"
        log_info "Cleaning Up"
        rm -rf "$tempfile"
        rm -f "${STATE_DIR}/${APP_ID}.step" 2>/dev/null

        log_info "Fixing up permissions"
        sudo chown -R root:wheel "/Applications/$app"
        log_info "Application [$appname] successfully installed"
        fetchLastModifiedDate update
        updateSplashScreen success Installed
    else
        log_error "Failed to install [$appname]"
        rm -rf "$tempdir"
        updateSplashScreen fail Failed
        exit 1
    fi
}

function installDMGPKG() {
    waitForProcess "$processpath" "300" "$terminateprocess"

    log_info "Installing [$appname]"
    updateSplashScreen progress "Installing..."

    volume="$tempdir/$appname"
    log_info "Mounting Image"
    hdiutil attach -quiet -nobrowse -mountpoint "$volume" "$tempfile"

    if [[ -d "/Applications/$app" ]]; then
        log_info "Removing existing files"
        rm -rf "/Applications/$app"
    fi

    for file in "$volume"/*.pkg; do
        log_info "Starting installer for [$file]"
        installer -pkg "$file" -target /Applications
    done

    for file in "$volume"/*.mpkg; do
        log_info "Starting installer for [$file]"
        installer -pkg "$file" -target /Applications
    done

    log_info "Un-mounting [$volume]"
    hdiutil detach -quiet "$volume"

    if [[ -a "/Applications/$app" ]]; then
        log_info "[$appname] Installed"
        log_info "Cleaning Up"
        rm -rf "$tempfile"
        rm -f "${STATE_DIR}/${APP_ID}.step" 2>/dev/null

        log_info "Fixing up permissions"
        sudo chown -R root:wheel "/Applications/$app"
        log_info "Application [$appname] successfully installed"
        fetchLastModifiedDate update
        updateSplashScreen success Installed
    else
        log_error "Failed to install [$appname]"
        rm -rf "$tempdir"
        updateSplashScreen fail Failed
        exit 1
    fi
}

function installZIP() {
    waitForProcess "$processpath" "300" "$terminateprocess"

    log_info "Installing $appname"
    updateSplashScreen progress "Installing..."

    cd "$tempdir"
    if [[ "$?" != "0" ]]; then
        log_error "Failed to change to $tempdir"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi

    unzip -qq -o "$tempfile"
    if [[ "$?" != "0" ]]; then
        log_error "Failed to unzip $tempfile"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi

    if [[ -a "/Applications/$app" ]]; then
        log_info "Removing old installation at /Applications/$app"
        rm -rf "/Applications/$app"
    fi

    rsync -a "$app/" "/Applications/$app"
    if [[ "$?" != "0" ]]; then
        log_error "Failed to move $appname to /Applications"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi

    log_info "Fix up permissions"
    dot_clean "/Applications/$app"
    sudo chown -R root:wheel "/Applications/$app"

    if [[ -a "/Applications/$app" ]]; then
        log_info "$appname Installed"
        updateSplashScreen success Installed
        log_info "Cleaning Up"
        rm -rf "$tempfile"
        rm -f "${STATE_DIR}/${APP_ID}.step" 2>/dev/null
        fetchLastModifiedDate update
        log_info "Application [$appname] successfully installed"
    else
        log_error "Failed to install $appname"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi
}

function installBZ2() {
    waitForProcess "$processpath" "300" "$terminateprocess"

    log_info "Installing $appname"
    updateSplashScreen progress "Installing..."

    cd "$tempdir"
    if [[ "$?" != "0" ]]; then
        log_error "Failed to change to $tempdir"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi

    tar -jxf "$tempfile"
    if [[ "$?" != "0" ]]; then
        log_error "Failed to uncompress $tempfile"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi

    if [[ -a "/Applications/$app" ]]; then
        log_info "Removing old installation at /Applications/$app"
        rm -rf "/Applications/$app"
    fi

    rsync -a "$app/" "/Applications/$app"
    if [[ "$?" != "0" ]]; then
        log_error "Failed to move $appname to /Applications"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi

    log_info "Fix up permissions"
    sudo chown -R root:wheel "/Applications/$app"

    if [[ -a "/Applications/$app" ]]; then
        log_info "$appname Installed"
        updateSplashScreen success Installed
        log_info "Cleaning Up"
        rm -rf "$tempfile"
        rm -f "${STATE_DIR}/${APP_ID}.step" 2>/dev/null
        fetchLastModifiedDate update
        log_info "Application [$appname] successfully installed"
    else
        log_error "Failed to install $appname"
        rm -rf "$tempdir" 2>/dev/null
        updateSplashScreen fail Failed
        exit 1
    fi
}

# Dispatch installation by detected package type
installByType() {
    case "$packageType" in
        PKG)    installPKG ;;
        DMG)    installDMG ;;
        DMGPKG) installDMGPKG ;;
        ZIP)    installZIP ;;
        BZ2)    installBZ2 ;;
        *)
            log_error "Unknown package type [$packageType], cannot install"
            updateSplashScreen fail "Unknown type"
            exit 1
            ;;
    esac
}

###############################################################
## UI -- Swift Dialog
###############################################################

function updateSplashScreen() {
    if [[ -a "$DIALOG_BIN" ]]; then
        local sd_status="$1"
        local sd_text="$2"
        log_info "UI update: [$appname] → status=$sd_status, text=$sd_text"
        echo "listitem: title: $appname, status: $sd_status, statustext: $sd_text" >> "$DIALOG_LOG"
    fi
}

# Update the overall progress bar (called by coordinator)
# Usage: updateOverallProgress 3 9
updateOverallProgress() {
    local completed=$1
    local total=$2
    if [[ -a "$DIALOG_BIN" ]]; then
        local pct=$(( (completed * 100) / total ))
        echo "progress: $pct" >> "$DIALOG_LOG"
        echo "progresstext: $completed of $total applications installed" >> "$DIALOG_LOG"
    fi
}

###############################################################
## State Tracking
###############################################################

# Report app completion to state directory (for reboot resilience)
# Usage: reportResult "Edge" 0   (0=success, non-zero=fail)
reportResult() {
    local id="$1"
    local exit_code="$2"
    if [[ "$exit_code" -eq 0 ]]; then
        atomic_write "$STATE_DIR/${id}.done" "success"
        log_info "Reported SUCCESS for [$id]"
    else
        atomic_write "$STATE_DIR/${id}.done" "fail:$exit_code"
        log_warn "Reported FAILURE (exit $exit_code) for [$id]"
    fi
}

# Check if an app was already completed (for resume after reboot)
# Usage: if isAppCompleted "Edge"; then echo "skip"; fi
isAppCompleted() {
    local id="$1"
    if [[ -f "$STATE_DIR/${id}.done" ]]; then
        local result
        result=$(cat "$STATE_DIR/${id}.done")
        if [[ "$result" == "success" ]]; then
            return 0
        fi
    fi
    return 1
}

###############################################################
## Complete Standard Install Flow
###############################################################

# runStandardInstall -- the complete download-detect-install flow in one call
# Requires: appname, app, weburl, logandmetadir, processpath, terminateprocess, autoUpdate
# to be set (either manually or via load_app_config)
runStandardInstall() {
    start_app_timer
    startLog

    log_info "============================================================"
    log_info "Starting install of [$appname] to [$log]"
    log_info "============================================================"

    checkForRosetta2
    updateCheck
    waitForDesktop
    downloadApp
    installByType
    log_app_time
}

# COMMON_LIB_DIR is derived from SCRIPT_DIR which callers must set before sourcing.
# All installer scripts do: SCRIPT_DIR="${0:A:h}" then source "${SCRIPT_DIR}/lib/common.zsh"
if [[ -n "$SCRIPT_DIR" ]]; then
    COMMON_LIB_DIR="${SCRIPT_DIR}/lib"
else
    # Fallback: try to determine from $0
    COMMON_LIB_DIR="${0:A:h}"
fi
