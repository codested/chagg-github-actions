#!/usr/bin/env bash
# upload-resources.sh — compress and upload image resources to chagg-service.
#
# Usage:
#   upload-resources.sh <json-file> <api-key> <api-url>
#
# The JSON file must be a chagg changelog (--format json) containing a
# top-level "resources" array with {path, entry_id} objects and "groups"
# with version info.
set -uo pipefail
# Note: set -e is intentionally omitted — this script must never fail the
# calling workflow.  All errors are reported as ::warning:: annotations.

JSON_FILE="${1:?usage: upload-resources.sh <json-file> <api-key> <api-url>}"
API_KEY="${2:?}"
API_URL="${3:?}"

# Size thresholds (bytes).
COMPRESS_THRESHOLD=$((2 * 1024 * 1024))   # compress images > 2 MB
MAX_FILE_SIZE=$((5 * 1024 * 1024))         # server rejects files > 5 MB

# ── helpers ──────────────────────────────────────────────────────────────────

has_cmd() { command -v "$1" &>/dev/null; }

# Pick the ImageMagick binary (v7 "magick" or v6 "convert").
MAGICK=""
if has_cmd magick; then
  MAGICK="magick"
elif has_cmd convert; then
  MAGICK="convert"
fi

is_image() {
  local mime
  mime=$(file -b --mime-type "$1" 2>/dev/null || echo "")
  [[ "$mime" == image/* ]]
}

file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

# Compress an image in-place if it exceeds COMPRESS_THRESHOLD.
# Returns 0 on success, 1 if the file is still too large.
compress_image() {
  local src="$1"
  local size
  size=$(file_size "$src")

  if [ "$size" -le "$COMPRESS_THRESHOLD" ]; then
    return 0
  fi

  if [ -z "$MAGICK" ]; then
    echo "::warning::ImageMagick not found — cannot compress $src (${size} bytes)"
    [ "$size" -le "$MAX_FILE_SIZE" ] && return 0
    return 1
  fi

  echo "  compressing $src ($(( size / 1024 )) KB)..."

  local tmp="${src}.compressed"
  # Resize so the longest side is at most 2000 px, keep aspect ratio,
  # strip metadata, and set JPEG/WebP quality to 85.
  if ! $MAGICK "$src" \
    -resize '2000x2000>' \
    -strip \
    -quality 85 \
    "$tmp" 2>/dev/null; then
    echo "::warning::ImageMagick failed to compress $src"
    rm -f "$tmp"
    [ "$(file_size "$src")" -le "$MAX_FILE_SIZE" ] && return 0
    return 1
  fi

  if [ -f "$tmp" ]; then
    local new_size
    new_size=$(file_size "$tmp")
    if [ "$new_size" -lt "$size" ]; then
      mv "$tmp" "$src"
      echo "  -> $(( new_size / 1024 )) KB"
    else
      rm -f "$tmp"
    fi
  fi

  size=$(file_size "$src")
  if [ "$size" -gt "$MAX_FILE_SIZE" ]; then
    echo "::warning::$src still exceeds 5 MB after compression — skipping upload"
    return 1
  fi
  return 0
}

# ── extract version->entry_id->path mapping from the JSON ───────────────────

# Produce TSV lines: entry_id <TAB> version <TAB> path
RESOURCE_LINES=$(jq -r '
  # Build entry_id -> version lookup from groups
  (
    [ .groups[] as $g | $g.types[].entries[].id as $eid | {($eid): $g.version} ]
    | add // {}
  ) as $id2ver
  | (.resources // [])[]
  | ($id2ver[.entry_id] // empty) as $version
  | [.entry_id, $version, .path]
  | @tsv
' "$JSON_FILE" 2>/dev/null || true)

if [ -z "$RESOURCE_LINES" ]; then
  echo "No image resources to upload."
  exit 0
fi

# ── compress & collect ───────────────────────────────────────────────────────

# We collect validated resources into a temp file (one TSV line per resource)
# grouped by version, then upload one multipart request per version.
STAGING_FILE=$(mktemp)
trap 'rm -f "$STAGING_FILE"' EXIT

SKIPPED=0
TOTAL=0

while IFS=$'\t' read -r entry_id version rel_path; do
  [ -z "$rel_path" ] && continue

  if [ ! -f "$rel_path" ]; then
    echo "::warning::Resource file not found: $rel_path"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if ! is_image "$rel_path"; then
    echo "::warning::Skipping non-image file: $rel_path"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if ! compress_image "$rel_path"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  printf '%s\t%s\t%s\n' "$entry_id" "$version" "$rel_path" >> "$STAGING_FILE"
  TOTAL=$((TOTAL + 1))
done <<< "$RESOURCE_LINES"

if [ "$TOTAL" -eq 0 ]; then
  echo "No resources to upload (${SKIPPED} skipped)."
  exit 0
fi

echo "Uploading ${TOTAL} resource(s) to chagg-service..."

# ── upload per version ───────────────────────────────────────────────────────

# Get unique versions.
VERSIONS=$(cut -f2 "$STAGING_FILE" | sort -u)

for version in $VERSIONS; do
  # Build curl -F args array safely.
  CURL_ARGS=()
  while IFS=$'\t' read -r entry_id _ rel_path; do
    # Use ;filename= to preserve the full relative path as the uploaded
    # filename. Without this, curl sends only the basename and the service
    # would store "screenshot.png" instead of ".changes/images/screenshot.png",
    # breaking the body-image path matching in the web UI.
    CURL_ARGS+=(-F "${entry_id}=@${rel_path};filename=${rel_path}")
  done < <(awk -F'\t' -v v="$version" '$2 == v' "$STAGING_FILE")

  if [ ${#CURL_ARGS[@]} -eq 0 ]; then
    continue
  fi

  HTTP_CODE=$(curl -sS -o /tmp/resource-response.json -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${API_KEY}" \
    "${CURL_ARGS[@]}" \
    "${API_URL}/changelogs/${version}/resources" 2>/dev/null) || true

  if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "  version ${version}: uploaded ${#CURL_ARGS[@]} file(s)"
  else
    echo "::warning::Resource upload failed for version ${version} (HTTP ${HTTP_CODE:-unknown})"
    cat /tmp/resource-response.json 2>/dev/null || true
  fi
done

echo "Done: ${TOTAL} uploaded, ${SKIPPED} skipped."
