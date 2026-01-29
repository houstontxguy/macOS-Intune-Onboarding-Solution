# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-01-29

### Fixed
- Devices now resume onboarding after overnight reboot
  - Previously, if onboarding failed and the device was rebooted the next day, the enrollment window check would prevent resumption
  - Added `onboarding_inprogress.flag` to track when onboarding has started
  - Enrollment window check is now skipped if in-progress flag exists

### Changed
- In-progress flag is automatically cleaned up on completion or when completion flag is detected

## [1.0.0] - 2026-01-22

### Added
- Initial public release
- Bootstrap script for Intune deployment
- LaunchDaemon for persistent onboarding
- Swift Dialog integration for progress UI
- Parallel application downloads
- Chunked download support for large files (Microsoft Office)
- Sleep prevention during onboarding (caffeinate)
- Device naming for Intune targeting
- Enrollment window checking
- Self-cleanup after completion
- Example install scripts for common applications
- Comprehensive documentation

### Features
- Support for macOS 12+
- Intel and Apple Silicon support (Rosetta 2 auto-install)
- Azure Blob Storage integration
- Configurable organization settings
- Retry logic with exponential backoff
- Detailed logging for troubleshooting
