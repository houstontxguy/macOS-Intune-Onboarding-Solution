#!/bin/zsh
############################################################################################
##
## Standard app installer -- called with APP_ID from apps.conf
## Handles any app that follows the download + detect type + install pattern
##
## Usage: install-standard.zsh <APP_ID>
##   e.g. install-standard.zsh AppThree
##        install-standard.zsh AppNine
##
## VER 2.0.0
## Your Organization IT
############################################################################################

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/lib/common.zsh"
source "${SCRIPT_DIR}/config/urls.conf"

# Load config for the requested app
load_app_config "$1" || exit 1

# Run the standard install flow
runStandardInstall
