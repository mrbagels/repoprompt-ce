#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source "$ROOT_DIR/version.env"
set +a

LOCAL_SELF_SIGNED_CERTIFICATE_NAME="RepoPrompt CE Local Self-Signed Code Signing"
LOCAL_PRODUCTION_INSTALL_DIR="${LOCAL_PRODUCTION_INSTALL_DIR:-/Applications}"
LOCAL_PRODUCTION_APP="$LOCAL_PRODUCTION_INSTALL_DIR/$DISPLAY_NAME.app"
LOCAL_CERTIFICATE_DAYS="${LOCAL_CERTIFICATE_DAYS:-3650}"
LOCAL_SIGNING_IDENTITY_REGISTRY_PATH="${LOCAL_SIGNING_IDENTITY_REGISTRY_PATH:-$HOME/Library/Application Support/RepoPrompt CE/local-signing-identity-v1.json}"
LOCAL_SIGNING_IDENTITY_SHA256="${LOCAL_SIGNING_IDENTITY_SHA256:-}"
ROTATE_LOCAL_SIGNING_IDENTITY="${ROTATE_LOCAL_SIGNING_IDENTITY:-0}"
LOCAL_SIGNING_IDENTITY_TOOL="$ROOT_DIR/Scripts/local_signing_identity.py"
TMP_DIR=""
STAGED_DIR=""
STAGED_APP=""
BACKUP_DIR=""
BACKUP_APP=""
REGISTRY_LOCK_DIR=""
REGISTRY_BACKUP_PATH=""
REGISTRY_EXISTED=0

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
    [[ -z "$STAGED_DIR" ]] || rm -rf "$STAGED_DIR"
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        if [[ ! -e "$LOCAL_PRODUCTION_APP" ]]; then
            mv "$BACKUP_APP" "$LOCAL_PRODUCTION_APP" ||
                printf 'ERROR: Could not restore prior app from backup: %s\n' "$BACKUP_APP" >&2
        else
            printf 'WARNING: Preserving prior app backup after failed replacement: %s\n' "$BACKUP_APP" >&2
        fi
    fi
    [[ -z "$BACKUP_DIR" ]] || rmdir "$BACKUP_DIR" 2>/dev/null || true
    if [[ -n "$REGISTRY_LOCK_DIR" ]]; then
        rm -f "$REGISTRY_LOCK_DIR/pid"
        rmdir "$REGISTRY_LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

json_field() {
    local path="$1"
    local expression="$2"
    python3 - "$path" "$expression" <<'PY'
import json
import sys

value = json.loads(open(sys.argv[1], encoding="utf-8").read())
for component in sys.argv[2].split("."):
    value = value[component]
if isinstance(value, bool):
    print("1" if value else "0")
elif value is not None:
    print(value)
PY
}

inventory_local_identities() {
    local output="$1"
    local -a args=(
        "$LOCAL_SIGNING_IDENTITY_TOOL" inventory
        --certificate-name "$LOCAL_SELF_SIGNED_CERTIFICATE_NAME"
        --keychain "$LOGIN_KEYCHAIN"
    )
    if [[ -n "${LOCAL_SIGNING_IDENTITY_INVENTORY_FIXTURE:-}" ]]; then
        args+=(--fixture "$LOCAL_SIGNING_IDENTITY_INVENTORY_FIXTURE")
    fi
    if [[ -n "${LOCAL_SIGNING_IDENTITY_EVALUATED_AT:-}" ]]; then
        args+=(--at "$LOCAL_SIGNING_IDENTITY_EVALUATED_AT")
    fi
    python3 "${args[@]}" > "$output"
}

mint_local_identity() {
    local password
    password="$(openssl rand -hex 24)"
    printf 'Creating one user-local RepoPrompt CE self-signed code-signing identity. macOS may ask for confirmation when its trust policy is installed.\n'
    cat > "$TMP_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = distinguished_name
x509_extensions = codesign_extensions
prompt = no

[distinguished_name]
CN = $LOCAL_SELF_SIGNED_CERTIFICATE_NAME
O = RepoPrompt CE Local
OU = Local Build

[codesign_extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF
    openssl req -new -newkey rsa:2048 -x509 -sha256 -days "$LOCAL_CERTIFICATE_DAYS" -nodes \
        -config "$TMP_DIR/openssl.cnf" \
        -out "$CERTIFICATE_PEM" \
        -keyout "$TMP_DIR/repoprompt-ce-local-signing-key.pem"
    local -a pkcs12_args=(-export)
    if { openssl pkcs12 -help 2>&1 || true; } | grep -q -- '-legacy'; then
        pkcs12_args+=(-legacy)
    fi
    openssl pkcs12 "${pkcs12_args[@]}" \
        -out "$TMP_DIR/repoprompt-ce-local-signing.p12" \
        -inkey "$TMP_DIR/repoprompt-ce-local-signing-key.pem" \
        -in "$CERTIFICATE_PEM" \
        -name "$LOCAL_SELF_SIGNED_CERTIFICATE_NAME" \
        -passout "pass:$password"
    security import "$TMP_DIR/repoprompt-ce-local-signing.p12" \
        -k "$LOGIN_KEYCHAIN" \
        -P "$password" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
    security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_PEM"
}

rollback_installed_app() {
    rm -rf "$LOCAL_PRODUCTION_APP"
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        mv "$BACKUP_APP" "$LOCAL_PRODUCTION_APP"
        BACKUP_APP=""
    fi
}

rollback_registry() {
    if (( REGISTRY_EXISTED )); then
        mv "$REGISTRY_BACKUP_PATH" "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
    else
        rm -f "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
    fi
}

[[ "${CONFIRM_LOCAL_PRODUCTION_INSTALL:-}" == "1" ]] ||
    fail "Set CONFIRM_LOCAL_PRODUCTION_INSTALL=1 to build and replace the local production app in $LOCAL_PRODUCTION_INSTALL_DIR."

for command in codesign ditto openssl plutil python3 security shasum swift; do
    require_command "$command"
done
[[ -f "$LOCAL_SIGNING_IDENTITY_TOOL" ]] || fail "Missing local signing identity tool: $LOCAL_SIGNING_IDENTITY_TOOL"

LOGIN_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
[[ -n "$LOGIN_KEYCHAIN" && -f "$LOGIN_KEYCHAIN" ]] || fail "Could not resolve the user's default login keychain."

TMP_DIR="$(mktemp -d)"
mkdir -p "$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")"
chmod 700 "$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")"
REGISTRY_LOCK_CANDIDATE="$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH.lock"
mkdir "$REGISTRY_LOCK_CANDIDATE" 2>/dev/null || fail "Another local production install is active, or a stale lock must be inspected: $REGISTRY_LOCK_CANDIDATE"
REGISTRY_LOCK_DIR="$REGISTRY_LOCK_CANDIDATE"
chmod 700 "$REGISTRY_LOCK_DIR"
printf '%s\n' "$$" > "$REGISTRY_LOCK_DIR/pid"
chmod 600 "$REGISTRY_LOCK_DIR/pid"
REGISTRY_BACKUP_PATH="$TMP_DIR/local-signing-identity-registry.backup"
CERTIFICATE_PEM="$TMP_DIR/repoprompt-ce-local-signing.pem"
INVENTORY_BEFORE="$TMP_DIR/identity-inventory-before.json"
INVENTORY_AFTER="$TMP_DIR/identity-inventory-after.json"
PLAN_PATH="$TMP_DIR/identity-plan.json"
SELECTED_CANDIDATE_PATH="$TMP_DIR/selected-candidate.json"

inventory_local_identities "$INVENTORY_BEFORE"
PLAN_ARGS=(
    "$LOCAL_SIGNING_IDENTITY_TOOL" plan
    --inventory "$INVENTORY_BEFORE"
    --registry "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
)
[[ -z "$LOCAL_SIGNING_IDENTITY_SHA256" ]] || PLAN_ARGS+=(--select "$LOCAL_SIGNING_IDENTITY_SHA256")
if [[ "$ROTATE_LOCAL_SIGNING_IDENTITY" == "1" || "$ROTATE_LOCAL_SIGNING_IDENTITY" == "true" ]]; then
    PLAN_ARGS+=(--rotate)
fi
python3 "${PLAN_ARGS[@]}" > "$PLAN_PATH"

IDENTITY_ACTION="$(json_field "$PLAN_PATH" action)"
LOCAL_SIGNING_SERVICE_GENERATION="$(json_field "$PLAN_PATH" serviceGeneration)"
REGISTRY_NEEDS_WRITE="$(json_field "$PLAN_PATH" registryNeedsWrite)"

if [[ "$IDENTITY_ACTION" == "mint" ]]; then
    if [[ "$ROTATE_LOCAL_SIGNING_IDENTITY" == "1" || "$ROTATE_LOCAL_SIGNING_IDENTITY" == "true" ]]; then
        printf 'WARNING: Rotating the local signing identity makes secrets in the prior local secure-storage generation inaccessible to the new app.\n' >&2
        printf 'WARNING: The prior certificate and Keychain service are preserved for rollback; values are not copied automatically.\n' >&2
    fi
    mint_local_identity
    inventory_local_identities "$INVENTORY_AFTER"
    python3 "$LOCAL_SIGNING_IDENTITY_TOOL" select-new \
        --before "$INVENTORY_BEFORE" \
        --after "$INVENTORY_AFTER" > "$SELECTED_CANDIDATE_PATH"
else
    python3 - "$PLAN_PATH" "$SELECTED_CANDIDATE_PATH" <<'PY'
import json
import sys

plan = json.loads(open(sys.argv[1], encoding="utf-8").read())
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(plan["candidate"], handle)
PY
    if [[ "$IDENTITY_ACTION" == "rotate" ]]; then
        printf 'WARNING: Rotating the local signing identity makes secrets in the prior local secure-storage generation inaccessible to the new app.\n' >&2
        printf 'WARNING: The prior certificate and Keychain service are preserved for rollback; values are not copied automatically.\n' >&2
    fi
fi

SIGN_IDENTITY="$(json_field "$SELECTED_CANDIDATE_PATH" sha1)"
SELECTED_CERTIFICATE_SHA256="$(json_field "$SELECTED_CANDIDATE_PATH" sha256)"
LOCAL_SIGNING_REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGN_IDENTITY\""
printf 'Local signing identity action: %s\n' "$IDENTITY_ACTION"
printf 'Selected local certificate SHA-256: %s\n' "$SELECTED_CERTIFICATE_SHA256"
printf 'Selected local secure-storage generation: v%s\n' "$LOCAL_SIGNING_SERVICE_GENERATION"

LOCAL_SELF_SIGNED_RELEASE=1 \
    LOCAL_SIGNING_CERTIFICATE_SHA1="$SIGN_IDENTITY" \
    LOCAL_SIGNING_CERTIFICATE_SHA256="$SELECTED_CERTIFICATE_SHA256" \
    LOCAL_SIGNING_SERVICE_GENERATION="$LOCAL_SIGNING_SERVICE_GENERATION" \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    "$ROOT_DIR/Scripts/package_app.sh" release

BUILD_DIR="$(swift build -c release --show-bin-path)"
SOURCE_APP="$BUILD_DIR/$APP_NAME.app"
[[ -d "$SOURCE_APP" ]] || fail "Missing packaged local production app: $SOURCE_APP"
[[ "$(plutil -extract RepoPromptSigningMode raw "$SOURCE_APP/Contents/Info.plist")" == "local-self-signed" ]] ||
    fail "Packaged app is missing the local self-signed signing-mode marker."
[[ "$(plutil -extract RepoPromptLocalSigningCertificateSHA256 raw "$SOURCE_APP/Contents/Info.plist")" == "$SELECTED_CERTIFICATE_SHA256" ]] ||
    fail "Packaged app local signing fingerprint metadata does not match the selected identity."
[[ "$(plutil -extract RepoPromptLocalSecureStorageGeneration raw "$SOURCE_APP/Contents/Info.plist")" == "$LOCAL_SIGNING_SERVICE_GENERATION" ]] ||
    fail "Packaged app local secure-storage generation metadata does not match the registry plan."
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$SOURCE_APP"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$SOURCE_APP" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$DESIGNATED_REQUIREMENT" ]] || fail "Could not extract the packaged app designated requirement."
grep -F -i -- "$SIGN_IDENTITY" <<< "$DESIGNATED_REQUIREMENT" >/dev/null ||
    fail "Packaged app designated requirement is not pinned to the selected certificate."
printf 'Packaged designated requirement: %s\n' "$DESIGNATED_REQUIREMENT"

if pgrep -f "$LOCAL_PRODUCTION_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    fail "Quit $DISPLAY_NAME before replacing $LOCAL_PRODUCTION_APP."
fi

mkdir -p "$LOCAL_PRODUCTION_INSTALL_DIR"
STAGED_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.installing.XXXXXX")"
STAGED_APP="$STAGED_DIR/$DISPLAY_NAME.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$STAGED_APP"
printf 'Installing fingerprint %s with designated requirement: %s\n' "$SELECTED_CERTIFICATE_SHA256" "$DESIGNATED_REQUIREMENT"
if [[ -e "$LOCAL_PRODUCTION_APP" ]]; then
    BACKUP_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.backup.XXXXXX")"
    BACKUP_APP="$BACKUP_DIR/$DISPLAY_NAME.app"
    mv "$LOCAL_PRODUCTION_APP" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$LOCAL_PRODUCTION_APP"
STAGED_APP=""
rmdir "$STAGED_DIR"
STAGED_DIR=""

if [[ "$REGISTRY_NEEDS_WRITE" == "1" ]]; then
    if [[ -e "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" ]]; then
        cp -p "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" "$REGISTRY_BACKUP_PATH"
        REGISTRY_EXISTED=1
    fi
    if ! python3 "$LOCAL_SIGNING_IDENTITY_TOOL" write-registry \
        --path "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" \
        --certificate-name "$LOCAL_SELF_SIGNED_CERTIFICATE_NAME" \
        --fingerprint "$SELECTED_CERTIFICATE_SHA256" \
        --generation "$LOCAL_SIGNING_SERVICE_GENERATION" >/dev/null
    then
        rollback_installed_app
        rollback_registry
        fail "Could not atomically update the local signing identity registry; restored the prior app and registry."
    fi
fi
python3 "$LOCAL_SIGNING_IDENTITY_TOOL" read-registry --path "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" >/dev/null || {
    rollback_installed_app
    if [[ "$REGISTRY_NEEDS_WRITE" == "1" ]]; then
        rollback_registry
    fi
    fail "Installed app continuity registry could not be verified; restored the prior app and registry."
}

if [[ -n "$BACKUP_APP" ]]; then
    rm -rf "$BACKUP_APP"
    rmdir "$BACKUP_DIR"
    BACKUP_APP=""
    BACKUP_DIR=""
fi

printf 'Installed local self-signed production app: %s\n' "$LOCAL_PRODUCTION_APP"
printf 'Registered local signing fingerprint: %s\n' "$SELECTED_CERTIFICATE_SHA256"
printf 'Local secure-storage service generation: v%s\n' "$LOCAL_SIGNING_SERVICE_GENERATION"
printf 'This app is local-only, not notarized, and must not be distributed or uploaded to GitHub Releases.\n'
