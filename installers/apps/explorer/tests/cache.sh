#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly INSTALLER_DIR=$(dirname "$TEST_DIR")
EXPLORER_INSTALLER_TEST_ROOT=$(mktemp -d)
export EXPLORER_INSTALLER_TEST_ROOT
trap 'rm -rf -- "$EXPLORER_INSTALLER_TEST_ROOT"' EXIT

# shellcheck source=../install-explorer.sh
source "$INSTALLER_DIR/install-explorer.sh"

install() {
    local target=${!#}
    mkdir -p "$target"
    chmod 0750 "$target"
}
stat() {
    [[ $* == *"$CACHE_DIR"* ]] && printf 'explorer:explorer:750\n'
}
runuser() {
    [[ $1 == -u && $2 == explorer && $3 == -- && $4 == test && $5 == -w && $6 == "$CACHE_DIR" ]]
}

ensure_explorer_cache
verify_explorer_cache
[[ -d $CACHE_DIR ]]
template=$EXPLORER_INSTALLER_TEST_ROOT/btc-rpc-explorer.env
write_environment_template "$template"
grep -Fqx 'BTCEXP_FILESYSTEM_CACHE_DIR=/var/cache/btc-rpc-explorer' "$template"

# Legacy update configuration is preserved and no longer fails solely because
# the newer cache directory is absent.
mkdir -p "$(dirname "$ENV_FILE")"
printf 'BTCEXP_BITCOIND_USER=explorer\n' >"$ENV_FILE"
rm -rf -- "$CACHE_DIR"
verify_update_cache_compatibility
[[ ! -e $CACHE_DIR ]]

# When the managed cache setting is present, update creates and validates it.
printf 'BTCEXP_FILESYSTEM_CACHE_DIR=/var/cache/btc-rpc-explorer\n' >>"$ENV_FILE"
verify_update_cache_compatibility
[[ -d $CACHE_DIR ]]

printf 'Explorer cache tests passed\n'
