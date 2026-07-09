#!/usr/bin/env bash
#
# NOTICE:
# Sample code only. This script is provided "as is" without warranties or
# guarantees of completeness, accuracy, availability, or fitness for a
# particular environment. Azure inventory, tags, API versions, RBAC permissions,
# service support, and Azure CLI behavior can vary. The customer must
# review, test, and validate all output in their own Azure environment before
# relying on it for operational, capacity, financial, compliance, or remediation
# decisions.
set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Azure resource inventory exporter.

NOTICE:
  Sample code only. Provided "as is" without warranties or guarantees.
  Customer must review, test, and validate all output in their own Azure
  environment before relying on it for operational, capacity, financial,
  compliance, or remediation decisions.

Uses Azure CLI to export resources, tags, raw Azure resource types, and
portal-style resource types to CSV.

Usage:
  ./document-azure-resources.sh [options]

Options:
  -a, --all                         Document resources for all subscriptions returned by Azure CLI.
  -s, --subscription <name-or-id>    Document one subscription. Repeat for multiple subscriptions.
  -f, --subscription-file <path>     Read subscription names or ids from a file, one per line.
                                     Blank lines and lines beginning with # are ignored.
  -t, --tenant <tenant-id>           Limit subscription selection to one tenant id.
  -o, --output <path>                CSV output path. Default: ./azure-resources.csv
  -h, --help                         Show this help.

Examples:
  ./document-azure-resources.sh --all --output ./azure-resources.csv
  ./document-azure-resources.sh --tenant 00000000-0000-0000-0000-000000000000 --all
  ./document-azure-resources.sh --subscription 00000000-0000-0000-0000-000000000000
  ./document-azure-resources.sh --subscription "Sub A" --subscription "Sub B"
  ./document-azure-resources.sh --subscription-file ./subscriptions.txt
USAGE
}

on_error() {
    local exit_code=$?
    local line_number=${BASH_LINENO[0]:-unknown}
    echo "Error: inventory export failed at line ${line_number} with exit code ${exit_code}." >&2
    exit "$exit_code"
}

trap on_error ERR

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' was not found on PATH."
}

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return
    fi

    if command -v python >/dev/null 2>&1; then
        echo "python"
        return
    fi

    die "Python 3 is required to format JSON and CSV output."
}

assert_python_is_version_3() {
    local executable="$1"
    "$executable" - <<'PY'
import sys

if sys.version_info.major < 3:
    raise SystemExit("Python 3 is required.")
PY
}

assert_az_signed_in() {
    if ! az account show -o json >/dev/null; then
        die "Azure CLI is not signed in. Run 'az login' for the intended tenant and try again."
    fi
}

assert_output_path_ready() {
    local path="$1"
    local output_dir
    output_dir="$(dirname "$path")"
    [[ -z "$output_dir" || "$output_dir" == "." ]] && output_dir="."
    mkdir -p "$output_dir"

    local test_file
    test_file="$(mktemp "${output_dir%/}/.inventory-write-test.XXXXXX")"
    rm -f "$test_file"
}

run_preflight_checks() {
    log_info "Running preflight checks."
    need_command az
    python_cmd="$(find_python)"
    assert_python_is_version_3 "$python_cmd"
    assert_az_signed_in
    assert_output_path_ready "$output_path"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

all=false
output_path="./azure-resources.csv"
subscription_file=""
tenant=""
python_cmd=""
subscriptions=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)
            all=true
            shift
            ;;
        -s|--subscription)
            [[ $# -ge 2 ]] || die "Missing value for $1."
            subscriptions+=("$2")
            shift 2
            ;;
        --subscription=*)
            subscriptions+=("${1#*=}")
            shift
            ;;
        -f|--subscription-file)
            [[ $# -ge 2 ]] || die "Missing value for $1."
            subscription_file="$2"
            shift 2
            ;;
        --subscription-file=*)
            subscription_file="${1#*=}"
            shift
            ;;
        -t|--tenant)
            [[ $# -ge 2 ]] || die "Missing value for $1."
            tenant="$2"
            shift 2
            ;;
        --tenant=*)
            tenant="${1#*=}"
            shift
            ;;
        -o|--output)
            [[ $# -ge 2 ]] || die "Missing value for $1."
            output_path="$2"
            shift 2
            ;;
        --output=*)
            output_path="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

run_preflight_checks

if [[ "$all" == true && ( ${#subscriptions[@]} -gt 0 || -n "$subscription_file" ) ]]; then
    die "Use either --all or subscription selectors, not both."
fi

if [[ -n "$subscription_file" ]]; then
    [[ -f "$subscription_file" ]] || die "Subscription file was not found: $subscription_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        subscriptions+=("$line")
    done < "$subscription_file"
fi

if [[ "$all" == false && ${#subscriptions[@]} -eq 0 ]]; then
    while true; do
        read -r -p "No subscription selector supplied. Get resources for [a]ll subscriptions or [o]ne subscription? " choice
        choice="$(trim "${choice,,}")"
        case "$choice" in
            a|all)
                all=true
                break
                ;;
            o|one|1)
                read -r -p "Enter the subscription name or id: " selector
                selector="$(trim "$selector")"
                [[ -z "$selector" ]] && {
                    echo "Subscription name or id cannot be empty." >&2
                    continue
                }
                subscriptions+=("$selector")
                break
                ;;
            *)
                echo "Enter A/all or O/one." >&2
                ;;
        esac
    done
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

accounts_file="$tmp_dir/accounts.json"
selectors_file="$tmp_dir/selectors.txt"
selected_file="$tmp_dir/selected-subscriptions.json"
resources_file="$tmp_dir/resources.json"

# Subscription discovery is tenant-filtered in Python because 'az account list' has
# no native tenant selector.
az account list --all -o json > "$accounts_file"

: > "$selectors_file"
for subscription in "${subscriptions[@]}"; do
    printf '%s\n' "$subscription" >> "$selectors_file"
done

"$python_cmd" - "$accounts_file" "$selectors_file" "$all" "$tenant" > "$selected_file" <<'PY'
import json
import sys

accounts_path, selectors_path, all_flag, tenant = sys.argv[1:5]

with open(accounts_path, "r", encoding="utf-8") as handle:
    accounts = json.load(handle)

if not accounts:
    print("Azure CLI returned no subscriptions. Confirm you are signed in with 'az login'.", file=sys.stderr)
    sys.exit(1)

if tenant:
    accounts = [
        account for account in accounts
        if str(account.get("tenantId", "")).lower() == tenant.lower()
        or str(account.get("homeTenantId", "")).lower() == tenant.lower()
    ]

    if not accounts:
        print(
            f"Azure CLI returned no subscriptions for tenant '{tenant}'. "
            f"Use the tenant id shown by 'az account list', or sign in with 'az login --tenant {tenant}'.",
            file=sys.stderr,
        )
        sys.exit(1)

if all_flag == "true":
    selected = accounts
else:
    with open(selectors_path, "r", encoding="utf-8") as handle:
        selectors = [line.strip() for line in handle if line.strip()]

    selected = []
    errors = []
    for selector in selectors:
        id_matches = [
            account for account in accounts
            if str(account.get("id", "")).lower() == selector.lower()
        ]
        if len(id_matches) == 1:
            selected.append(id_matches[0])
            continue

        name_matches = [
            account for account in accounts
            if str(account.get("name", "")).lower() == selector.lower()
        ]
        if len(name_matches) == 1:
            selected.append(name_matches[0])
        elif len(name_matches) > 1:
            errors.append(f"Subscription name '{selector}' matched multiple subscriptions. Use a subscription id instead.")
        else:
            errors.append(f"No subscription found with name or id '{selector}'.")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        sys.exit(1)

by_id = {}
for subscription in selected:
    subscription_id = subscription.get("id")
    if subscription_id and subscription_id not in by_id:
        by_id[subscription_id] = {
            "id": subscription_id,
            "name": subscription.get("name", "")
        }

selected = list(by_id.values())
if not selected:
    print("No subscriptions were selected.", file=sys.stderr)
    sys.exit(1)

json.dump(selected, sys.stdout)
PY

"$python_cmd" - "$output_path" <<'PY'
import csv
import os
import sys

output_path = sys.argv[1]
parent = os.path.dirname(os.path.abspath(output_path))
if parent:
    os.makedirs(parent, exist_ok=True)

headers = [
    "subscription id",
    "subscription name",
    "resource group",
    "region",
    "availability zone",
    "resource type",
    "portal type",
    "resource name",
    "tags",
]

with open(output_path, "w", encoding="utf-8", newline="") as handle:
    csv.writer(handle).writerow(headers)
PY

resource_count=0
while IFS=$'\t' read -r subscription_id subscription_name; do
    log_info "Collecting resources for ${subscription_name} [${subscription_id}]."
    if ! az account set --subscription "$subscription_id"; then
        log_warn "Skipping ${subscription_name} [${subscription_id}] because Azure CLI could not set the subscription context."
        continue
    fi

    if ! az resource list --subscription "$subscription_id" -o json > "$resources_file"; then
        log_warn "Skipping ${subscription_name} [${subscription_id}] because Azure CLI could not list resources."
        continue
    fi

    rows_added="$("$python_cmd" - "$output_path" "$subscription_id" "$subscription_name" "$resources_file" <<'PY'
import csv
import json
import sys

output_path, subscription_id, subscription_name, resources_path = sys.argv[1:5]

with open(resources_path, "r", encoding="utf-8") as handle:
    resources = json.load(handle)

# Keep tags deterministic and compact in a single CSV column.
def tags_to_text(tags):
    if not isinstance(tags, dict) or not tags:
        return ""
    pairs = []
    for key in sorted(tags):
        value = tags[key]
        pairs.append(f"{key}={'' if value is None else value}")
    return ", ".join(pairs)

def zones_to_text(zones):
    if zones is None:
        return ""
    if isinstance(zones, list):
        return ",".join(str(zone) for zone in zones if zone not in (None, ""))
    return str(zones)

PORTAL_TYPE_NAMES = {
    "microsoft.app/containerapps": "Container App",
    "microsoft.app/managedenvironments": "Container Apps Environment",
    "microsoft.authorization/roleassignments": "Role Assignment",
    "microsoft.cognitiveservices/accounts": "Azure AI Services",
    "microsoft.cognitiveservices/accounts/projects": "Azure AI Foundry Project",
    "microsoft.compute/disks": "Disk",
    "microsoft.compute/snapshots": "Snapshot",
    "microsoft.compute/virtualmachines": "Virtual Machine",
    "microsoft.containerregistry/registries": "Container Registry",
    "microsoft.documentdb/databaseaccounts": "Azure Cosmos DB Account",
    "microsoft.eventgrid/systemtopics": "Event Grid System Topic",
    "microsoft.insights/actiongroups": "Action Group",
    "microsoft.keyvault/vaults": "Key Vault",
    "microsoft.managedidentity/userassignedidentities": "Managed Identity",
    "microsoft.network/loadbalancers": "Load Balancer",
    "microsoft.network/networkinterfaces": "Network Interface",
    "microsoft.network/networksecuritygroups": "Network Security Group",
    "microsoft.network/networkwatchers": "Network Watcher",
    "microsoft.network/privateendpoints": "Private Endpoint",
    "microsoft.network/publicipaddresses": "Public IP Address",
    "microsoft.network/routetables": "Route Table",
    "microsoft.network/virtualnetworks": "Virtual Network",
    "microsoft.operationalinsights/workspaces": "Log Analytics Workspace",
    "microsoft.storage/storageaccounts": "Storage Account",
    "microsoft.web/serverfarms": "App Service Plan",
    "microsoft.web/sites": "App Service",
}

def token_to_title(value):
    if not value:
        return ""
    words = []
    current = ""
    for character in str(value).replace("_", " ").replace("-", " "):
        if character.isupper() and current and (current[-1].islower() or current[-1].isdigit()):
            words.append(current)
            current = character
        else:
            current += character
    if current:
        words.append(current)
    return " ".join(" ".join(words).lower().title().split())

def portal_type_name(resource_type):
    if not resource_type:
        return ""
    normalized = str(resource_type).strip().lower()
    if normalized in PORTAL_TYPE_NAMES:
        return PORTAL_TYPE_NAMES[normalized]
    return token_to_title(str(resource_type).split("/")[-1])

with open(output_path, "a", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle)
    for resource in resources:
        writer.writerow([
            subscription_id,
            subscription_name,
            resource.get("resourceGroup", "") or "",
            resource.get("location", "") or "",
            zones_to_text(resource.get("zones")),
            resource.get("type", "") or "",
            portal_type_name(resource.get("type")),
            resource.get("name", "") or "",
            tags_to_text(resource.get("tags")),
        ])

print(len(resources))
PY
)"
    resource_count=$((resource_count + rows_added))
done < <("$python_cmd" - "$selected_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    subscriptions = json.load(handle)

for subscription in subscriptions:
    print(f"{subscription['id']}\t{subscription.get('name', '')}")
PY
)

log_info "Wrote ${resource_count} resources to ${output_path}"
