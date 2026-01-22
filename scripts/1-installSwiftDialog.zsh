#!/bin/zsh
#
# Swift Dialog Installer Script
# This script installs Swift Dialog and launches the onboarding UI
#
# This file should be included in onboarding_scripts.zip as:
# 1-installSwiftDialog.zsh
#
# Inspired by Microsoft's Swift Dialog sample:
# https://github.com/microsoft/shell-intune-samples/tree/master/macOS/Config/Swift%20Dialog
#

#####################################
## CONFIGURATION - CUSTOMIZE THESE
#####################################

# URL to Swift Dialog PKG (get from https://github.com/swiftDialog/swiftDialog/releases)
# You should host this in your own blob storage with a SAS token
SWIFT_DIALOG_URL="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/dialog-2.5.6-4805.pkg?YOUR_SAS_TOKEN"

# Swift Dialog assets location
SWIFT_DIALOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog"

# Log file
LOG_FILE="${SWIFT_DIALOG_DIR}/Swift Dialog.log"

#####################################
## Script starts here
#####################################

mkdir -p "$SWIFT_DIALOG_DIR"
exec &> >(tee -a "$LOG_FILE")

echo ""
echo "##############################################################"
echo "# Swift Dialog Installer - $(date)"
echo "##############################################################"
echo ""

#####################################
## Wait for desktop (Dock)
#####################################

echo "$(date) | Waiting for Dock to indicate desktop is ready..."
until ps aux | grep /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -v grep &>/dev/null; do
    echo "$(date) | Dock not running, waiting..."
    sleep 1
done
echo "$(date) | Dock is running. Desktop is ready."

#####################################
## Get logged-in user
#####################################

currentUser=$(stat -f "%Su" /dev/console)
echo "$(date) | Current user: $currentUser"

if [[ "$currentUser" == "root" ]] || [[ "$currentUser" == "_mbsetupuser" ]] || [[ -z "$currentUser" ]]; then
    echo "$(date) | Waiting for a valid user session..."
    until [[ "$currentUser" != "root" ]] && [[ "$currentUser" != "_mbsetupuser" ]] && [[ -n "$currentUser" ]]; do
        sleep 2
        currentUser=$(stat -f "%Su" /dev/console)
    done
    echo "$(date) | User logged in: $currentUser"
fi

#####################################
## Download Swift Dialog
#####################################

echo "$(date) | Downloading Swift Dialog..."
tempdir=$(mktemp -d)
pkgfile="${tempdir}/dialog.pkg"

downloadattempts=0
downloadSuccess=false

while [[ $downloadattempts -lt 5 ]] && [[ "$downloadSuccess" != "true" ]]; do
    downloadattempts=$((downloadattempts + 1))
    echo "$(date) | Download attempt $downloadattempts..."
    
    httpCode=$(/usr/bin/curl -fL \
        --connect-timeout 10 \
        --max-time 120 \
        --retry 3 \
        --retry-delay 5 \
        --retry-all-errors \
        -o "$pkgfile" \
        "$SWIFT_DIALOG_URL" \
        -w "%{http_code}")
    
    if [[ "$httpCode" == "200" ]] && [[ -f "$pkgfile" ]]; then
        downloadSuccess=true
        echo "$(date) | Download successful."
    else
        echo "$(date) | Download failed (HTTP $httpCode). Retrying..."
        sleep 2
    fi
done

if [[ "$downloadSuccess" != "true" ]]; then
    echo "$(date) | FATAL: Failed to download Swift Dialog after 5 attempts."
    exit 1
fi

#####################################
## Install Swift Dialog
#####################################

echo "$(date) | Installing Swift Dialog..."
installer -pkg "$pkgfile" -target /

if [[ $? -ne 0 ]]; then
    echo "$(date) | ERROR: Swift Dialog installation failed."
    exit 1
fi

echo "$(date) | Swift Dialog installed successfully."

#####################################
## Launch Swift Dialog
#####################################

echo "$(date) | Launching Swift Dialog with onboarding UI..."

jsonFile="${SWIFT_DIALOG_DIR}/swiftdialog.json"

if [[ ! -f "$jsonFile" ]]; then
    echo "$(date) | ERROR: JSON file not found at $jsonFile"
    exit 1
fi

# Launch dialog in background
/usr/local/bin/dialog --jsonfile "$jsonFile" --commandfile /var/tmp/dialog.log &

echo "$(date) | Swift Dialog launched."

# Cleanup temp files
rm -rf "$tempdir"

exit 0
