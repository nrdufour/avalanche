# Immich Photo Import Guide

**Created**: 2026-01-10
**Status**: Active

## Overview

This guide covers best practices for importing large photo libraries into Immich. While the web UI works for small batches, bulk imports require different strategies to ensure reliability and performance.

## Import Methods

### Method 1: Immich CLI (Recommended for Bulk Import)

The official CLI tool is the fastest and most reliable way to upload thousands of photos.

**Installation:**
```bash
# Install globally
npm install -g @immich/cli

# Or use npx (no installation required)
npx @immich/cli --help
```

**Get API Key:**
1. Go to https://immich.internal
2. Click profile icon → **Account Settings**
3. Navigate to **API Keys**
4. Click **New API Key**
5. Copy the generated key

**Basic Upload:**
```bash
npx @immich/cli upload \
  --key YOUR_API_KEY \
  --server https://immich.internal \
  --recursive \
  /path/to/photos
```

**Advanced Options:**
```bash
npx @immich/cli upload \
  --key YOUR_API_KEY \
  --server https://immich.internal \
  --recursive \
  --skip-hash \           # Skip duplicate detection (faster if you're sure no dupes)
  --delete \              # Delete local files after successful upload
  --album "Family 2024" \ # Create/add to album
  /path/to/photos
```

**Advantages:**
- ✅ Handles thousands of photos reliably
- ✅ Resumes on network failure
- ✅ Progress tracking
- ✅ Can exclude patterns (`.git`, `node_modules`, `.DS_Store`)
- ✅ Batch operations (albums, deletion)

**Disadvantages:**
- ❌ Requires Node.js installation
- ❌ Photos are copied (duplicates storage)

### Method 2: External Library (Best if Photos Already on NFS)

Since Immich's library volume is NFS-mounted from `cardinal:/tank/Images`, you can import photos **without uploading** by placing them directly on cardinal and having Immich scan them.

**Setup:**
```bash
# 1. Copy photos to cardinal's NFS export
rsync -avP --progress ~/Pictures/ cardinal.internal:/tank/Images/library/

# 2. In Immich web UI:
#    Settings → Libraries → External Libraries → Create External Library
#
#    Name: My Photo Library
#    Import paths: /data/library
#
# 3. Click "Scan Library" to index photos
```

**Advantages:**
- ✅ No upload time (files already on storage)
- ✅ No duplicate storage (single copy on cardinal)
- ✅ Faster initial import (just scans metadata)
- ✅ Files stay on cardinal's ZFS with snapshots/backups

**Disadvantages:**
- ❌ Files must remain in place (can't delete from cardinal)
- ❌ Immich doesn't manage the file structure
- ❌ Requires SSH access to cardinal

**Best for:**
- Large existing photo libraries already on network storage
- Users who want to keep photos on ZFS with independent backups
- Situations where storage space is limited

### Method 3: Web UI Upload (Small Batches Only)

The web interface works well for small batches and testing.

**Usage:**
1. Go to https://immich.internal
2. Click **Upload** button
3. Drag and drop photos or click to browse
4. Select multiple files/folders

**Recommended for:**
- ✅ Testing with 10-50 photos
- ✅ Adding new albums occasionally
- ✅ Quick uploads from desktop

**Not recommended for:**
- ❌ Thousands of photos (browser will struggle)
- ❌ Unreliable network (no resume capability)
- ❌ Large files (>100MB each)

### Method 4: Mobile App Auto-Upload

After initial bulk import, use the mobile apps for ongoing synchronization.

**Setup:**
1. Install Immich mobile app (iOS/Android)
2. Configure server URL: `https://immich.internal`
3. Enable background upload
4. Select albums to sync

**Best for:**
- ✅ Ongoing phone photo backup
- ✅ Automatic new photo sync
- ✅ On-the-go access

## Recommended Import Strategy

### Phase 1: Test with Small Subset (Critical!)

**Never start with your entire library.** Test first to verify everything works.

```bash
# Select 50-100 diverse photos (mix of formats, dates, locations)
npx @immich/cli upload \
  --key YOUR_API_KEY \
  --server https://immich.internal \
  --recursive \
  ~/Pictures/test-batch
```

**Verify:**
1. Photos appear in Immich web UI
2. Wait 10-15 minutes for ML processing
3. Check **Explore → People** for detected faces
4. Try smart search for concepts (e.g., "outdoor", "person")
5. Verify thumbnails generated
6. Check storage usage on cardinal and in Longhorn PVCs

**If any issues arise, fix them before bulk import!**

### Phase 2: Bulk Import by Batches

Import in logical batches (by year or event) rather than all at once. This makes it easier to:
- Track progress
- Identify problematic photos
- Manage ML processing load

```bash
# Import by year (easier to track and debug)
for year in 2020 2021 2022 2023 2024 2025; do
  echo "=== Importing $year ==="
  npx @immich/cli upload \
    --key YOUR_API_KEY \
    --server https://immich.internal \
    --recursive \
    ~/Pictures/$year

  echo "Waiting 2 minutes for ML processing to catch up..."
  sleep 120
done
```

**Alternative: Import by event/album**
```bash
# Create albums during import
npx @immich/cli upload \
  --key YOUR_API_KEY \
  --server https://immich.internal \
  --album "Wedding 2023" \
  --recursive \
  ~/Pictures/Events/Wedding-2023
```

### Phase 3: Monitor ML Processing

ML processing happens asynchronously in the background. Monitor progress to ensure jobs complete.

**Check overall progress:**
```bash
kubectl exec -n media immich-16-db-1 -c postgres -- psql -U postgres -d immich -c "
SELECT
  COUNT(*) as total_photos,
  COUNT(CASE WHEN ss.embedding IS NOT NULL THEN 1 END) as clip_done,
  COUNT(CASE WHEN ajs.\"facesRecognizedAt\" IS NOT NULL THEN 1 END) as faces_done,
  COUNT(CASE WHEN ajs.\"ocrAt\" IS NOT NULL THEN 1 END) as ocr_done
FROM asset a
LEFT JOIN smart_search ss ON a.id = ss.\"assetId\"
LEFT JOIN asset_job_status ajs ON a.id = ajs.\"assetId\";
"
```

**Watch ML processing in real-time:**
```bash
kubectl logs -n media -l app=immich-machine-learning --tail=50 --follow
```

**Check job queues in web UI:**
1. Go to https://immich.internal
2. Profile → **Administration**
3. **Jobs** tab
4. View queue status for:
   - Smart Search (CLIP embeddings)
   - Face Detection
   - Metadata Extraction
   - Thumbnail Generation

**Trigger missing jobs:**
If some photos didn't get processed:
1. Administration → Jobs
2. Find job type (e.g., "Smart Search")
3. Click **"Process Missing"** or **"Process All"**

## Performance Expectations

### Upload Speed
Depends on network bandwidth and photo size:
- **1 Gbps local network**: ~50-100 MB/s
- **100 Mbps**: ~10-12 MB/s
- **Typical**: Hundreds of photos per hour

**Example:** 10,000 photos averaging 5MB each:
- Total size: ~50GB
- Upload time (1Gbps): ~10-15 minutes
- Upload time (100Mbps): ~1.5-2 hours

### ML Processing Speed
Processing happens sequentially on a single machine-learning pod:
- **~5-10 seconds per photo** (CLIP + face detection + OCR)

**Examples:**
- 100 photos: ~15-30 minutes
- 1,000 photos: ~3-5 hours
- 10,000 photos: ~1-2 days
- 50,000 photos: ~5-7 days

**Important:** You can browse and use Immich while ML processing continues in the background. Photos are viewable immediately; smart search and face detection populate gradually.

### Resource Usage During Import

**Expected load:**
- **immich-server**: 200-500 MB RAM, 100-200m CPU
- **immich-machine-learning**: 1-2 GB RAM, 500m-1 CPU
- **PostgreSQL**: 500 MB - 1 GB RAM per replica
- **Redis**: Minimal (64-128 MB)

**Monitor resources:**
```bash
# Check pod resource usage
kubectl top pods -n media

# Check if ML pod is throttled (should show "no" for throttled)
kubectl describe pod -n media -l app=immich-machine-learning | grep -i throttl
```

**If ML processing is slow:**
- Check pod resources aren't maxed out
- Ensure no CPU throttling (cluster policy: no CPU limits)
- Verify ML cache PVC has space (`kubectl exec -n media deployment/immich-machine-learning -- df -h /cache`)

## Storage Planning

### Calculate Required Space

Immich stores:
1. **Original photos** (100% of library size)
2. **Thumbnails** (~5-10% of library size)
3. **Encoded videos** (varies, ~20-50% for transcoded videos)
4. **ML cache** (models: ~600MB CLIP + 20MB OCR)

**Formula:** `Required Space = Library Size × 1.5`

**Example:**
- 50,000 photos @ 5MB average = 250 GB
- Thumbnails = ~25 GB
- ML cache = ~1 GB
- **Total: ~375 GB** (use 400 GB to be safe)

### Check Available Space

**On cardinal (NFS storage):**
```bash
ssh cardinal.internal
df -h /tank/Images
```

**In Immich (PVCs):**
```bash
# Library volume (NFS)
kubectl exec -n media deployment/immich-server -- df -h /data

# Server cache (Longhorn)
kubectl exec -n media deployment/immich-server -- df -h /cache

# ML cache (Longhorn)
kubectl exec -n media deployment/immich-machine-learning -- df -h /cache
```

**Expand if needed:**
- NFS: Expand `/tank/Images` ZFS dataset on cardinal
- Longhorn PVCs: Edit PVC size (requires Longhorn volume expansion support)

## Pre-Import Preparation

### 1. Remove Duplicates (Optional)

Use `fdupes` or similar tools to find duplicate photos before import:

```bash
# Install fdupes (Arch Linux)
sudo pacman -S fdupes

# Find duplicates
fdupes -r ~/Pictures

# Delete duplicates interactively
fdupes -r -d ~/Pictures
```

**Note:** Immich has built-in duplicate detection, but cleaning up beforehand reduces storage and processing time.

### 2. Organize by Date/Event (Optional)

Immich uses EXIF data for dates and creates automatic timelines, but you may want to organize first:

```bash
# Example: Organize by year/month
exiftool '-Directory<DateTimeOriginal' -d ~/Pictures/%Y/%m ~/Pictures/*
```

**Note:** Only do this if your photos lack EXIF data or are poorly organized.

### 3. Remove Unwanted Files

Clean out screenshots, memes, and duplicates:

```bash
# Remove common screenshot patterns
find ~/Pictures -iname "Screenshot*.png" -delete
find ~/Pictures -iname "IMG-*.jpg" -delete  # WhatsApp auto-saved images

# Remove common cache/thumbnail folders
find ~/Pictures -type d -name ".thumbnails" -exec rm -rf {} +
find ~/Pictures -type d -name "__pycache__" -exec rm -rf {} +
```

## Troubleshooting

### Upload Fails with "413 Request Entity Too Large"

**Cause:** Nginx ingress body size limit

**Fix:** Already applied in this cluster (`nginx.ingress.kubernetes.io/proxy-body-size: "0"`)

**Verify:**
```bash
kubectl get ingress -n media immich-ingress -o yaml | grep proxy-body-size
```

Should show: `nginx.ingress.kubernetes.io/proxy-body-size: "0"`

### ML Processing Stalled

**Symptoms:** New photos uploaded but no faces detected, smart search doesn't work

**Check:**
```bash
# Verify ML service is running
kubectl get pods -n media -l app=immich-machine-learning

# Check for errors
kubectl logs -n media -l app=immich-machine-learning --tail=100
```

**Fix:** Trigger jobs manually via web UI:
1. Administration → Jobs
2. Find stalled job type (Smart Search, Face Detection, etc.)
3. Click "Process All" or "Process Missing"

### Photos Missing After Upload

**Check database:**
```bash
kubectl exec -n media immich-16-db-1 -c postgres -- psql -U postgres -d immich -c "SELECT COUNT(*) FROM asset;"
```

**Check filesystem:**
```bash
kubectl exec -n media deployment/immich-server -- ls -lh /data/library/
```

**Common causes:**
- Upload interrupted (check CLI logs)
- Immich didn't have write permissions (check pod logs)
- NFS mount issue (check `kubectl describe pod`)

### Slow Upload Speed

**Check network bandwidth:**
```bash
# From workstation to cardinal
iperf3 -c cardinal.internal
```

**Optimize upload:**
- Use `--skip-hash` if no duplicates expected
- Upload from a machine with fast network connection
- Consider using External Library method (no upload needed)

### Database Full / Out of Space

**Check database size:**
```bash
kubectl exec -n media immich-16-db-1 -c postgres -- psql -U postgres -d immich -c "
SELECT pg_size_pretty(pg_database_size('immich')) AS database_size;
"
```

**Expand if needed:**
```bash
# Check current PVC size
kubectl get pvc -n media | grep immich-16-db

# CloudNative-PG automatically manages storage
# If needed, edit cluster spec to increase storage size
kubectl edit cluster -n media immich-16-db
# Update: spec.storage.size: 20Gi (or larger)
```

## Post-Import Tasks

### 1. Verify Backup Configuration

**VolSync backups** (cache volumes):
```bash
kubectl get replicationsource -n media immich-cache
# Should show successful backups
```

**Barman backups** (PostgreSQL):
```bash
kubectl get backup -n media
# Should show recent successful backups
```

### 2. Set Up Mobile Auto-Upload

1. Install Immich mobile app
2. Configure server URL
3. Enable background upload
4. Test with a few photos

### 3. Configure Face Recognition

1. Go to **Explore → People**
2. Name detected faces
3. Immich will group similar faces automatically

### 4. Create Albums

Organize photos into albums:
- By event (weddings, trips, birthdays)
- By person (using face recognition)
- By year/season

### 5. Review Storage Usage

```bash
# Check overall usage
kubectl exec -n media deployment/immich-server -- du -sh /data/*

# By user (if multi-user)
kubectl exec -n media immich-16-db-1 -c postgres -- psql -U postgres -d immich -c "
SELECT
  u.email,
  COUNT(a.id) as photo_count,
  pg_size_pretty(SUM(a.\"fileSize\")::bigint) as total_size
FROM users u
LEFT JOIN asset a ON a.\"ownerId\" = u.id
GROUP BY u.email;
"
```

## Best Practices Summary

1. **Test first** - Always import 50-100 photos as a test before bulk import
2. **Import in batches** - By year or event, easier to track and debug
3. **Monitor ML processing** - Check job queues, don't assume it's automatic
4. **Use CLI for bulk** - Web UI is for small batches only
5. **Consider External Library** - If photos already on network storage
6. **Plan for 1.5x storage** - Originals + thumbnails + cache
7. **Clean before import** - Remove duplicates and unwanted files
8. **Verify backups work** - Test VolSync and Barman after initial import
9. **Don't interrupt ML processing** - Let it complete, even if it takes days
10. **Use albums and face naming** - Makes search much more powerful

## Additional Resources

- **Immich CLI documentation**: https://immich.app/docs/features/command-line-interface
- **External libraries guide**: https://immich.app/docs/features/libraries
- **Backup configuration**: `kubernetes/base/apps/media/immich/storage/volsync/`
- **Database backups**: `kubernetes/base/apps/media/immich/db/`

## Appendix: Example Import Scripts

### Script 1: Batch Import by Year

```bash
#!/bin/bash
set -e

API_KEY="YOUR_API_KEY_HERE"
SERVER="https://immich.internal"
PHOTO_DIR="$HOME/Pictures"

for year in 2020 2021 2022 2023 2024 2025; do
  if [ ! -d "$PHOTO_DIR/$year" ]; then
    echo "Skipping $year (directory not found)"
    continue
  fi

  echo "========================================="
  echo "Importing photos from $year..."
  echo "========================================="

  npx @immich/cli upload \
    --key "$API_KEY" \
    --server "$SERVER" \
    --recursive \
    "$PHOTO_DIR/$year"

  echo ""
  echo "Import complete for $year. Waiting 2 minutes for processing..."
  sleep 120
done

echo ""
echo "All imports complete!"
echo "Check ML processing status at: $SERVER → Administration → Jobs"
```

### Script 2: External Library Setup

```bash
#!/bin/bash
set -e

LOCAL_PHOTOS="$HOME/Pictures"
CARDINAL_HOST="cardinal.internal"
CARDINAL_PATH="/tank/Images/library"

echo "Copying photos to cardinal..."
rsync -avP --progress \
  --exclude=".DS_Store" \
  --exclude="Thumbs.db" \
  --exclude=".thumbnails" \
  "$LOCAL_PHOTOS/" "$CARDINAL_HOST:$CARDINAL_PATH/"

echo ""
echo "Copy complete!"
echo ""
echo "Next steps:"
echo "1. Go to https://immich.internal"
echo "2. Settings → Libraries → External Libraries"
echo "3. Create external library with path: /data/library"
echo "4. Click 'Scan Library'"
```

### Script 3: Monitor ML Processing

```bash
#!/bin/bash

echo "=== Immich ML Processing Monitor ==="
echo ""

while true; do
  clear
  echo "ML Processing Status (refreshes every 30s)"
  echo "Press Ctrl+C to exit"
  echo ""

  kubectl exec -n media immich-16-db-1 -c postgres -- psql -U postgres -d immich -c "
SELECT
  COUNT(*) as total_photos,
  COUNT(CASE WHEN ss.embedding IS NOT NULL THEN 1 END) as clip_done,
  ROUND(100.0 * COUNT(CASE WHEN ss.embedding IS NOT NULL THEN 1 END) / NULLIF(COUNT(*), 0), 1) as clip_pct,
  COUNT(CASE WHEN ajs.\"facesRecognizedAt\" IS NOT NULL THEN 1 END) as faces_done,
  ROUND(100.0 * COUNT(CASE WHEN ajs.\"facesRecognizedAt\" IS NOT NULL THEN 1 END) / NULLIF(COUNT(*), 0), 1) as faces_pct
FROM asset a
LEFT JOIN smart_search ss ON a.id = ss.\"assetId\"
LEFT JOIN asset_job_status ajs ON a.id = ajs.\"assetId\";
"

  echo ""
  echo "Storage Usage:"
  kubectl exec -n media deployment/immich-server -- df -h /data /cache 2>/dev/null | tail -2

  sleep 30
done
```

Save these scripts and make them executable:
```bash
chmod +x import-by-year.sh external-library-setup.sh monitor-ml.sh
```
