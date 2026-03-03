#!/bin/zsh
############################################################################################
##
## Dialog installer -- downloads, installs, and launches the SwiftDialog UI
##
## VER 2.0.0
## Your Organization IT
############################################################################################

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/lib/common.zsh"
source "${SCRIPT_DIR}/config/urls.conf"

# Variables
appname="Swift Dialog"
logandmetadir="/Library/Application Support/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"
dialogWidth="1024"
dialogHeight="780"

# Start logging
if [[ ! -d "$logandmetadir" ]]; then
    log_info "Creating [$logandmetadir] to store logs"
    mkdir -p "$logandmetadir"
fi
exec > >(tee -a "$log") 2>&1

# Install Rosetta if needed
checkForRosetta2

# Download Swift Dialog
log_info "Downloading $appname [$URL_SWIFT_DIALOG]"
sd_tempdir=$(mktemp -d)

wait_for_network || log_warn "Network check failed before Swift Dialog download"

curl -f -s --connect-timeout 30 --retry 5 --retry-delay 60 --compressed -L -J -o "$sd_tempdir/swiftdialog.pkg" "$URL_SWIFT_DIALOG"

if ! validate_download "$sd_tempdir/swiftdialog.pkg" "pkg"; then
    log_error "Swift Dialog download failed validation"
fi

# Install Swift Dialog
log_info "Installing Swift Dialog"
installer -pkg "$sd_tempdir/swiftdialog.pkg" -target /
rm -rf "$sd_tempdir"

# Wait for Dock (desktop ready)
waitForDesktop

# Launch Swift Dialog with the onboarding JSON
max_attempts=5
for ((attempt=1; attempt<=max_attempts; attempt++)); do
    touch /var/tmp/dialog.log
    chmod a+w /var/tmp/dialog.log

    /usr/local/bin/dialog --jsonfile "$logandmetadir/swiftdialog.json" --width $dialogWidth --height $dialogHeight

    if [[ $? -eq 0 || $? -eq 5 ]]; then
        log_info "Successfully launched $appname."
        touch "$logandmetadir/onboarding.flag"
        sudo sh -c "date +%s > '/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog/onboarding.flag'"
        break
    else
        log_warn "Attempt $attempt to launch $appname failed. Retrying..."
        sleep 5
    fi
done
