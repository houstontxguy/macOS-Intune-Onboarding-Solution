#!/bin/zsh
#
# Example: Install Package After Dependencies
#
# This script demonstrates how to wait for other applications to be installed
# before proceeding with installation. Useful for:
#   - Installing Microsoft AutoUpdate after Microsoft Office
#   - Installing plugins after their parent application
#   - Installing configuration tools after the app they configure
#
# Place in: onboarding_scripts/scripts/
# Name with a higher number to run later: 10-installAfterDependencies.zsh
#

#####################################
## CONFIGURATION
#####################################

APP_NAME="Microsoft AutoUpdate"
APP_URL="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/MicrosoftAutoUpdate.pkg?YOUR_SAS_TOKEN"
APP_PATH="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"

# Dependencies - wait for these apps to be installed first
# Add the full path to each application that must be installed before this one
DEPENDENCIES=(
    "/Applications/Microsoft Word.app"
    "/Applications/Microsoft Excel.app"
    "/Applications/Microsoft PowerPoint.app"
    "/Applications/Microsoft Outlook.app"
)

# How long to wait for dependencies (in seconds)
# Set to 0 to skip dependency check
DEPENDENCY_TIMEOUT=600  # 10 minutes

# How often to check for dependencies (in seconds)
DEPENDENCY_CHECK_INTERVAL=10

#####################################
## Logging setup
#####################################

LOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
LOG_FILE="${LOG_DIR}/${APP_NAME// /_}.log"
mkdir -p "$LOG_DIR"
exec &> >(tee -a "$LOG_FILE")

echo ""
echo "##############################################################"
echo "# Installing: $APP_NAME (with dependencies) - $(date)"
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
## Wait for dependencies
#####################################

waitForDependencies() {
    if [[ ${#DEPENDENCIES[@]} -eq 0 ]] || [[ $DEPENDENCY_TIMEOUT -eq 0 ]]; then
        echo "$(date) | No dependencies configured or timeout is 0, skipping dependency check."
        return 0
    fi
    
    echo "$(date) | Waiting for ${#DEPENDENCIES[@]} dependencies to be installed..."
    updateDialog "wait" "Waiting for dependencies..."
    
    local startTime=$(date +%s)
    local allInstalled=false
    
    while [[ "$allInstalled" != "true" ]]; do
        # Check timeout
        local currentTime=$(date +%s)
        local elapsed=$((currentTime - startTime))
        
        if [[ $elapsed -ge $DEPENDENCY_TIMEOUT ]]; then
            echo "$(date) | WARNING: Dependency timeout reached after ${elapsed}s. Proceeding anyway..."
            return 0
        fi
        
        # Check each dependency
        allInstalled=true
        local missingCount=0
        
        for dep in "${DEPENDENCIES[@]}"; do
            if [[ ! -e "$dep" ]]; then
                allInstalled=false
                missingCount=$((missingCount + 1))
                echo "$(date) | Waiting for: $dep"
            fi
        done
        
        if [[ "$allInstalled" == "true" ]]; then
            echo "$(date) | All dependencies installed!"
            return 0
        fi
        
        # Update dialog with waiting status
        local remaining=$((DEPENDENCY_TIMEOUT - elapsed))
        updateDialog "wait" "Waiting for $missingCount app(s)..."
        
        echo "$(date) | $missingCount dependencies remaining. Checking again in ${DEPENDENCY_CHECK_INTERVAL}s (timeout in ${remaining}s)..."
        sleep $DEPENDENCY_CHECK_INTERVAL
    done
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
## Alternative: Wait for specific process
#####################################

# Uncomment this function if you need to wait for another install SCRIPT
# to complete (rather than waiting for an app to appear)

# waitForProcess() {
#     local processName="$1"
#     local timeout="${2:-300}"  # Default 5 minutes
#     
#     echo "$(date) | Waiting for process '$processName' to complete..."
#     
#     local startTime=$(date +%s)
#     
#     while pgrep -f "$processName" > /dev/null; do
#         local currentTime=$(date +%s)
#         local elapsed=$((currentTime - startTime))
#         
#         if [[ $elapsed -ge $timeout ]]; then
#             echo "$(date) | WARNING: Process wait timeout reached."
#             return 1
#         fi
#         
#         echo "$(date) | Process '$processName' still running. Waiting..."
#         sleep 5
#     done
#     
#     echo "$(date) | Process '$processName' completed."
#     return 0
# }

#####################################
## Main installation logic
#####################################

# Step 1: Wait for dependencies
waitForDependencies
depResult=$?

if [[ $depResult -ne 0 ]]; then
    echo "$(date) | WARNING: Dependency check had issues, but continuing..."
fi

# Step 2: Update dialog and start installation
updateDialog "wait" "Downloading..."

# Step 3: Create temp directory
tempdir=$(mktemp -d)
tempfile="${tempdir}/${APP_NAME// /_}.pkg"

echo "$(date) | Temp directory: $tempdir"

# Step 4: Download the package
echo "$(date) | Downloading $APP_NAME..."
if ! downloadFile "$APP_URL" "$tempfile"; then
    updateDialog "fail" "Download failed"
    rm -rf "$tempdir"
    exit 1
fi

# Step 5: Install
updateDialog "wait" "Installing..."
echo "$(date) | Installing $APP_NAME..."

installer -pkg "$tempfile" -target /
installResult=$?

# Step 6: Verify installation
if [[ $installResult -eq 0 ]] && [[ -e "$APP_PATH" ]]; then
    echo "$(date) | $APP_NAME installed successfully."
    updateDialog "success" "Installed"
else
    echo "$(date) | ERROR: $APP_NAME installation failed."
    updateDialog "fail" "Failed"
    rm -rf "$tempdir"
    exit 1
fi

# Step 7: Cleanup
rm -rf "$tempdir"

echo "$(date) | Installation complete."
exit 0
