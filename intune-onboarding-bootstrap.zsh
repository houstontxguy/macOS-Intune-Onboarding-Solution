#!/bin/zsh

##############################################
## Mac Intune Onboarding - Bootstrap Script
## Version: 1.4
## 
## v1.4 Changes:
## - Added in-progress flag to allow resume after overnight reboot
##   (enrollment window check is skipped if onboarding was already started)
##
## v1.3 Changes:
## - Device naming during provisioning and after completion
## - Intune filter support for targeting completed devices
## - Caffeinate for sleep prevention
## - Cleanup on completion flag detection
## - LaunchDaemon unload before bootstrap (for script updates)
##
## This script is deployed via Intune and creates:
## 1. The onboarding.zsh script
## 2. A LaunchDaemon to run it at boot
##
## Attribution: Based on concepts from Microsoft's shell-intune-samples
##############################################

# Exit on error
set -e

# ============================================
# CONFIGURATION - MODIFY THESE FOR YOUR ORG
# ============================================

# Your Azure Blob Storage URL with SAS token for the onboarding scripts package
onboardingScriptsUrl="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/onboarding_scripts.zip?YOUR_SAS_TOKEN"

# How long after enrollment should onboarding still run? (in hours)
# Devices enrolled longer than this will skip onboarding (unless already in progress)
enrollmentWindowHours=1

# Organization identifier for LaunchDaemon naming (use reverse domain notation)
# Example: com.contoso, com.mycompany, org.school
ORG_IDENTIFIER="com.yourorg"

# Device naming prefixes
# During provisioning (helps identify devices still being set up)
DEVICE_PREFIX_PROVISIONING="MAC-PROV"
# After completion (helps with Intune filters for targeting)
DEVICE_PREFIX_COMPLETED="MAC"

# ============================================
# END CONFIGURATION
# ============================================

# --- Paths ---
SUPPORT_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
SCRIPT_PATH="$SUPPORT_DIR/onboarding.zsh"
PLIST="/Library/LaunchDaemons/${ORG_IDENTIFIER}.intune.onboarding.plist"
LAUNCHDAEMON_LABEL="${ORG_IDENTIFIER}.intune.onboarding"

# --- Create directory structure ---
mkdir -p "$SUPPORT_DIR"

# --- Write the onboarding.zsh script (runs via LaunchDaemon) ---
cat > "$SCRIPT_PATH" << 'ONBOARDING_SCRIPT_EOF'
#!/bin/zsh

##############################################
## Onboarding Script (runs via LaunchDaemon)
## Version: 1.4
##############################################

# Configuration (injected by bootstrap script)
onboardingScriptsUrl="__ONBOARDING_SCRIPTS_URL__"
enrollmentWindowHours=__ENROLLMENT_WINDOW_HOURS__
ORG_IDENTIFIER="__ORG_IDENTIFIER__"
DEVICE_PREFIX_PROVISIONING="__DEVICE_PREFIX_PROVISIONING__"
DEVICE_PREFIX_COMPLETED="__DEVICE_PREFIX_COMPLETED__"

# Paths
SUPPORT_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
SWIFT_DIALOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog"
completionFlag="$SUPPORT_DIR/onboardingcompleted.flag"
inProgressFlag="$SUPPORT_DIR/onboarding_inprogress.flag"
PLIST="/Library/LaunchDaemons/${ORG_IDENTIFIER}.intune.onboarding.plist"
LAUNCHDAEMON_LABEL="${ORG_IDENTIFIER}.intune.onboarding"
tempdir=$(mktemp -d)

echo ""
echo "##############################################"
echo "## Mac Intune Onboarding v1.4"
echo "## $(date)"
echo "##############################################"
echo ""

# --- Check for completion flag ---
if [[ -f "$completionFlag" ]]; then
    echo "$(date) | Onboarding already completed. Cleaning up and exiting."
    
    # Cleanup LaunchDaemon and script
    echo "$(date) | Deleting LaunchDaemon plist..."
    rm -f "$PLIST"
    
    echo "$(date) | Deleting onboarding script..."
    rm -f "$SUPPORT_DIR/onboarding.zsh"
    
    echo "$(date) | Deleting in-progress flag..."
    rm -f "$inProgressFlag"
    
    echo "$(date) | Unloading LaunchDaemon..."
    launchctl bootout system/$LAUNCHDAEMON_LABEL 2>/dev/null
    
    exit 0
fi

# --- Check for in-progress flag ---
# If onboarding was already started, skip enrollment window check
if [[ -f "$inProgressFlag" ]]; then
    echo "$(date) | In-progress flag found. Resuming onboarding (skipping enrollment window check)..."
else
    # --- Check enrollment window (only for fresh starts) ---
    echo "$(date) | Checking how long ago this device was enrolled..."
    
    # Get the installation date of the MDM management profile
    profile_output=$(profiles -P -v 2>/dev/null | grep -A 10 "Management Profile")
    install_date=$(echo "$profile_output" | grep -oE 'installationDate:.*' | head -1 | cut -d' ' -f2-)
    
    if [[ -n "$install_date" ]]; then
        install_date_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$install_date" "+%s" 2>/dev/null)
        current_time_seconds=$(date "+%s")
        
        if [[ -n "$install_date_seconds" ]]; then
            time_difference_hours=$(( (current_time_seconds - install_date_seconds) / 3600 ))
            echo "$(date) |  + MDM Profile install time: $install_date"
            echo "$(date) |  + Time since enrollment: $time_difference_hours hours"
            
            if [[ "$time_difference_hours" -gt "$enrollmentWindowHours" ]]; then
                echo "$(date) |  + Device was enrolled more than $enrollmentWindowHours hour(s) ago."
                echo "$(date) |  + Skipping onboarding (no in-progress flag found)."
                exit 0
            fi
        else
            echo "$(date) |  + Could not parse enrollment date. Continuing..."
        fi
    else
        echo "$(date) |  + Could not determine enrollment date. Continuing..."
    fi
    
    # --- Create in-progress flag ---
    echo "$(date) | Creating in-progress flag (first run)..."
    date +%s > "$inProgressFlag"
fi

# --- Set device name (provisioning status) ---
serial=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $NF}')
echo "$(date) | Setting device name to ${DEVICE_PREFIX_PROVISIONING}-$serial (provisioning in progress)"
scutil --set ComputerName "${DEVICE_PREFIX_PROVISIONING}-$serial"
# LocalHostName cannot have underscores, so we replace them with hyphens
localHostName=$(echo "${DEVICE_PREFIX_PROVISIONING}-$serial" | tr '_' '-')
scutil --set LocalHostName "$localHostName"
scutil --set HostName "${DEVICE_PREFIX_PROVISIONING}-$serial"

# --- Install Rosetta 2 if needed ---
echo "$(date) | Checking if we need Rosetta 2..."
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    echo "$(date) | Apple Silicon processor detected"
    if ! /usr/bin/pgrep oahd >/dev/null 2>&1; then
        echo "$(date) | Rosetta not found, installing..."
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        
        # Verify installation
        attempt=0
        until /usr/bin/pgrep oahd >/dev/null 2>&1 || [[ $attempt -ge 10 ]]; do
            attempt=$((attempt + 1))
            echo "$(date) | Waiting for Rosetta (attempt $attempt/10)..."
            sleep 2
        done
    else
        echo "$(date) | Rosetta already installed"
    fi
else
    echo "$(date) | Intel processor, skipping Rosetta check"
fi

# --- Download onboarding scripts ---
downloadattempts=0
echo "$(date) | Downloading onboarding scripts from Azure Blob Storage..."

while [[ ! -d "$tempdir/onboarding_scripts" ]]; do
    downloadattempts=$((downloadattempts + 1))
    echo "$(date) |  + Download attempt $downloadattempts"
    
    curl -f -L \
        --connect-timeout 10 \
        --max-time 300 \
        --retry 3 \
        --retry-delay 5 \
        --retry-all-errors \
        -C - \
        -o "${tempdir}/onboarding_scripts.zip" \
        "${onboardingScriptsUrl}"
    
    if [[ $? -eq 0 ]]; then
        echo "$(date) |  + Downloaded, extracting..."
        unzip -o "$tempdir/onboarding_scripts.zip" -d "$tempdir"
    else
        echo "$(date) |  + Download failed, waiting 2 seconds..."
        sleep 2
    fi
    
    if [[ $downloadattempts -gt 5 ]]; then
        echo "$(date) | FATAL: Failed to download onboarding scripts after 5 attempts"
        exit 1
    fi
done

# --- Move Swift Dialog assets ---
echo "$(date) | Setting up Swift Dialog assets..."
mkdir -p "$SWIFT_DIALOG_DIR"
mv "$tempdir/onboarding_scripts/icons" "$SWIFT_DIALOG_DIR/icons" 2>/dev/null || true
mv "$tempdir/onboarding_scripts/swiftdialog.json" "$SWIFT_DIALOG_DIR/swiftdialog.json" 2>/dev/null || true

# --- Launch Swift Dialog installer ---
echo "$(date) | Starting Swift Dialog installation..."
xattr -d com.apple.quarantine "$tempdir/onboarding_scripts/1-installSwiftDialog.zsh" 2>/dev/null
chmod +x "$tempdir/onboarding_scripts/1-installSwiftDialog.zsh"
nice -n -5 "$tempdir/onboarding_scripts/1-installSwiftDialog.zsh" &

# --- Wait for Swift Dialog to start ---
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

# --- Start caffeinate (prevent sleep during onboarding) ---
echo "$(date) | Starting caffeinate to prevent sleep..."
caffeinate -d -i -s -u &
CAFFEINATE_PID=$!

# Allow Swift Dialog to fully initialize
sleep 10

# --- Execute install scripts ---
echo "$(date) | Processing install scripts..."
for script in "$tempdir"/onboarding_scripts/scripts/*.*; do
    if [[ -f "$script" ]]; then
        echo "$(date) | Executing: $(basename "$script")"
        xattr -d com.apple.quarantine "$script" 2>/dev/null
        chmod +x "$script"
        nice -n 10 "$script" &
    fi
done

# --- Stop caffeinate before waiting ---
echo "$(date) | Stopping caffeinate before waiting for scripts to complete..."
kill "$CAFFEINATE_PID" 2>/dev/null

# --- Wait for all install scripts to complete ---
wait
echo "$(date) | All install scripts finished."

# --- Set device name (completed) ---
echo "$(date) | Renaming device to ${DEVICE_PREFIX_COMPLETED}-$serial (onboarding complete)"
scutil --set ComputerName "${DEVICE_PREFIX_COMPLETED}-$serial"
scutil --set LocalHostName "${DEVICE_PREFIX_COMPLETED}-$serial"
scutil --set HostName "${DEVICE_PREFIX_COMPLETED}-$serial"

# --- Write completion flag ---
echo "$(date) | Writing completion flag..."
date +%s > "$completionFlag"

# --- Remove in-progress flag ---
echo "$(date) | Removing in-progress flag..."
rm -f "$inProgressFlag"

# --- Dismiss Swift Dialog ---
echo "$(date) | Dismissing Swift Dialog..."
echo "quit:" >> /var/tmp/dialog.log

# --- Show completion dialog ---
echo "$(date) | Showing completion dialog..."
osascript -e 'display dialog "Onboarding process has completed successfully!

Your Mac is now configured and ready to use." buttons {"OK"} default button "OK" with title "Setup Complete" with icon note'

# --- Cleanup ---
echo "$(date) | Performing cleanup..."

echo "$(date) | Deleting LaunchDaemon plist..."
rm -f "$PLIST"

echo "$(date) | Deleting onboarding script..."
rm -f "$SUPPORT_DIR/onboarding.zsh"

echo "$(date) | Unloading LaunchDaemon..."
launchctl bootout system/$LAUNCHDAEMON_LABEL 2>/dev/null

echo "$(date) | Cleaning up temp directory..."
rm -rf "$tempdir"

echo "$(date) | Onboarding complete!"
echo ""

exit 0
ONBOARDING_SCRIPT_EOF

# --- Inject configuration values into onboarding.zsh ---
sed -i '' "s|__ONBOARDING_SCRIPTS_URL__|${onboardingScriptsUrl}|g" "$SCRIPT_PATH"
sed -i '' "s|__ENROLLMENT_WINDOW_HOURS__|${enrollmentWindowHours}|g" "$SCRIPT_PATH"
sed -i '' "s|__ORG_IDENTIFIER__|${ORG_IDENTIFIER}|g" "$SCRIPT_PATH"
sed -i '' "s|__DEVICE_PREFIX_PROVISIONING__|${DEVICE_PREFIX_PROVISIONING}|g" "$SCRIPT_PATH"
sed -i '' "s|__DEVICE_PREFIX_COMPLETED__|${DEVICE_PREFIX_COMPLETED}|g" "$SCRIPT_PATH"

chmod 755 "$SCRIPT_PATH"

# --- Write the LaunchDaemon plist ---
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHDAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboarding.zsh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Relaunch only if it fails (non-zero exit) -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOF

chmod 644 "$PLIST"

# --- Load the LaunchDaemon ---
# First check if LaunchDaemon is already loaded and unload it (for script updates)
if launchctl print system/$LAUNCHDAEMON_LABEL &>/dev/null; then
    echo "LaunchDaemon already loaded, unloading first..."
    launchctl bootout system/$LAUNCHDAEMON_LABEL 2>/dev/null
    sleep 1
fi

launchctl bootstrap system "$PLIST"
launchctl enable system/$LAUNCHDAEMON_LABEL

echo "Bootstrap complete. LaunchDaemon will start onboarding process."
