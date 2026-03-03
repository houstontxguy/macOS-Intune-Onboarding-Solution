#!/bin/zsh
############################################################################################
##
## Licensed app installer -- special handler for apps requiring license/key assignment
##
## VER 2.0.0
## Your Organization IT
############################################################################################

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/lib/common.zsh"
source "${SCRIPT_DIR}/config/urls.conf"

# Load config for the licensed app (APP_ID defined in apps.conf with handler=licensed)
load_app_config "AppFour" || exit 1

# Start logging
start_app_timer
startLog

log_info "============================================================"
log_info "Starting install of [$appname] to [$log]"
log_info "============================================================"

# Install Rosetta if needed
checkForRosetta2

# Check if update is needed
updateCheck

# Wait for desktop
waitForDesktop

# Download app
downloadApp

# Override installPKG to add license assignment after install
waitForProcess "$processpath" "300" "$terminateprocess"

log_info "Installing $appname"
updateSplashScreen progress "Installing..."

if [[ -d "/Applications/$app" ]]; then
    rm -rf "/Applications/$app"
fi

max_attempts=5
attempt=1

while [ $attempt -le $max_attempts ]; do
    log_info "Attempting installation (attempt $attempt of $max_attempts)..."
    updateSplashScreen progress "Installing (attempt $attempt of $max_attempts)"
    installer -pkg "$tempfile" -target /

    if [ "$?" = "0" ]; then
        log_info "$appname Installed"

        # License/key assignment for the installed app
        LICENSE_LOG="/var/log/licensed_app.log"
        LICENSE_TOOL="/Applications/LicensedApp.app/Contents/Resources/licensectl"

        log_info "Starting license assignment..."
        updateSplashScreen progress "Licensing..."

        # Wait for app to be available
        for i in {1..10}; do
            if [ -x "$LICENSE_TOOL" ]; then
                log_info "Licensed app found. Proceeding with license assignment..."
                break
            else
                log_warn "Licensed app not found. Retrying in 10 seconds... (attempt $i of 10)"
                sleep 10
            fi
        done

        # Assign license key
        sudo "$LICENSE_TOOL" license "$LICENSE_KEY" >> "$LICENSE_LOG" 2>&1

        # Verify
        sudo "$LICENSE_TOOL" stats >> "$LICENSE_LOG" 2>&1

        log_info "License assignment completed."

        log_info "Cleaning Up"
        rm -rf "$tempdir"
        rm -f "${STATE_DIR}/${APP_ID}.step" 2>/dev/null

        log_info "Application [$appname] successfully installed"
        fetchLastModifiedDate update
        updateSplashScreen success Installed
        log_app_time
        break
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

if [ $attempt -gt $max_attempts ]; then
    log_error "Installation failed after $max_attempts attempts. Exiting."
    updateSplashScreen fail "Failed, after $max_attempts retries"
    rm -rf "$tempdir"
    exit 1
fi
