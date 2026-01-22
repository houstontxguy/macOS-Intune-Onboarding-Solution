# Mac Intune Onboarding

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://www.apple.com/macos/)
[![MDM](https://img.shields.io/badge/MDM-Microsoft%20Intune-blue.svg)](https://docs.microsoft.com/en-us/mem/intune/)

An automated onboarding solution for macOS devices enrolled via Microsoft Intune. This solution uses [Swift Dialog](https://github.com/swiftDialog/swiftDialog) to provide a user-friendly progress interface while installing required enterprise applications.

Built on top of [Microsoft's Swift Dialog sample](https://github.com/microsoft/shell-intune-samples/tree/master/macOS/Config/Swift%20Dialog) from their shell-intune-samples repository.

## Features

- 🚀 **Automated Deployment** — LaunchDaemon ensures onboarding runs at first boot
- 🎨 **User-Friendly UI** — Swift Dialog provides real-time progress feedback
- ⚡ **Parallel Downloads** — Multiple applications download simultaneously
- 🔄 **Chunked Downloads** — Large files (like Microsoft Office) split for reliability
- 😴 **Sleep Prevention** — Caffeinate prevents Mac from sleeping during setup
- 🏷️ **Device Naming** — Automatic naming for Intune targeting
- 🧹 **Self-Cleanup** — LaunchDaemon removes itself after completion
  
![Sample screenshot](https://raw.githubusercontent.com/houstontxguy/macOS-Intune-Onboarding-Solution/main/sample.jpeg)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        INTUNE DEPLOYMENT                            │
│              Deploys: intune-onboarding-bootstrap.zsh               │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    BOOTSTRAP SCRIPT (Runs Once)                     │
│  1. Creates onboarding.zsh script                                   │
│  2. Creates LaunchDaemon plist                                      │
│  3. Loads LaunchDaemon                                              │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  LAUNCHDAEMON (Runs at Login)                       │
│  Executes: onboarding.zsh                                           │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────────────────┐
        ▼                       ▼                                   ▼
┌───────────────┐     ┌─────────────────────┐           ┌───────────────────┐
│ Swift Dialog  │     │ Download Scripts Zip │           │ Install Rosetta   │
│ (Progress UI) │     │ from Azure Blob      │           │ (Apple Silicon)   │
└───────┬───────┘     └──────────┬──────────┘           └───────────────────┘
        │                        │
        │              ┌─────────┴─────────┐
        │              ▼                   ▼
        │     ┌────────────────┐  ┌────────────────┐
        │     │ App Install    │  │ App Install    │  ... (parallel)
        │     │ Script 01      │  │ Script 02      │
        │     └────────────────┘  └────────────────┘
        │              │                   │
        │              └─────────┬─────────┘
        │                        │
        └────────────────────────┴────────────────────────────────────┐
                                                                      ▼
                                                    ┌─────────────────────────┐
                                                    │ Completion              │
                                                    │ • Rename device         │
                                                    │ • Write flag file       │
                                                    │ • Cleanup LaunchDaemon  │
                                                    └─────────────────────────┘
```

## Quick Start

### Prerequisites

- Microsoft Intune environment with macOS management
- Azure Blob Storage account (or other file hosting with direct URLs)
- macOS 12+ target devices

### 1. Prepare Your Assets

1. Download [Swift Dialog](https://github.com/swiftDialog/swiftDialog/releases) PKG
2. Gather your application installers (PKG or DMG)
3. Create icons for each application (PNG, ~128x128)

### 2. Configure Azure Blob Storage

```bash
# Create a container
az storage container create \
    --account-name YOUR_ACCOUNT \
    --name onboarding

# Upload Swift Dialog
az storage blob upload \
    --account-name YOUR_ACCOUNT \
    --container-name onboarding \
    --file dialog-2.5.6-4805.pkg

# Upload your application packages
az storage blob upload \
    --account-name YOUR_ACCOUNT \
    --container-name onboarding \
    --file YourApp.pkg

# Generate a SAS token (read-only, expires in 1 year)
az storage container generate-sas \
    --account-name YOUR_ACCOUNT \
    --name onboarding \
    --permissions r \
    --expiry $(date -v +1y +%Y-%m-%d)
```

### 3. Create the Scripts Package

```bash
# Structure your onboarding_scripts folder:
onboarding_scripts/
├── 1-installSwiftDialog.zsh
├── swiftdialog.json
├── icons/
│   ├── company-logo.png
│   ├── companyportal.png
│   ├── office.png
│   └── ...
└── scripts/
    ├── 01-installCompanyPortal.zsh
    ├── 02-installMicrosoftOffice.zsh
    └── ...

# Zip it
zip -r onboarding_scripts.zip onboarding_scripts/

# Upload to Azure
az storage blob upload \
    --account-name YOUR_ACCOUNT \
    --container-name onboarding \
    --file onboarding_scripts.zip
```

### 4. Configure the Bootstrap Script

Edit `intune-onboarding-bootstrap.zsh`:

```bash
# Organization identifier
ORG_IDENTIFIER="com.yourcompany"

# Device naming prefixes
DEVICE_PREFIX_PROVISIONING="YOURCO_PS"
DEVICE_PREFIX_COMPLETED="YOURCO"

# Azure Blob Storage URL
ONBOARDING_SCRIPTS_URL="https://YOUR_ACCOUNT.blob.core.windows.net/onboarding/onboarding_scripts.zip?YOUR_SAS_TOKEN"
```

### 5. Deploy via Intune

1. Go to **Microsoft Intune admin center**
2. Navigate to **Devices** → **macOS** → **Shell scripts**
3. Create a new script
4. Upload `intune-onboarding-bootstrap.zsh`
5. Configure:
   - Run as: **System**
   - Max retries: **3**
   - Frequency: **Not configured** (runs once)
6. Assign to your device groups

## Configuration

### Device Naming for Intune Targeting

The solution uses device naming to enable Intune filters:

| Phase | Device Name | Example |
|-------|-------------|---------|
| Provisioning | `{PREFIX_PS}-{SERIAL}` | `YOURCO_PS-C02X1234ABCD` |
| Completed | `{PREFIX}-{SERIAL}` | `YOURCO-C02X1234ABCD` |

Create an Intune filter to target only completed devices:

```
(device.deviceName -startsWith "YOURCO-")
```

This prevents update policies from running on devices still being provisioned.

### Enrollment Window

The `ENROLLMENT_WINDOW_HOURS` setting prevents onboarding from running on devices enrolled more than X hours ago:

```bash
ENROLLMENT_WINDOW_HOURS=1  # Only run on devices enrolled in the last hour
```

Set to a higher value if your enrollment process spans multiple days.

### Sleep Prevention

The script automatically runs `caffeinate` to prevent the Mac from sleeping during onboarding:

```bash
caffeinate -d -i -s -u &  # Prevents display, idle, and system sleep
```

This is automatically killed before the completion dialog appears.

## Large File Downloads (Chunked)

For files larger than 500MB (like Microsoft Office), use chunked parallel downloads:

### Split the Installer

```bash
# Split into 200MB chunks
split -b 200m Microsoft_365_Installer.pkg Microsoft_365_Installer.pkg.part_

# Get the chunk suffixes
ls *.part_* | sed "s/.*part_//" | tr '\n' ' '
# Output: aa ab ac ad ae af ag ah ai aj ak al am an

# Get the original file size
stat -f%z Microsoft_365_Installer.pkg
# Output: 2737483648
```

### Upload Chunks

```bash
az storage blob upload-batch \
    --account-name YOUR_ACCOUNT \
    --destination onboarding \
    --source . \
    --pattern "*.part_*"
```

### Configure the Install Script

See `scripts/examples/02-installMicrosoftOffice-chunked.zsh` for a complete example.

## Swift Dialog Integration

Install scripts communicate with Swift Dialog by writing to `/var/tmp/dialog.log`:

```bash
# Update status
echo "listitem: title: My App, status: wait, statustext: Installing..." >> /var/tmp/dialog.log
echo "listitem: title: My App, status: success, statustext: Installed" >> /var/tmp/dialog.log

# Available statuses
# pending  - Initial state
# wait     - Currently installing
# success  - Completed successfully
# fail     - Installation failed
# error    - Error occurred
```

## File Locations

| File | Path | Purpose |
|------|------|---------|
| Log Directory | `/Library/Application Support/Microsoft/IntuneScripts/onBoarding/` | Logs and metadata |
| Main Log | `onBoarding/onboard.log` | Primary execution log |
| Completion Flag | `onBoarding/onboardingcompleted.flag` | Prevents re-execution |
| LaunchDaemon | `/Library/LaunchDaemons/com.yourorg.intune.onboarding.plist` | System daemon |
| Swift Dialog Assets | `/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog/` | UI assets |
| Dialog Command File | `/var/tmp/dialog.log` | Swift Dialog commands |

## Troubleshooting

### Check Logs

```bash
# Main onboarding log
cat "/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboard.log"

# Swift Dialog log
cat "/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog/Swift Dialog.log"

# Individual app logs
ls "/Library/Application Support/Microsoft/IntuneScripts/onBoarding/"*.log
```

### LaunchDaemon Status

```bash
# Check if loaded
launchctl list | grep onboarding

# View daemon status
launchctl print system/com.yourorg.intune.onboarding
```

### Manual Testing

```bash
# Run bootstrap manually
sudo /bin/zsh /path/to/intune-onboarding-bootstrap.zsh

# Force re-run by removing flag
sudo rm "/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboardingcompleted.flag"
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Script doesn't run | Completion flag exists | Remove the flag file |
| Downloads fail | SAS token expired | Generate new SAS token |
| Swift Dialog doesn't appear | Running before desktop | Script waits for Dock |
| Mac sleeps during install | Caffeinate not running | Check logs for errors |
| Device not renamed | Script failed early | Check logs for errors |

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

This project was inspired by and builds upon:

- [Microsoft Shell Intune Samples](https://github.com/microsoft/shell-intune-samples/tree/master/macOS/Config/Swift%20Dialog) — Microsoft's Swift Dialog onboarding example provided the foundation for this solution
- [Swift Dialog](https://github.com/swiftDialog/swiftDialog) by Bart Reardon — the excellent macOS dialog tool that powers the UI

## Disclaimer

This project is not affiliated with or endorsed by Microsoft or Apple. Use at your own risk. Always test thoroughly in a non-production environment before deploying to production devices.
