#!/usr/bin/env bash

# Optional application metadata is deliberately explicit so adding an
# installer remains auditable. Compatibility is a comma-separated list of
# Bitcoin node modes.
# id|label|description|compatible node modes|installer path|systemd service
APP_CATALOG_ENTRIES=(
    'explorer|BTC RPC Explorer|Web-based Bitcoin blockchain explorer|full,pruned|installers/apps/explorer/install-explorer.sh|explorer.service'
)
APP_IDS=()
for entry in "${APP_CATALOG_ENTRIES[@]}"; do APP_IDS+=("${entry%%|*}"); done

app_field() {
    local wanted=$1 field=$2 entry id label description compatibility installer service
    for entry in "${APP_CATALOG_ENTRIES[@]}"; do
        IFS='|' read -r id label description compatibility installer service <<<"$entry"
        [[ $id == "$wanted" ]] || continue
        case $field in
            label) printf '%s\n' "$label" ;;
            description) printf '%s\n' "$description" ;;
            compatibility) printf '%s\n' "$compatibility" ;;
            installer) printf '%s\n' "$installer" ;;
            service) printf '%s\n' "$service" ;;
            *) return 1 ;;
        esac
        return 0
    done
    return 1
}

app_label() { app_field "$1" label; }
app_description() { app_field "$1" description; }
app_compatibility() { app_field "$1" compatibility; }
app_installer() { app_field "$1" installer; }
app_service() { app_field "$1" service; }

catalog_has_app() {
    local wanted=$1 app
    for app in "${APP_IDS[@]}"; do
        [[ $app != "$wanted" ]] || return 0
    done
    return 1
}

app_supports_mode() {
    local app=$1 mode=$2 compatibility
    catalog_has_app "$app" || return 1
    compatibility=",$(app_compatibility "$app"),"
    [[ $compatibility == *",${mode},"* ]]
}

available_apps_for_mode() {
    local mode=$1 app
    [[ $mode == full || $mode == pruned ]] || return 1
    for app in "${APP_IDS[@]}"; do
        app_supports_mode "$app" "$mode" && printf '%s\n' "$app"
    done
}

validate_app_list() {
    local mode=$1 app seen=" "
    shift
    for app in "$@"; do
        catalog_has_app "$app" || return 1
        app_supports_mode "$app" "$mode" || return 1
        [[ $seen != *" $app "* ]] || return 1
        seen+="$app "
    done
}
