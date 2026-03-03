# macOS Intune Onboarding Solution

Automated onboarding for macOS devices enrolled via Microsoft Intune. Uses a LaunchDaemon for persistence and [SwiftDialog](https://github.com/swiftDialog/swiftDialog) for a user-friendly progress UI during initial device setup.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Intune](https://img.shields.io/badge/Microsoft_Intune-managed-green) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Key Features

- **Config-driven** — add new apps by editing `apps.conf` and `urls.conf`, no code changes needed
- **Single bootstrap script** — deployed via Intune, handles all setup automatically
- **Two-phase execution** — parallel phase for independent apps, sequential phase for dependencies
- **State-based resume** — per-app state files survive reboots for reliable resume
- **Shared library** — `lib/common.zsh` provides logging, downloads, and SwiftDialog control
- **Sleep prevention** — `caffeinate` prevents system/display sleep during onboarding (including Apple Silicon)
- **In-progress flag** — resumes after overnight reboot even if the enrollment window has passed

## Architecture

```
Intune deploys onboarding-bootstrap.zsh
        │
        ▼
Bootstrap creates LaunchDaemon + downloads OnboardingScripts.zip
        │
        ▼
LaunchDaemon runs onboarding.zsh (coordinator)
        │
        ├── install-mdm-enrollment.zsh  (MDM enrollment client + auto-updater)
        ├── install-chunked.zsh         (chunked parallel download for large apps)
        ├── install-licensed.zsh        (license/key assignment after install)
        ├── install-standard.zsh        (generic: any standard download + install app)
        └── install-dialog.zsh          (UI framework)
```

## File Structure

```
├── onboarding-bootstrap.zsh          # Intune-deployed bootstrap script
├── OnboardingScripts/
│   ├── config/
│   │   ├── apps.conf                 # App manifest (one line per app)
│   │   └── urls.conf                 # Azure Blob URLs + SAS token
│   ├── lib/
│   │   └── common.zsh                # Shared functions library
│   ├── install-standard.zsh          # Generic installer (download + detect type + install)
│   ├── install-mdm-enrollment.zsh    # MDM enrollment client + auto-updater
│   ├── install-licensed.zsh          # Licensed app + key assignment
│   ├── install-chunked.zsh           # Large app (chunked parallel download)
│   ├── install-dialog.zsh            # SwiftDialog installer
│   ├── swiftdialog.json              # SwiftDialog UI layout
│   └── icons/                        # App icons for the progress UI
```

## Getting Started

### Prerequisites

- macOS 13+ (Ventura or later)
- Microsoft Intune enrollment
- Azure Blob Storage account for hosting packages
- SwiftDialog 3.0+

### Setup

1. **Upload packages** to your Azure Blob Storage container
2. **Edit `OnboardingScripts/config/urls.conf`** — set your storage account URL and SAS token
3. **Edit `OnboardingScripts/config/apps.conf`** — customize the app list for your environment
4. **Edit `OnboardingScripts/swiftdialog.json`** — update the title, icon, and app list
5. **Zip the `OnboardingScripts/` folder** and upload to your blob storage
6. **Update `onboarding-bootstrap.zsh`** line 227 with your `OnboardingScripts.zip` URL
7. **Deploy `onboarding-bootstrap.zsh`** as a macOS Shell Script in Intune

### Adding a New App

Just add one line to `apps.conf`:

```
AppID|Display Name|Bundle.app|URL_KEY|/path/to/process|terminate|autoupdate|phase|handler|icon.png
```

And add the corresponding URL to `urls.conf`. No code changes required.

### Available Handlers

| Handler | Script | Use Case |
|---|---|---|
| `standard` | `install-standard.zsh` | Most apps — download, detect type (pkg/dmg/zip), install |
| `chunked` | `install-chunked.zsh` | Large apps split into chunks for parallel download |
| `licensed` | `install-licensed.zsh` | Apps requiring license/key assignment after install |
| `mdm-enrollment` | `install-mdm-enrollment.zsh` | MDM enrollment client with auto-updater pre-install |

## Customization

| What to change | Where |
|---|---|
| App list | `OnboardingScripts/config/apps.conf` |
| Package URLs & SAS token | `OnboardingScripts/config/urls.conf` |
| License key | `OnboardingScripts/config/urls.conf` |
| UI title, icon, layout | `OnboardingScripts/swiftdialog.json` |
| Bootstrap download URL | `onboarding-bootstrap.zsh` line 227 |
| LaunchDaemon identifier | Search for `com.yourcompany.intune.onboarding` |

## License

MIT
