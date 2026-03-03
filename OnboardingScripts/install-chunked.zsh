#!/bin/zsh
############################################################################################
##
## Chunked installer -- special handler for large apps using chunked parallel download
##
## VER 2.0.0
## Your Organization IT
############################################################################################

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/lib/common.zsh"
source "${SCRIPT_DIR}/config/urls.conf"

# Load config for the chunked app (APP_ID defined in apps.conf with handler=chunked)
load_app_config "AppTwo" || exit 1

# Start logging
start_app_timer
startLog

log_info "============================================================"
log_info "Starting install of [$appname] to [$log]"
log_info "============================================================"

# Install Rosetta if needed
checkForRosetta2

###############################################################
## Suite-specific update check (checks for all sub-apps)
###############################################################

log_info "Checking if we need to install or update [$appname]"
updateSplashScreen wait "Checking for updates..."

# List all sub-applications that are part of this suite
SuiteApps=(
    "/Applications/Suite App One.app"
    "/Applications/Suite App Two.app"
    "/Applications/Suite App Three.app"
    "/Applications/Suite App Four.app"
)

missingappcount=0
for i in "${SuiteApps[@]}"; do
    if [[ ! -e "$i" ]]; then
        log_info "[$i] not installed, need to perform full installation"
        missingappcount=$((missingappcount + 1))
    fi
done

if [[ $missingappcount -eq 0 ]]; then
    if [[ "$autoUpdate" == "true" ]]; then
        log_info "[$appname] is already installed and handles updates itself, exiting"
        updateSplashScreen success Installed
        exit 0
    fi

    # Use first chunk URL to check last modified date
    checkUrl="${URL_OFFICE_BASE}/${OFFICE_CHUNK_PREFIX}aa?${SAS_TOKEN}"
    lastmodified=$(curl -sIL "$checkUrl" | grep -i "last-modified" | awk '{$1=""; print $0}' | awk '{ sub(/^[ \t]+/, ""); print }' | tr -d '\r')

    if [[ -d "$logandmetadir" ]] && [[ -f "$metafile" ]]; then
        previouslastmodifieddate=$(cat "$metafile")
        if [[ "$previouslastmodifieddate" == "$lastmodified" ]]; then
            log_info "No update between previous [$previouslastmodifieddate] and current [$lastmodified]"
            updateSplashScreen success Installed
            log_info "Exiting, nothing to do"
            exit 0
        else
            log_info "Update found, previous [$previouslastmodifieddate] and current [$lastmodified]"
        fi
    fi
fi

# Wait for desktop
waitForDesktop

###############################################################
## Chunked parallel download
###############################################################

# Download a single chunk with retries
downloadChunk() {
    local chunkName=$1
    local outputFile=$2
    local url="${URL_OFFICE_BASE}/${OFFICE_CHUNK_PREFIX}${chunkName}?${SAS_TOKEN}"
    local maxAttempts=5
    local attempt=0

    while [[ $attempt -lt $maxAttempts ]]; do
        attempt=$((attempt + 1))
        log_info "Chunk [$chunkName] attempt $attempt of $maxAttempts..."

        # Wait for network before each chunk attempt
        wait_for_network || continue

        curl -fL \
            --connect-timeout 10 \
            --max-time 1800 \
            --speed-limit 10240 \
            --speed-time 120 \
            --retry 3 \
            --retry-delay 5 \
            --retry-all-errors \
            -o "$outputFile" \
            "$url"

        if [[ $? -eq 0 && -s "$outputFile" ]]; then
            # Validate chunk is not too small (likely error page)
            local chunk_size=$(stat -f%z "$outputFile" 2>/dev/null || echo 0)
            if (( chunk_size < 1024 )); then
                log_warn "Chunk [$chunkName] too small (${chunk_size} bytes), likely corrupt"
                rm -f "$outputFile"
            else
                log_info "Chunk [$chunkName] downloaded successfully ($(humanize_bytes $chunk_size))"
                return 0
            fi
        else
            log_warn "Chunk [$chunkName] attempt $attempt failed"
            # Delete partial file before retry to prevent corruption
            rm -f "$outputFile" 2>/dev/null
        fi

        if [[ $attempt -lt $maxAttempts ]]; then
            local delay=$(retry_delay $attempt)
            log_info "Retrying chunk [$chunkName] in ${delay}s..."
            sleep $delay
        fi
    done

    log_error "Chunk [$chunkName] FAILED after $maxAttempts attempts"
    return 1
}

log_info "Starting parallel chunk download of [$appname]"
updateSplashScreen progress "Downloading (chunked)"

# Wait for network before starting downloads
wait_for_network || {
    updateSplashScreen fail "No network"
    exit 1
}

cd "$tempdir"
start_download_timer
chunkDir="$tempdir/chunks"
mkdir -p "$chunkDir"

pids=()
failed=false

# Kill orphaned chunk processes if script exits unexpectedly
cleanup_chunks() {
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null
    done
}
trap cleanup_chunks EXIT

log_info "Launching ${#OFFICE_CHUNK_LIST[@]} parallel downloads..."

for chunk in "${OFFICE_CHUNK_LIST[@]}"; do
    downloadChunk "$chunk" "$chunkDir/part_$chunk" &
    pids+=($!)
done

log_info "Waiting for all chunks to complete..."
for (( i = 1; i <= ${#pids[@]}; i++ )); do
    wait ${pids[$i]}
    if [[ $? -ne 0 ]]; then
        log_warn "Chunk ${OFFICE_CHUNK_LIST[$i]} failed"
        failed=true
    fi
done

# Sequential retry for any failed chunks
if [[ "$failed" == true ]]; then
    log_warn "Some chunks failed, attempting sequential retry..."
    for chunk in "${OFFICE_CHUNK_LIST[@]}"; do
        if [[ ! -s "$chunkDir/part_$chunk" ]]; then
            log_info "Retrying chunk [$chunk]..."
            downloadChunk "$chunk" "$chunkDir/part_$chunk"
            if [[ $? -ne 0 ]]; then
                log_error "FATAL: Could not download chunk [$chunk]"
                updateSplashScreen fail "Download failed"
                exit 1
            fi
        fi
    done
fi

# Verify all chunks exist
log_info "Verifying all chunks downloaded..."
for chunk in "${OFFICE_CHUNK_LIST[@]}"; do
    if [[ ! -s "$chunkDir/part_$chunk" ]]; then
        log_error "FATAL: Missing chunk [$chunk]"
        updateSplashScreen fail "Download failed"
        exit 1
    fi
done

dl_elapsed=$(( SECONDS - DOWNLOAD_TIMER_START ))
log_info "Download completed in ${dl_elapsed}s"

# Reassemble chunks into final PKG
office_pkg="$tempdir/$appname.pkg"
log_info "Reassembling ${#OFFICE_CHUNK_LIST[@]} chunks into [$office_pkg]..."
updateSplashScreen progress "Assembling"

cat "$chunkDir"/part_* > "$office_pkg"
if [[ $? -ne 0 ]]; then
    log_error "FATAL: Failed to reassemble chunks"
    updateSplashScreen fail "Assembly failed"
    exit 1
fi

actualSize=$(stat -f%z "$office_pkg" 2>/dev/null || echo 0)
log_info "Final file size: $(humanize_bytes $actualSize) (expected: $(humanize_bytes $OFFICE_EXPECTED_SIZE))"

if [[ $actualSize -lt $((OFFICE_EXPECTED_SIZE - 1000000)) ]]; then
    log_warn "File size smaller than expected, may be incomplete"
fi

# Validate the assembled package
validate_download "$office_pkg" "pkg" || {
    log_error "Assembled chunked package failed validation"
    updateSplashScreen fail "Download corrupt"
    rm -rf "$tempdir"
    exit 1
}

rm -rf "$chunkDir"
trap - EXIT  # Clear cleanup trap — chunks assembled successfully
log_info "Download and assembly complete: $office_pkg"
updateSplashScreen progress "Downloaded (${dl_elapsed}s)"

###############################################################
## Install the assembled PKG
###############################################################

log_info "Installing [$appname]"
updateSplashScreen progress "Installing..."

installer -pkg "$office_pkg" -target /Applications
if [[ "$?" = "0" ]]; then
    log_info "$appname Installed"
    log_info "Cleaning Up"
    rm -rf "$tempdir"

    fetchLastModifiedDate update
    log_info "Application [$appname] successfully installed"
    updateSplashScreen success Installed
    log_app_time
    exit 0
else
    log_error "Failed to install $appname"
    rm -rf "$tempdir"
    updateSplashScreen fail Failed
    exit 1
fi
