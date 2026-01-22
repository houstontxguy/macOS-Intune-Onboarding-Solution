# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
