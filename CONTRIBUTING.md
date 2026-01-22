# Contributing to Mac Intune Onboarding

Thank you for your interest in contributing! This document provides guidelines for contributing to this project.

## How to Contribute

### Reporting Issues

Before creating an issue, please:

1. Check existing issues to avoid duplicates
2. Use the appropriate issue template
3. Include relevant details:
   - macOS version
   - Intune configuration
   - Log excerpts
   - Steps to reproduce

### Submitting Pull Requests

1. **Fork the repository** and create a feature branch
2. **Make your changes** following the code style guidelines below
3. **Test thoroughly** on actual macOS devices with Intune
4. **Update documentation** if your changes affect usage
5. **Submit a pull request** with a clear description

### Code Style Guidelines

#### Shell Scripts

- Use `#!/bin/zsh` for all scripts (macOS default shell)
- Use descriptive variable names in `UPPER_CASE`
- Include comments explaining complex logic
- Use functions for repeated code
- Always quote variables: `"$variable"`
- Use `[[ ]]` for conditionals instead of `[ ]`

```bash
# Good
DOWNLOAD_URL="https://example.com/file.pkg"
if [[ -f "$DOWNLOAD_URL" ]]; then
    echo "File exists"
fi

# Bad
url=https://example.com/file.pkg
if [ -f $url ]; then
    echo File exists
fi
```

#### Logging

- Use consistent timestamp format: `$(date)`
- Prefix log messages with a pipe: `echo "$(date) | Message"`
- Log both successes and failures
- Include enough context for troubleshooting

```bash
echo "$(date) | Starting download of $APP_NAME..."
echo "$(date) | ERROR: Download failed with HTTP $httpCode"
echo "$(date) | $APP_NAME installed successfully."
```

#### Swift Dialog Integration

- Always update dialog status at key points
- Use consistent status values: `pending`, `wait`, `success`, `fail`, `error`
- Include meaningful status text

```bash
updateDialog "wait" "Downloading..."
updateDialog "wait" "Installing..."
updateDialog "success" "Installed"
```

### Testing

Before submitting a PR, please test:

1. **Clean enrollment** — Test on a freshly enrolled Mac
2. **Re-run scenarios** — Verify completion flag prevents re-run
3. **Error handling** — Test with invalid URLs, network issues
4. **Both architectures** — Test on Intel and Apple Silicon Macs
5. **Different macOS versions** — Test on supported macOS versions

### Documentation

- Update README.md for user-facing changes
- Add comments in code for complex logic
- Include examples for new features
- Update troubleshooting section for known issues

## Development Setup

### Prerequisites

- macOS 12 or later
- Microsoft Intune test environment
- Azure Blob Storage account (for testing)
- Test Mac device(s) for enrollment

### Local Testing

```bash
# Run bootstrap manually (as root)
sudo /bin/zsh intune-onboarding-bootstrap.zsh

# Check logs
tail -f "/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboard.log"

# Reset for re-testing
sudo rm -f "/Library/Application Support/Microsoft/IntuneScripts/onBoarding/onboardingcompleted.flag"
sudo rm -f "/Library/LaunchDaemons/com.example.intune.onboarding.plist"
sudo rm -f "/Library/Application Support/Microsoft/IntuneScripts/onboarding.zsh"
```

## Release Process

1. Update version numbers in scripts
2. Update CHANGELOG.md
3. Create a GitHub release with:
   - Version tag (e.g., `v1.0.0`)
   - Release notes
   - Any migration instructions

## Questions?

If you have questions about contributing, please open a discussion or issue.

Thank you for helping improve this project! 🎉
