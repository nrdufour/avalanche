# Vaultwarden management recipes

# List available vw recipes
default:
    @just --list vw

# List all Vaultwarden items with their UUIDs
list:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Fetching Vaultwarden items..."
    echo ""

    kubectl exec -n security deployment/bitwarden-cli -- \
        curl -s http://127.0.0.1:8087/list/object/items | \
        jq -r '.data.data[] | "\(.id)\t\(.name)\t\(.type)"' | \
        column -t -s $'\t' -N "UUID,NAME,TYPE"

# Search Vaultwarden items by name
search search_term:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Searching for '{{search_term}}' in Vaultwarden..."
    echo ""

    kubectl exec -n security deployment/bitwarden-cli -- \
        curl -s http://127.0.0.1:8087/list/object/items | \
        jq -r '.data.data[] | select(.name | ascii_downcase | contains("{{search_term}}" | ascii_downcase)) | "\(.id)\t\(.name)\t\(.type)"' | \
        column -t -s $'\t' -N "UUID,NAME,TYPE"

# Get details of a specific Vaultwarden item by UUID
get uuid:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Fetching item {{uuid}}..."
    echo ""

    kubectl exec -n security deployment/bitwarden-cli -- \
        curl -s http://127.0.0.1:8087/object/item/{{uuid}} | \
        jq '.data'

# List Vaultwarden items in JSON format (for scripting)
list-json:
    #!/usr/bin/env bash
    set -euo pipefail

    kubectl exec -n security deployment/bitwarden-cli -- \
        curl -s http://127.0.0.1:8087/list/object/items | \
        jq '.data.data'
