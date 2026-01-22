#!/bin/zsh
#
# Mac Intune Onboarding Bootstrap Script
# https://github.com/houstontxguy/macOS-Intune-Onboarding-Solution
#
# This script is deployed via Microsoft Intune and sets up a LaunchDaemon
# to orchestrate the onboarding process for newly enrolled Macs.
#
# Inspired by Microsoft's Swift Dialog sample:
# https://github.com/microsoft/shell-intune-samples/tree/master/macOS/Config/Swift%20Dialog
#
# Version: 1.0.0
# License: MIT
#

#####################################
## CONFIGURATION - CUSTOMIZE THESE
#####################################

# Organization identifier (used in LaunchDaemon naming)
# Example: "com.yourcompany" or "org.example"
ORG_IDENTIFIER="com.example"

# Device naming prefix during provisioning
# Devices are named "${DEVICE_PREFIX_PROVISIONING}-${SERIAL}" during onboarding
# and "${DEVICE_PREFIX_COMPLETED}-${SERIAL}" after completion
# This enables Intune device filters to target only completed devices
DEVICE_PREFIX_PROVISIONING="MAC_PS"
DEVICE_PREFIX_COMPLETED="MAC"

# Azure Blob Storage URL for onboarding scripts package
# The URL should point to a .zip file containing:
#   - 1-installSwiftDialog.zsh
#   - swiftdialog.json
#   - icons/ directory
#   - scripts/ directory with numbered install scripts
ONBOARDING_SCRIPTS_URL="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/onboarding_scripts.zip?YOUR_SAS_TOKEN"

# How many hours after enrollment should onboarding still run?
# Devices enrolled longer than this will skip onboarding
ENROLLMENT_WINDOW_HOURS=1

# Enable enrollment time check (set to false for testing)
CHECK_ENROLLMENT_TIME=true

# Log file location
LOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
LOG_FILE="${LOG_DIR}/onboard.log"

# Swift Dialog location
SWIFT_DIALOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog"

#####################################
## DO NOT MODIFY BELOW THIS LINE
#####################################

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Redirect all output to log file
exec &> >(tee -a "$LOG_FILE")

echo ""
echo "##############################################################"
echo "# Mac Intune Onboarding Bootstrap"
echo "# $(date)"
echo "##############################################################"
echo ""

# Define paths
LAUNCH_DAEMON_LABEL="${ORG_IDENTIFIER}.intune.onboarding"
LAUNCH_DAEMON_PLIST="/Library/LaunchDaemons/${LAUNCH_DAEMON_LABEL}.plist"
SCRIPT_DIR="/Library/Application Support/Microsoft/IntuneScripts"
ONBOARDING_SCRIPT="${SCRIPT_DIR}/onboarding.zsh"

#####################################
## Check for existing LaunchDaemon
#####################################

if [[ -f "$LAUNCH_DAEMON_PLIST" ]]; then
    echo "$(date) | LaunchDaemon already exists at $LAUNCH_DAEMON_PLIST"
    
    # Check if it's loaded
    if launchctl list | grep -q "$LAUNCH_DAEMON_LABEL"; then
        echo "$(date) | LaunchDaemon is currently loaded. Unloading..."
        launchctl bootout system "$LAUNCH_DAEMON_PLIST" 2>/dev/null || true
        sleep 2
    fi
    
    # Remove old files
    echo "$(date) | Removing existing files..."
    rm -f "$LAUNCH_DAEMON_PLIST"
    rm -f "$ONBOARDING_SCRIPT"
fi

#####################################
## Create script directory
#####################################

echo "$(date) | Creating script directory..."
mkdir -p "$SCRIPT_DIR"

#####################################
## Write onboarding script to disk
#####################################

echo "$(date) | Writing onboarding script to $ONBOARDING_SCRIPT"

cat > "$ONBOARDING_SCRIPT" << 'ONBOARDING_SCRIPT_EOF'
#!/bin/zsh
#
# Mac Intune Onboarding Script
# This script runs via LaunchDaemon after enrollment
#

#####################################
## CONFIGURATION (injected by bootstrap)
#####################################
ORG_IDENTIFIER="__ORG_IDENTIFIER__"
DEVICE_PREFIX_PROVISIONING="__DEVICE_PREFIX_PROVISIONING__"
DEVICE_PREFIX_COMPLETED="__DEVICE_PREFIX_COMPLETED__"
ONBOARDING_SCRIPTS_URL="__ONBOARDING_SCRIPTS_URL__"
ENROLLMENT_WINDOW_HOURS=__ENROLLMENT_WINDOW_HOURS__
CHECK_ENROLLMENT_TIME=__CHECK_ENROLLMENT_TIME__
LOG_DIR="__LOG_DIR__"
LOG_FILE="__LOG_FILE__"
SWIFT_DIALOG_DIR="__SWIFT_DIALOG_DIR__"

#####################################
## Derived paths
#####################################
FLAG="${LOG_DIR}/onboardingcompleted.flag"
LAUNCH_DAEMON_LABEL="${ORG_IDENTIFIER}.intune.onboarding"
LAUNCH_DAEMON_PLIST="/Library/LaunchDaemons/${LAUNCH_DAEMON_LABEL}.plist"
SCRIPT_DIR="/Library/Application Support/Microsoft/IntuneScripts"
ONBOARDING_SCRIPT="${SCRIPT_DIR}/onboarding.zsh"

#####################################
## Logging setup
#####################################
mkdir -p "$LOG_DIR"
exec &> >(tee -a "$LOG_FILE")

echo ""
echo "##############################################################"
echo "# Mac Intune Onboarding Script - $(date)"
echo "##############################################################"
echo ""

#####################################
## Check completion flag
#####################################

if [[ -f "$FLAG" ]]; then
    echo "$(date) | Onboarding already completed. Flag exists at: $FLAG"
    echo "$(date) | Cleaning up LaunchDaemon and script..."
    
    # Cleanup
    rm -f "$LAUNCH_DAEMON_PLIST"
    rm -f "$ONBOARDING_SCRIPT"
    
    # Unload daemon
    launchctl bootout system "$LAUNCH_DAEMON_PLIST" 2>/dev/null || true
    
    echo "$(date) | Cleanup complete. Exiting."
    exit 0
fi

#####################################
## Check enrollment window
#####################################

if [[ "$CHECK_ENROLLMENT_TIME" == "true" ]]; then
    echo "$(date) | Checking enrollment time..."
    
    # Get MDM profile installation date
    profile_output=$(profiles -P -v 2>/dev/null | grep -A 10 "Management Profile")
    install_date=$(echo "$profile_output" | grep -oE 'installationDate:.*' | head -1 | cut -d' ' -f2-)
    
    if [[ -n "$install_date" ]]; then
        install_date_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$install_date" "+%s" 2>/dev/null)
        current_time_seconds=$(date "+%s")
        
        if [[ -n "$install_date_seconds" ]]; then
            time_difference_hours=$(( (current_time_seconds - install_date_seconds) / 3600 ))
            echo "$(date) | MDM Profile installed: $install_date"
            echo "$(date) | Time since enrollment: $time_difference_hours hours"
            
            if [[ "$time_difference_hours" -gt "$ENROLLMENT_WINDOW_HOURS" ]]; then
                echo "$(date) | Device enrolled more than $ENROLLMENT_WINDOW_HOURS hour(s) ago. Skipping onboarding."
                mkdir -p "$(dirname "$FLAG")"
                date +%s > "$FLAG"
                exit 0
            fi
        fi
    else
        echo "$(date) | Could not determine enrollment date. Continuing with onboarding."
    fi
fi

#####################################
## Set device name (provisioning)
#####################################

echo "$(date) | Setting device name to indicate provisioning in progress..."
SERIAL=$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F\" '/IOPlatformSerialNumber/{print $(NF-1)}')
DEVICE_NAME="${DEVICE_PREFIX_PROVISIONING}-${SERIAL}"

sudo scutil --set ComputerName "$DEVICE_NAME"
sudo scutil --set HostName "$DEVICE_NAME"
# LocalHostName cannot contain underscores, replace with hyphens
LOCAL_HOST_NAME=$(echo "$DEVICE_NAME" | tr '_' '-')
sudo scutil --set LocalHostName "$LOCAL_HOST_NAME"

echo "$(date) | Device name set to: $DEVICE_NAME"

#####################################
## Install Rosetta 2 if needed
#####################################

echo "$(date) | Checking architecture..."
ARCH=$(uname -m)

if [[ "$ARCH" == "arm64" ]]; then
    echo "$(date) | Apple Silicon detected. Checking for Rosetta 2..."
    
    if ! /usr/bin/pgrep oahd &>/dev/null; then
        echo "$(date) | Installing Rosetta 2..."
        attempt_counter=0
        max_attempts=10
        
        until /usr/bin/pgrep oahd || [[ $attempt_counter -eq $max_attempts ]]; do
            attempt_counter=$((attempt_counter + 1))
            echo "$(date) | Rosetta install attempt $attempt_counter of $max_attempts..."
            /usr/sbin/softwareupdate --install-rosetta --agree-to-license
            sleep 1
        done
        
        if [[ $attempt_counter -eq $max_attempts ]]; then
            echo "$(date) | WARNING: Rosetta 2 installation may have failed. Continuing..."
        else
            echo "$(date) | Rosetta 2 installed successfully."
        fi
    else
        echo "$(date) | Rosetta 2 already installed."
    fi
else
    echo "$(date) | Intel Mac detected. Rosetta 2 not needed."
fi

#####################################
## Download onboarding scripts
#####################################

echo "$(date) | Downloading onboarding scripts package..."
tempdir=$(mktemp -d)
downloadattempts=0
unzipExitCode=1

while [[ $unzipExitCode -ne 0 ]]; do
    downloadattempts=$((downloadattempts + 1))
    echo "$(date) | Download attempt $downloadattempts..."
    
    DownloadResult=$(/usr/bin/curl -fL \
        --connect-timeout 10 \
        --max-time 300 \
        --retry 3 \
        --retry-delay 5 \
        --retry-all-errors \
        -C - \
        -o "${tempdir}/onboarding_scripts.zip" \
        "$ONBOARDING_SCRIPTS_URL" \
        -w "%{http_code}")
    
    if [[ $DownloadResult -eq 200 ]]; then
        echo "$(date) | Download successful. Extracting..."
        unzip -o "${tempdir}/onboarding_scripts.zip" -d "$tempdir"
        unzipExitCode=$?
    else
        echo "$(date) | Download failed with HTTP $DownloadResult. Retrying in 2 seconds..."
        sleep 2
    fi
    
    if [[ $downloadattempts -gt 5 ]]; then
        echo "$(date) | FATAL: Failed to download onboarding scripts after 5 attempts."
        exit 1
    fi
done

#####################################
## Move Swift Dialog assets
#####################################

echo "$(date) | Setting up Swift Dialog assets..."
mkdir -p "$SWIFT_DIALOG_DIR"
mv "$tempdir/onboarding_scripts/icons" "$SWIFT_DIALOG_DIR/icons" 2>/dev/null || true
mv "$tempdir/onboarding_scripts/swiftdialog.json" "$SWIFT_DIALOG_DIR/swiftdialog.json" 2>/dev/null || true

#####################################
## Launch Swift Dialog installer
#####################################

echo "$(date) | Starting Swift Dialog installation..."
xattr -d com.apple.quarantine "$tempdir/onboarding_scripts/1-installSwiftDialog.zsh" 2>/dev/null
chmod +x "$tempdir/onboarding_scripts/1-installSwiftDialog.zsh"
nice -n -5 "$tempdir/onboarding_scripts/1-installSwiftDialog.zsh" &

#####################################
## Wait for Swift Dialog
#####################################

echo -n "$(date) | Waiting for Swift Dialog to start..."
START=$(date +%s)
until ps aux | grep /usr/local/bin/dialog | grep -v grep &>/dev/null; do
    if [[ $(($(date +%s) - $START)) -ge 300 ]]; then
        echo ""
        echo "$(date) | WARNING: Swift Dialog did not start within 5 minutes. Continuing anyway..."
        break
    fi
    echo -n "."
    sleep 5
done
echo " OK"

#####################################
## Start caffeinate (prevent sleep)
#####################################

echo "$(date) | Starting caffeinate to prevent sleep during onboarding..."
caffeinate -d -i -s -u &
CAFFEINATE_PID=$!

# Allow Swift Dialog to fully initialize
sleep 10

#####################################
## Execute install scripts
#####################################

echo "$(date) | Processing install scripts..."
for script in "$tempdir"/onboarding_scripts/scripts/*.*; do
    if [[ -f "$script" ]]; then
        echo "$(date) | Executing: $(basename "$script")"
        xattr -d com.apple.quarantine "$script" 2>/dev/null
        chmod +x "$script"
        nice -n 10 "$script" &
    fi
done

#####################################
## Stop caffeinate before wait
#####################################

echo "$(date) | Stopping caffeinate before waiting for scripts..."
kill "$CAFFEINATE_PID" 2>/dev/null

# Wait for all install scripts to complete
wait

echo "$(date) | All install scripts finished."

#####################################
## Set device name (completed)
#####################################

echo "$(date) | Renaming device to indicate onboarding complete..."
DEVICE_NAME_COMPLETED="${DEVICE_PREFIX_COMPLETED}-${SERIAL}"

sudo scutil --set ComputerName "$DEVICE_NAME_COMPLETED"
sudo scutil --set HostName "$DEVICE_NAME_COMPLETED"
sudo scutil --set LocalHostName "$DEVICE_NAME_COMPLETED"

echo "$(date) | Device name set to: $DEVICE_NAME_COMPLETED"

#####################################
## Write completion flag
#####################################

echo "$(date) | Writing completion flag..."
mkdir -p "$(dirname "$FLAG")"
date +%s > "$FLAG"

#####################################
## Dismiss Swift Dialog
#####################################

echo "$(date) | Dismissing Swift Dialog..."
echo "quit:" >> /var/tmp/dialog.log

#####################################
## Show completion dialog
#####################################

echo "$(date) | Showing completion dialog..."
osascript -e 'display dialog "Onboarding process has completed successfully!\n\nYour Mac is now configured and ready to use." buttons {"OK"} default button "OK" with title "Setup Complete" with icon note'

#####################################
## Cleanup
#####################################

echo "$(date) | Performing cleanup..."

# Remove LaunchDaemon
rm -f "$LAUNCH_DAEMON_PLIST"

# Remove this script
rm -f "$ONBOARDING_SCRIPT"

# Unload LaunchDaemon
launchctl bootout system "$LAUNCH_DAEMON_PLIST" 2>/dev/null || true

# Cleanup temp directory
rm -rf "$tempdir"

echo "$(date) | Onboarding complete!"
echo ""

exit 0
ONBOARDING_SCRIPT_EOF

#####################################
## Inject configuration values
#####################################

echo "$(date) | Injecting configuration values..."
sed -i '' "s|__ORG_IDENTIFIER__|${ORG_IDENTIFIER}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__DEVICE_PREFIX_PROVISIONING__|${DEVICE_PREFIX_PROVISIONING}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__DEVICE_PREFIX_COMPLETED__|${DEVICE_PREFIX_COMPLETED}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__ONBOARDING_SCRIPTS_URL__|${ONBOARDING_SCRIPTS_URL}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__ENROLLMENT_WINDOW_HOURS__|${ENROLLMENT_WINDOW_HOURS}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__CHECK_ENROLLMENT_TIME__|${CHECK_ENROLLMENT_TIME}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__LOG_DIR__|${LOG_DIR}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__LOG_FILE__|${LOG_FILE}|g" "$ONBOARDING_SCRIPT"
sed -i '' "s|__SWIFT_DIALOG_DIR__|${SWIFT_DIALOG_DIR}|g" "$ONBOARDING_SCRIPT"

chmod +x "$ONBOARDING_SCRIPT"

#####################################
## Create LaunchDaemon plist
#####################################

echo "$(date) | Creating LaunchDaemon plist..."

cat > "$LAUNCH_DAEMON_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>${ONBOARDING_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchdaemon.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchdaemon.error.log</string>
</dict>
</plist>
EOF

chmod 644 "$LAUNCH_DAEMON_PLIST"
chown root:wheel "$LAUNCH_DAEMON_PLIST"

#####################################
## Load LaunchDaemon
#####################################

echo "$(date) | Loading LaunchDaemon..."
launchctl bootstrap system "$LAUNCH_DAEMON_PLIST"

echo "$(date) | Bootstrap complete. LaunchDaemon will start onboarding process."
echo ""

exit 0
