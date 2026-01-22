#!/bin/zsh
#
# Example App Install Script Template
# 
# Copy this template for each application you want to install during onboarding.
# Name your scripts with numeric prefixes for execution order:
#   01-installCompanyPortal.zsh
#   02-installMicrosoftOffice.zsh
#   03-installZoom.zsh
#
# Place finished scripts in: onboarding_scripts/scripts/
#

#####################################
## CONFIGURATION - CUSTOMIZE THESE
#####################################

# Display name (shown in Swift Dialog)
APP_NAME="Example App"

# Download URL (with SAS token if using Azure Blob Storage)
APP_URL="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/ExampleApp.pkg?YOUR_SAS_TOKEN"

# Expected application path after installation (for verification)
APP_PATH="/Applications/Example App.app"

# Package type: "pkg" or "dmg"
PACKAGE_TYPE="pkg"

# For DMG installs: the name of the .app inside the DMG
DMG_APP_NAME="Example App.app"

#####################################
## Logging setup
#####################################

LOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
LOG_FILE="${LOG_DIR}/${APP_NAME// /_}.log"
mkdir -p "$LOG_DIR"
exec &> >(tee -a "$LOG_FILE")

echo ""
echo "##############################################################"
echo "# Installing: $APP_NAME - $(date)"
echo "##############################################################"
echo ""

#####################################
## Swift Dialog status function
#####################################

updateDialog() {
    local status="$1"
    local statustext="$2"
    echo "listitem: title: ${APP_NAME}, status: ${status}, statustext: ${statustext}" >> /var/tmp/dialog.log
}

#####################################
## Download function with retry
#####################################

downloadFile() {
    local url="$1"
    local output="$2"
    local maxAttempts=5
    local attempt=0
    
    while [[ $attempt -lt $maxAttempts ]]; do
        attempt=$((attempt + 1))
        echo "$(date) | Download attempt $attempt of $maxAttempts..."
        
        httpCode=$(/usr/bin/curl -fL \
            --connect-timeout 10 \
            --max-time 300 \
            --retry 3 \
            --retry-delay 5 \
            --retry-all-errors \
            -C - \
            -o "$output" \
            "$url" \
            -w "%{http_code}")
        
        if [[ "$httpCode" == "200" ]] && [[ -s "$output" ]]; then
            echo "$(date) | Download successful."
            return 0
        fi
        
        echo "$(date) | Download failed (HTTP $httpCode). Retrying..."
        sleep 5
    done
    
    echo "$(date) | FATAL: Download failed after $maxAttempts attempts."
    return 1
}

#####################################
## Main installation logic
#####################################

# Update dialog: installing
updateDialog "wait" "Installing..."

# Create temp directory
tempdir=$(mktemp -d)
echo "$(date) | Temp directory: $tempdir"

# Download the package
echo "$(date) | Downloading $APP_NAME..."
if [[ "$PACKAGE_TYPE" == "pkg" ]]; then
    tempfile="${tempdir}/${APP_NAME}.pkg"
else
    tempfile="${tempdir}/${APP_NAME}.dmg"
fi

if ! downloadFile "$APP_URL" "$tempfile"; then
    updateDialog "fail" "Download failed"
    rm -rf "$tempdir"
    exit 1
fi

# Install based on package type
if [[ "$PACKAGE_TYPE" == "pkg" ]]; then
    # PKG installation
    echo "$(date) | Installing PKG..."
    installer -pkg "$tempfile" -target /
    installResult=$?
else
    # DMG installation
    echo "$(date) | Mounting DMG..."
    mountpoint=$(hdiutil attach "$tempfile" -nobrowse -readonly | grep "/Volumes" | awk '{print $3}')
    
    if [[ -z "$mountpoint" ]]; then
        echo "$(date) | ERROR: Failed to mount DMG"
        updateDialog "fail" "Mount failed"
        rm -rf "$tempdir"
        exit 1
    fi
    
    echo "$(date) | Copying app to /Applications..."
    cp -R "${mountpoint}/${DMG_APP_NAME}" /Applications/
    installResult=$?
    
    echo "$(date) | Unmounting DMG..."
    hdiutil detach "$mountpoint" -quiet
fi

# Verify installation
if [[ $installResult -eq 0 ]] && [[ -e "$APP_PATH" ]]; then
    echo "$(date) | $APP_NAME installed successfully."
    updateDialog "success" "Installed"
else
    echo "$(date) | ERROR: $APP_NAME installation failed."
    updateDialog "fail" "Failed"
    rm -rf "$tempdir"
    exit 1
fi

# Cleanup
rm -rf "$tempdir"

echo "$(date) | Installation complete."
exit 0
