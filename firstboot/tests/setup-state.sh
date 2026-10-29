#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../setup
source "$TEST_DIR/../setup"
# shellcheck source=../app-catalog.sh
source "$TEST_DIR/../app-catalog.sh"

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT

[[ $(join_apps) == none ]]
[[ $(join_apps explorer) == explorer ]]

printf 'selected=none\nconfigured=none\nfailed=explorer\n' >"$temporary_dir/state"
SELECTED_APPS=(sentinel)
FAILED_APPS=()
load_app_value "$temporary_dir/state" selected SELECTED_APPS
((${#SELECTED_APPS[@]} == 0))
load_app_value "$temporary_dir/state" failed FAILED_APPS
[[ ${FAILED_APPS[*]} == explorer ]]
validate_app_list pruned explorer
! validate_app_list pruned explorer explorer

grep -Fq '"$BITCOIN_INSTALLER" --no-start' "$TEST_DIR/../setup"

: >"$temporary_dir/empty-selection"
values=()
while IFS= read -r value; do values+=("$value"); done <"$temporary_dir/empty-selection"
((${#values[@]} == 0))

chown() { :; }
install() { :; }
atomic_write_record "$temporary_dir/atomic-record" 0644 'status=complete'
grep -qx 'status=complete' "$temporary_dir/atomic-record"

printf 'setup state tests passed\n'
