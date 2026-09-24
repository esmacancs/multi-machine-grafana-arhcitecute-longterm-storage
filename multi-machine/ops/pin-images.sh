#!/bin/bash
# =============================================================================
#  Pin image tags to digests (@sha256:...) in every .env under multi-machine/.
#  Run on a machine with Docker + registry access (or CI). See design §13.
#    ./pin-images.sh            # rewrites .env files in place (backups .env.bak)
#    ./pin-images.sh --check    # only report images without a digest
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-run}"

# every image-bearing key used across the stack
KEYS='ONETECH_IMAGE VICTORIA_IMAGE VMAUTH_IMAGE NODE_IMAGE VMAGENT_IMAGE
      BLACKBOX_IMAGE PUSHGW_IMAGE PG_IMAGE KC_IMAGE
      FORTIGATE_EXPORTER_IMAGE OCI_EXPORTER_IMAGE'

pin_one() {
  local img="$1"
  case "$img" in
    ""|"#"*) echo "$img"; return ;;                     # empty / comment
    *@sha256:*) echo "$img"; return ;;                  # already pinned
    ghcr.io/*|*/latest) echo "$img"; return ;;          # mirror/later must be resolved by digest
  esac
  local dgst
  dgst=$(docker buildx imagetools inspect "$img" --format '{{println .Manifest.Digest}}' 2>/dev/null | head -1 || true)
  if [ -z "$dgst" ]; then
    dgst=$(docker manifest inspect "$img" 2>/dev/null | grep -m1 '"digest"' | cut -d'"' -f4 || true)
  fi
  if [ -n "$dgst" ]; then echo "${img}@${dgst}"; else echo "$img"; fi
}

for envf in $(find . -name '.env' -not -path '*/.*' | sort); do
  cp "$envf" "$envf.bak"
  while IFS= read -r line; do
    for k in $KEYS; do
      case "$line" in
        "$k="*)
          cur="${line#"$k="}"
          new=$(pin_one "$cur")
          if [ "$MODE" = "--check" ]; then
            case "$new" in *@sha256:*) ;; *) echo "$envf: $k not pinned ($cur)";; esac
          fi
          line="$k=$new"
          ;;
      esac
    done
    printf '%s\n' "$line"
  done < "$envf.bak" > "$envf"
  [ "$MODE" = "--check" ] && rm -f "$envf" || true
  echo "processed: $envf"
done

[ "$MODE" = "--check" ] && exit 0

echo
echo "Pinned. Validate with: docker compose config | grep image:"
echo "  Re-run after every upgrade; commit the .env digests."