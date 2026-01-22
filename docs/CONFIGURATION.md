# Configuration Guide

This document provides detailed configuration instructions for the Mac Intune Onboarding solution.

## Table of Contents

- [Bootstrap Script Configuration](#bootstrap-script-configuration)
- [Azure Blob Storage Setup](#azure-blob-storage-setup)
- [Scripts Package Structure](#scripts-package-structure)
- [Swift Dialog Configuration](#swift-dialog-configuration)
- [Application Install Scripts](#application-install-scripts)
- [Intune Deployment Configuration](#intune-deployment-configuration)
- [Device Filtering](#device-filtering)

---

## Bootstrap Script Configuration

The `intune-onboarding-bootstrap.zsh` script contains all primary configuration options.

### Required Settings

| Variable | Description | Example |
|----------|-------------|---------|
| `ORG_IDENTIFIER` | Reverse domain identifier for your organization | `com.contoso` |
| `ONBOARDING_SCRIPTS_URL` | Full URL to onboarding_scripts.zip with SAS token | See below |

### Optional Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVICE_PREFIX_PROVISIONING` | `MAC_PS` | Device name prefix during setup |
| `DEVICE_PREFIX_COMPLETED` | `MAC` | Device name prefix after completion |
| `ENROLLMENT_WINDOW_HOURS` | `1` | Hours after enrollment to run onboarding |
| `CHECK_ENROLLMENT_TIME` | `true` | Whether to check enrollment time |

### URL Format

```bash
ONBOARDING_SCRIPTS_URL="https://STORAGE_ACCOUNT.blob.core.windows.net/CONTAINER/onboarding_scripts.zip?SAS_TOKEN"

# Example:
ONBOARDING_SCRIPTS_URL="https://contosoapps.blob.core.windows.net/intune/onboarding_scripts.zip?sv=2025-07-05&st=2026-01-01&se=2027-01-01&sr=c&sp=r&sig=XXXXX"
```

---

## Azure Blob Storage Setup

### Create Storage Account

```bash
# Create resource group
az group create --name rg-intune-apps --location eastus

# Create storage account
az storage account create \
    --name contosoappstorage \
    --resource-group rg-intune-apps \
    --location eastus \
    --sku Standard_LRS

# Create container
az storage container create \
    --account-name contosoappstorage \
    --name intune
```

### Generate SAS Token

#### Via Azure CLI

```bash
# Get account key
ACCOUNT_KEY=$(az storage account keys list \
    --account-name contosoappstorage \
    --query '[0].value' -o tsv)

# Generate SAS token (valid for 1 year)
az storage container generate-sas \
    --account-name contosoappstorage \
    --account-key $ACCOUNT_KEY \
    --name intune \
    --permissions r \
    --expiry $(date -v+1y +%Y-%m-%d) \
    --https-only
```

#### Via Azure Portal

1. Navigate to your Storage Account
2. Go to **Containers** → Select your container
3. Click **Shared access tokens**
4. Configure:
   - **Signing method:** Account key
   - **Signing key:** key1
   - **Permissions:** Read only
   - **Start:** Today
   - **Expiry:** 1 year from now
5. Click **Generate SAS token and URL**
6. Copy the **Blob SAS URL**

### Upload Files

```bash
# Upload single file
az storage blob upload \
    --account-name contosoappstorage \
    --container-name intune \
    --file onboarding_scripts.zip \
    --name onboarding_scripts.zip

# Upload multiple files
az storage blob upload-batch \
    --account-name contosoappstorage \
    --destination intune \
    --source ./packages/ \
    --pattern "*.pkg"
```

---

## Scripts Package Structure

The `onboarding_scripts.zip` must contain:

```
onboarding_scripts/
├── 1-installSwiftDialog.zsh    # Swift Dialog installer (REQUIRED)
├── swiftdialog.json            # Swift Dialog configuration (REQUIRED)
├── icons/                       # Application icons (REQUIRED)
│   ├── company-logo.png        # Main logo shown in dialog
│   ├── companyportal.png       # Icon for each app
│   ├── office.png
│   └── ...
└── scripts/                     # Application installers (REQUIRED)
    ├── 01-installCompanyPortal.zsh
    ├── 02-installMicrosoftOffice.zsh
    └── ...
```

### Icon Requirements

- **Format:** PNG recommended
- **Size:** 128x128 pixels recommended
- **Naming:** Match the icon filename in swiftdialog.json

### Script Naming Convention

Scripts execute in alphabetical order. Use numeric prefixes:

```
01-installCompanyPortal.zsh    # Runs first
02-installMicrosoftOffice.zsh  # Runs second
03-installZoom.zsh             # Runs third
```

---

## Swift Dialog Configuration

### swiftdialog.json

```json
{
    "title": "Setting Up Your Mac",
    "message": "Please wait while we configure your Mac...",
    "icon": "/Library/Application Support/Microsoft/IntuneScripts/Swift Dialog/icons/company-logo.png",
    "iconsize": "128",
    "button1disabled": true,
    "button1text": "Please Wait...",
    "blurscreen": false,
    "ontop": false,
    "position": "center",
    "moveable": true,
    "width": "700",
    "height": "500",
    "listitem": [
        {
            "title": "Company Portal",
            "icon": "/path/to/icon.png",
            "status": "pending",
            "statustext": "Waiting..."
        }
    ]
}
```

### Key Options

| Option | Description |
|--------|-------------|
| `title` | Window title |
| `message` | Instructions shown to user |
| `icon` | Path to company logo |
| `blurscreen` | Blur background (can be distracting) |
| `ontop` | Keep window on top (can block other apps) |
| `moveable` | Allow user to move window |
| `button1disabled` | Disable button until complete |

### List Item Status Values

| Status | Description | Visual |
|--------|-------------|--------|
| `pending` | Not started | Gray clock |
| `wait` | In progress | Spinning wheel |
| `success` | Completed | Green checkmark |
| `fail` | Failed | Red X |
| `error` | Error occurred | Red exclamation |

---

## Application Install Scripts

### Basic Template

```bash
#!/bin/zsh

APP_NAME="My App"
APP_URL="https://storage.blob.core.windows.net/container/MyApp.pkg?sas"
APP_PATH="/Applications/My App.app"

# Update Swift Dialog
updateDialog() {
    echo "listitem: title: ${APP_NAME}, status: ${1}, statustext: ${2}" >> /var/tmp/dialog.log
}

updateDialog "wait" "Installing..."

# Download
tempfile=$(mktemp)
curl -fL -o "$tempfile" "$APP_URL"

# Install
installer -pkg "$tempfile" -target /

# Verify
if [[ -e "$APP_PATH" ]]; then
    updateDialog "success" "Installed"
else
    updateDialog "fail" "Failed"
fi

rm -f "$tempfile"
```

### DMG Installation

```bash
# Mount DMG
mountpoint=$(hdiutil attach "$dmgfile" -nobrowse -readonly | grep "/Volumes" | awk '{print $3}')

# Copy app
cp -R "${mountpoint}/App Name.app" /Applications/

# Unmount
hdiutil detach "$mountpoint" -quiet
```

### Chunked Download (Large Files)

See `scripts/examples/02-installMicrosoftOffice-chunked.zsh` for a complete example of parallel chunk downloading.

---

## Intune Deployment Configuration

### Script Settings

| Setting | Value |
|---------|-------|
| Run script as signed-in user | No |
| Hide script notifications | Yes |
| Script frequency | Not configured |
| Max number of retries | 3 |

### Assignment

1. Create a device group for new Mac enrollments
2. Assign the script to this group
3. Consider using filters for specific hardware or OS versions

---

## Device Filtering

### How Device Naming Works

1. **During provisioning:** Device named `{PREFIX_PS}-{SERIAL}`
   - Example: `CONTOSO_PS-C02X1234ABCD`

2. **After completion:** Device renamed `{PREFIX}-{SERIAL}`
   - Example: `CONTOSO-C02X1234ABCD`

### Intune Filter Configuration

Create a filter to target only completed devices:

**Filter expression:**
```
(device.deviceName -startsWith "CONTOSO-")
```

This filter:
- **Matches:** `CONTOSO-C02X1234ABCD` (completed)
- **Does not match:** `CONTOSO_PS-C02X1234ABCD` (still provisioning)

### Use Cases

1. **Configuration profiles** — Apply to completed devices only
2. **App deployments** — Deploy additional apps after onboarding
3. **Compliance policies** — Only evaluate completed devices
4. **Updates** — Only push updates to completed devices

---

## Security Considerations

### SAS Token Best Practices

1. **Use read-only permissions** — Scripts only need download access
2. **Set appropriate expiration** — 6-12 months recommended
3. **Rotate tokens regularly** — Update before expiration
4. **Use HTTPS only** — Always require HTTPS in SAS tokens

### Script Security

1. Scripts run as **root** via LaunchDaemon
2. Quarantine attributes are removed from downloaded scripts
3. Consider code signing for additional security
4. Audit scripts before deployment

### Network Considerations

1. Ensure Azure Blob Storage is accessible from your network
2. Consider CDN for improved download performance
3. Test with various network conditions
