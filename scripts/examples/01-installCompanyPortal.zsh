#!/bin/zsh
#
# Company Portal Install Script
#
# Example of a simple PKG installation.
# Place in: onboarding_scripts/scripts/01-installCompanyPortal.zsh
#

#####################################
## CONFIGURATION
#####################################

APP_NAME="Company Portal"
APP_URL="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/CompanyPortal.pkg?YOUR_SAS_TOKEN"
APP_PATH="/Applications/Company Portal.app"

#####################################
## Logging setup
#####################################

LOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
LOG_FILE="${LOG_DIR}/CompanyPortal.log"
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
## Main installation logic
#####################################

updateDialog "wait" "Installing..."

tempdir=$(mktemp -d)
tempfile="${tempdir}/CompanyPortal.pkg"

echo "$(date) | Downloading $APP_NAME..."
httpCode=$(/usr/bin/curl -fL \
    --connect-timeout 10 \
    --max-time 300 \
    --retry 3 \
    --retry-delay 5 \
    --retry-all-errors \
    -C - \
    -o "$tempfile" \
    "$APP_URL" \
    -w "%{http_code}")

if [[ "$httpCode" != "200" ]] || [[ ! -s "$tempfile" ]]; then
    echo "$(date) | ERROR: Download failed (HTTP $httpCode)"
    updateDialog "fail" "Download failed"
    rm -rf "$tempdir"
    exit 1
fi

echo "$(date) | Installing..."
installer -pkg "$tempfile" -target /

if [[ $? -eq 0 ]] && [[ -e "$APP_PATH" ]]; then
    echo "$(date) | $APP_NAME installed successfully."
    updateDialog "success" "Installed"
else
    echo "$(date) | ERROR: Installation failed."
    updateDialog "fail" "Failed"
    rm -rf "$tempdir"
    exit 1
fi

rm -rf "$tempdir"
exit 0
