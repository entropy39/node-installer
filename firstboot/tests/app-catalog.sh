#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../app-catalog.sh
source "${TEST_DIR}/../app-catalog.sh"

full_apps=()
pruned_apps=()
while IFS= read -r app; do full_apps+=("$app"); done < <(available_apps_for_mode full)
while IFS= read -r app; do pruned_apps+=("$app"); done < <(available_apps_for_mode pruned)

[[ ${full_apps[*]} == explorer ]]
[[ ${pruned_apps[*]} == explorer ]]
validate_app_list full
validate_app_list full explorer
validate_app_list pruned explorer
! validate_app_list full explorer explorer
! validate_app_list pruned unknown
! available_apps_for_mode invalid >/dev/null

printf 'application catalog tests passed\n'
