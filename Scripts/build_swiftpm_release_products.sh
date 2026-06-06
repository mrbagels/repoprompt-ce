#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_WITHOUT_GITHUB_TOKENS="${REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS:-$SCRIPT_DIR/run_without_github_tokens.sh}"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/public-release-products/release}"
SCRATCH_ROOT="${REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT:-$ROOT_DIR/.build/public-release-swiftpm}"
LIPO="${LIPO:-lipo}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

normalized_arches() {
    "$LIPO" -archs "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

require_exact_arch() {
    local path="$1"
    local expected="$2"
    [[ -f "$path" ]] || fail "missing SwiftPM product: $path"
    local actual
    actual="$(normalized_arches "$path")"
    [[ "$actual" == "$expected" ]] ||
        fail "unexpected architecture set for $path: expected $expected, got ${actual:-<none>}"
}

[[ -x "$RUN_WITHOUT_GITHUB_TOKENS" ]] || fail "missing token-scrubbing SwiftPM wrapper: $RUN_WITHOUT_GITHUB_TOKENS"
[[ -x "$SCRIPT_DIR/patch_keyboard_shortcuts_resource_lookup.sh" ]] || fail "missing KeyboardShortcuts resource patch helper"
[[ -x "$SCRIPT_DIR/compare_swiftpm_release_resources.py" ]] || fail "missing resource comparator"
command -v "$LIPO" >/dev/null 2>&1 || fail "missing lipo command: $LIPO"
command -v ditto >/dev/null 2>&1 || fail "missing ditto"

mkdir -p "$SCRATCH_ROOT" "$(dirname "$OUTPUT_DIR")"
if [[ "${REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS:-0}" == "1" ]]; then
    run rm -rf "$SCRATCH_ROOT"
    run mkdir -p "$SCRATCH_ROOT"
fi

ARM64_BIN_DIR=""
X86_64_BIN_DIR=""
for arch in arm64 x86_64; do
    scratch="$SCRATCH_ROOT/$arch"
    run env \
        REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS="$RUN_WITHOUT_GITHUB_TOKENS" \
        REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch" \
        "$SCRIPT_DIR/patch_keyboard_shortcuts_resource_lookup.sh" "$ROOT_DIR"
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build \
        -c release \
        --arch "$arch" \
        --scratch-path "$scratch" \
        --product RepoPrompt
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build \
        -c release \
        --arch "$arch" \
        --scratch-path "$scratch" \
        --product repoprompt-mcp
    printf '+ %q ' "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path
    printf '\n'
    bin_dir="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)"
    if [[ "$arch" == "arm64" ]]; then
        ARM64_BIN_DIR="$bin_dir"
    else
        X86_64_BIN_DIR="$bin_dir"
    fi
    require_exact_arch "$bin_dir/RepoPrompt" "$arch"
    require_exact_arch "$bin_dir/repoprompt-mcp" "$arch"
done

run "$SCRIPT_DIR/compare_swiftpm_release_resources.py" "$ARM64_BIN_DIR" "$X86_64_BIN_DIR"

staged_output="$(mktemp -d "$(dirname "$OUTPUT_DIR")/.public-release-products.XXXXXX")"
cleanup() {
    rm -rf "$staged_output"
}
trap cleanup EXIT

run "$LIPO" -create \
    "$ARM64_BIN_DIR/RepoPrompt" \
    "$X86_64_BIN_DIR/RepoPrompt" \
    -output "$staged_output/RepoPrompt"
run "$LIPO" -create \
    "$ARM64_BIN_DIR/repoprompt-mcp" \
    "$X86_64_BIN_DIR/repoprompt-mcp" \
    -output "$staged_output/repoprompt-mcp"
run chmod +x "$staged_output/RepoPrompt" "$staged_output/repoprompt-mcp"
require_exact_arch "$staged_output/RepoPrompt" "arm64,x86_64"
require_exact_arch "$staged_output/repoprompt-mcp" "arm64,x86_64"

for resource in "$ARM64_BIN_DIR"/*.bundle "$ARM64_BIN_DIR/Sparkle.framework"; do
    [[ -e "$resource" ]] || continue
    run ditto "$resource" "$staged_output/$(basename "$resource")"
done

run rm -rf "$OUTPUT_DIR"
run mv "$staged_output" "$OUTPUT_DIR"
trap - EXIT
printf 'OK: universal SwiftPM release products created at %s\n' "$OUTPUT_DIR"
