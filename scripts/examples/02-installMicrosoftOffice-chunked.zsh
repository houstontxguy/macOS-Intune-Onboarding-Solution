#!/bin/zsh
#
# Microsoft Office Install Script (Chunked Parallel Download)
#
# This script demonstrates how to download large files (~2GB) using parallel
# chunk downloads for improved speed and reliability.
#
# SETUP REQUIRED:
# 1. Split the Office installer into chunks on your machine:
#    split -b 200m Microsoft_365_Installer.pkg Microsoft_365_Installer.pkg.part_
#
# 2. Upload all chunks to Azure Blob Storage
#
# 3. Update the configuration below
#

#####################################
## CONFIGURATION - CUSTOMIZE THESE
#####################################

APP_NAME="Microsoft Office"
APP_PATH="/Applications/Microsoft Word.app"

# Azure Blob Storage base URL (without SAS token)
BASE_URL="https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER"

# SAS token (without leading ?)
SAS_TOKEN="sv=2025-07-05&spr=https&st=2025-01-01..."

# Chunk file prefix (what you named the split files)
CHUNK_PREFIX="Microsoft_365_Installer.pkg.part_"

# List of chunk suffixes (output from: ls *.part_* | sed "s/.*part_//" | tr '\n' ' ')
# For a ~2.7GB file split into 200MB chunks, you'll have ~14 chunks
CHUNK_LIST=("aa" "ab" "ac" "ad" "ae" "af" "ag" "ah" "ai" "aj" "ak" "al" "am" "an")

# Expected final file size in bytes (from: stat -f%z OriginalFile.pkg)
EXPECTED_FILE_SIZE=2737483648

#####################################
## Logging setup
#####################################

LOG_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
LOG_FILE="${LOG_DIR}/MicrosoftOffice.log"
mkdir -p "$LOG_DIR"
exec &> >(tee -a "$LOG_FILE")

echo ""
echo "##############################################################"
echo "# Installing: $APP_NAME (Parallel Download) - $(date)"
echo "##############################################################"
echo ""

#####################################
## Swift Dialog status function
#####################################

updateDialog() {
    local status="$1"
    local statustext="$2"
    echo "listitem: title: ${APP_NAME}, status: ${status}, statustext: ${statustext}" >> /var/tmp/dialog.log
}

updateDialogProgress() {
    local percent="$1"
    echo "listitem: title: ${APP_NAME}, progress: ${percent}" >> /var/tmp/dialog.log
}

#####################################
## Download chunk function
#####################################

downloadChunk() {
    local chunk="$1"
    local outputDir="$2"
    local url="${BASE_URL}/${CHUNK_PREFIX}${chunk}?${SAS_TOKEN}"
    local output="${outputDir}/part_${chunk}"
    local maxAttempts=5
    local attempt=0
    
    while [[ $attempt -lt $maxAttempts ]]; do
        attempt=$((attempt + 1))
        
        httpCode=$(/usr/bin/curl -fL \
            --connect-timeout 10 \
            --max-time 600 \
            --retry 3 \
            --retry-delay 5 \
            --retry-all-errors \
            -C - \
            -o "$output" \
            "$url" \
            -w "%{http_code}" 2>/dev/null)
        
        if [[ "$httpCode" == "200" ]] && [[ -s "$output" ]]; then
            echo "$(date) | Chunk $chunk downloaded successfully"
            return 0
        fi
        
        sleep 2
    done
    
    echo "$(date) | ERROR: Failed to download chunk $chunk"
    return 1
}

#####################################
## Main installation logic
#####################################

updateDialog "wait" "Downloading..."

# Create temp directory
tempdir=$(mktemp -d)
chunksDir="${tempdir}/chunks"
mkdir -p "$chunksDir"

echo "$(date) | Temp directory: $tempdir"
echo "$(date) | Starting parallel download of ${#CHUNK_LIST[@]} chunks..."

# Download all chunks in parallel
pids=()
for chunk in "${CHUNK_LIST[@]}"; do
    downloadChunk "$chunk" "$chunksDir" &
    pids+=($!)
done

# Wait for all downloads to complete
echo "$(date) | Waiting for all chunks to download..."
failedChunks=0
completedChunks=0

for pid in "${pids[@]}"; do
    wait $pid
    if [[ $? -ne 0 ]]; then
        failedChunks=$((failedChunks + 1))
    else
        completedChunks=$((completedChunks + 1))
        # Update progress
        progress=$((completedChunks * 100 / ${#CHUNK_LIST[@]}))
        updateDialogProgress "$progress"
    fi
done

if [[ $failedChunks -gt 0 ]]; then
    echo "$(date) | ERROR: $failedChunks chunk(s) failed to download."
    updateDialog "fail" "Download failed"
    rm -rf "$tempdir"
    exit 1
fi

echo "$(date) | All chunks downloaded successfully."

# Reassemble the file
updateDialog "wait" "Assembling..."
echo "$(date) | Reassembling chunks into PKG..."

pkgFile="${tempdir}/Microsoft_365.pkg"

# Concatenate in order
for chunk in "${CHUNK_LIST[@]}"; do
    cat "${chunksDir}/part_${chunk}" >> "$pkgFile"
done

# Verify file size
actualSize=$(stat -f%z "$pkgFile" 2>/dev/null || echo 0)
echo "$(date) | Reassembled file size: $actualSize bytes (expected: $EXPECTED_FILE_SIZE)"

if [[ $actualSize -lt $EXPECTED_FILE_SIZE ]]; then
    echo "$(date) | ERROR: Reassembled file is smaller than expected."
    updateDialog "fail" "Verification failed"
    rm -rf "$tempdir"
    exit 1
fi

# Install the package
updateDialog "wait" "Installing..."
echo "$(date) | Installing Microsoft Office..."

installer -pkg "$pkgFile" -target /
installResult=$?

# Verify installation
if [[ $installResult -eq 0 ]] && [[ -e "$APP_PATH" ]]; then
    echo "$(date) | Microsoft Office installed successfully."
    updateDialog "success" "Installed"
else
    echo "$(date) | ERROR: Microsoft Office installation failed."
    updateDialog "fail" "Failed"
    rm -rf "$tempdir"
    exit 1
fi

# Cleanup
echo "$(date) | Cleaning up..."
rm -rf "$tempdir"

echo "$(date) | Installation complete."
exit 0
