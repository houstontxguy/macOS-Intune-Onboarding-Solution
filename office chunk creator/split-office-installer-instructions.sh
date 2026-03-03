#!/bin/bash
############################################################################################
##
## Instructions for splitting Office 365 installer for parallel downloads
##
## Run these commands on your local machine before uploading to Azure
##
############################################################################################

# === STEP 1: Get your file info ===

# Check current file size (save this for the script)
OFFICE_PKG="Microsoft_365_and_Office_16.105.26011018_Installer.pkg"
stat -f%z "$OFFICE_PKG"
# Example output: 2147483648  (use this for expectedFileSize in the script)


# === STEP 2: Split into 200MB chunks ===

# This creates files named:
#   Microsoft_365_and_Office_16.103.25110922_Installer.pkg.part_aa
#   Microsoft_365_and_Office_16.103.25110922_Installer.pkg.part_ab
#   Microsoft_365_and_Office_16.103.25110922_Installer.pkg.part_ac
#   ... etc

split -b 200m "$OFFICE_PKG" "${OFFICE_PKG}.part_"


# === STEP 3: List the chunks created ===

ls -la "${OFFICE_PKG}.part_"*

# Example output for ~2GB file:
#   -rw-r--r--  1 user  staff  209715200 Jan 13 10:00 ...part_aa
#   -rw-r--r--  1 user  staff  209715200 Jan 13 10:00 ...part_ab
#   -rw-r--r--  1 user  staff  209715200 Jan 13 10:00 ...part_ac
#   ... (approximately 10 files)


# === STEP 4: Get the chunk list ===

# Run this to see what suffixes were created:
ls "${OFFICE_PKG}.part_"* | sed "s/.*part_//" | tr '\n' ' '

# Example output: aa ab ac ad ae af ag ah ai aj
# Copy this to update chunkList in the script


# === STEP 5: Upload to Azure Blob Storage ===

# Option A: Using Azure CLI
az storage blob upload-batch \
    --account-name yourstorageaccount \
    --destination core-installs/onboarding \
    --source . \
    --pattern "${OFFICE_PKG}.part_*"

# Option B: Using Azure Storage Explorer
# 1. Open Azure Storage Explorer
# 2. Navigate to: yourstorageaccount > Blob Containers > core-installs > onboarding
# 3. Upload all .part_* files


# === STEP 6: Generate SAS tokens ===

# You'll need a SAS token that works for all chunks. 
# Easiest: Generate a container-level SAS or use the same token for the pattern.

# Using Azure CLI:
az storage blob generate-sas \
    --account-name yourstorageaccount \
    --container-name core-installs \
    --name "onboarding/${OFFICE_PKG}.part_aa" \
    --permissions r \
    --expiry 2026-12-03T00:00:00Z \
    --https-only


# === STEP 7: Update the script ===

# Edit 02-installOffice365Pro.sh and update these variables:

# 1. Update sasToken with your new SAS token
# 2. Update chunkList with your actual chunk suffixes (from Step 4)
# 3. Update expectedFileSize with actual file size (from Step 1)

# Example:
#   sasToken="sv=2025-07-05&spr=https&st=2025-12-02..."
#   chunkList=("aa" "ab" "ac" "ad" "ae" "af" "ag" "ah" "ai" "aj")
#   expectedFileSize=2147483648


# === STEP 8: Verify (optional) ===

# Test reassembly locally before deploying:
cat "${OFFICE_PKG}.part_"* > "${OFFICE_PKG}.reassembled"
diff "$OFFICE_PKG" "${OFFICE_PKG}.reassembled"
# Should output nothing if files are identical

# Check SHA256:
shasum -a 256 "$OFFICE_PKG"
shasum -a 256 "${OFFICE_PKG}.reassembled"
# Should match


# === CLEANUP ===

# After uploading, you can delete local chunks:
rm "${OFFICE_PKG}.part_"*
rm "${OFFICE_PKG}.reassembled"
