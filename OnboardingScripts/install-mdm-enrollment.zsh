#!/bin/zsh
############################################################################################
##
## MDM enrollment app installer -- special handler for enrollment client + auto-updater
##
## VER 2.0.0
## Your Organization IT
############################################################################################

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/lib/common.zsh"
source "${SCRIPT_DIR}/config/urls.conf"

# Load config for the MDM enrollment app (APP_ID defined in apps.conf with handler=mdm-enrollment)
load_app_config "AppOne" || exit 1

# Start logging
start_app_timer
startLog

log_info "============================================================"
log_info "Starting install of [$appname] to [$log]"
log_info "============================================================"

# Enable PSSO debug logging
log_info "Enabling debug logs for PSSO"
sudo log config --mode "level:debug,persist:debug" --subsystem com.apple.AppSSO

# Install Rosetta if needed
checkForRosetta2

# Check if update is needed
updateCheck

# Wait for desktop
waitForDesktop

# Download and install auto-updater first
log_info "Starting downloading of [Auto-Updater]"
updater_tempdir=$(mktemp -d)

wait_for_network || log_warn "Network check failed before auto-updater download"

curl -o "$updater_tempdir/autoupdater.pkg" -f -s --connect-timeout 10 --retry 15 --retry-delay 5 -C - -L -J -O "$URL_MDM_ENROLLMENT_AUTOUPDATER"
if [[ $? -eq 0 ]]; then
    if validate_download "$updater_tempdir/autoupdater.pkg" "pkg"; then
        log_info "Downloaded auto-updater to [$updater_tempdir/autoupdater.pkg]"
        log_info "Starting installation of auto-updater"
        installer -pkg "$updater_tempdir/autoupdater.pkg" -target /
        if [[ "$?" = "0" ]]; then
            log_info "Auto-updater installed"
        else
            log_error "Failed to install auto-updater"
        fi
    else
        log_warn "Auto-updater download failed validation, skipping"
    fi
    rm -rf "$updater_tempdir"
else
    log_error "Failure to download auto-updater"
    rm -rf "$updater_tempdir"
fi

# Download MDM enrollment app
downloadApp

# Install by detected type
installByType
log_app_time
