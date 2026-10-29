#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly INSTALLER_DIR=$(dirname "$TEST_DIR")
EXPLORER_INSTALLER_TEST_ROOT=$(mktemp -d)
export EXPLORER_INSTALLER_TEST_ROOT
trap 'rm -rf -- "$EXPLORER_INSTALLER_TEST_ROOT"' EXIT

# shellcheck source=../install-explorer.sh
source "$INSTALLER_DIR/install-explorer.sh"

readonly OLD_TEST_TAG=v1.0.0-entropy39.1
readonly NEW_TEST_TAG=v1.1.0-entropy39.1
readonly OLD_TEST_COMMIT=1111111111111111111111111111111111111111
readonly NEW_TEST_COMMIT=2222222222222222222222222222222222222222

OLD_STARTS=yes
NEW_STARTS=yes
SERVICE_ACTIVE=yes
SYSTEMCTL_CALLS=(sentinel)

chown() { :; }
prepare_keyring() { :; }
verify_tag() { :; }
git() {
    local repo revision
    if [[ $1 == -C ]]; then
        repo=$2
        shift 2
    fi
    case $1 in
        rev-parse)
            revision=$2
            if [[ $revision == HEAD ]]; then
                sed -n '1p' "$repo/commit"
            else
                sed -n '1p' "$repo/tag-commit"
            fi
            ;;
        fsck|diff) return 0 ;;
        status) return 0 ;;
        *) return 0 ;;
    esac
}
release_matches_commit() {
    [[ -f $1/commit && $(<"$1/commit") == "$2" ]]
}
verify_release_tree() {
    release_matches_commit "$1" "$2" || die "test release verification failed"
}
verify_running_installation() {
    systemctl is-active --quiet explorer.service && wait_for_explorer
}
verify_explorer_cache() { :; }
systemctl() {
    local action=$1
    SYSTEMCTL_CALLS+=("$*")
    case $action in
        stop) SERVICE_ACTIVE=no; return 0 ;;
        daemon-reload|reload|enable) return 0 ;;
        start|restart)
            service_can_start || return 1
            SERVICE_ACTIVE=yes
            ;;
        is-active)
            [[ $SERVICE_ACTIVE == yes ]] && service_can_start
            ;;
        is-enabled) return 0 ;;
        *) return 0 ;;
    esac
}
wait_for_explorer() { service_can_start; }
service_can_start() {
    if release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"; then
        [[ $OLD_STARTS == yes ]]
    elif release_matches_commit "$INSTALL_DIR" "$NEW_TEST_COMMIT"; then
        [[ $NEW_STARTS == yes ]]
    else
        return 1
    fi
}
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

write_marker() {
    local mode=$1 phase=$2 temporary=${MARKER}.new
    mkdir -p "$STATE_DIR"
    {
        printf 'mode=%s\nphase=%s\ntag=%s\ncommit=%s\n' \
            "$mode" "$phase" "$SELECTED_TAG" "$SELECTED_COMMIT"
        [[ -z ${OLD_TAG:-} ]] || printf 'old_tag=%s\n' "$OLD_TAG"
        [[ -z ${OLD_COMMIT:-} ]] || printf 'old_commit=%s\n' "$OLD_COMMIT"
        [[ $mode != update ]] || printf 'explorer_was_active=%s\n' "$EXPLORER_WAS_ACTIVE"
    } >"$temporary"
    mv -f -- "$temporary" "$MARKER"
}

write_release_records() {
    printf '%s\n' "$1" >"$TAG_RECORD"
    printf '%s\n' "$2" >"$COMMIT_RECORD"
}

make_release() {
    mkdir -p "$1/.git"
    printf '%s\n' "$2" >"$1/commit"
    printf '%s\n' "$2" >"$1/tag-commit"
}

reset_case() {
    rm -rf -- "$INSTALL_DIR" "$UPDATE_BACKUP" "$WORK_DIR" "$STATE_DIR" "$ENV_FILE" \
        "$SERVICE_FILE" "$APACHE_SITE" "$APACHE_PORTS" "$BITCOIN_CONF" "$CACHE_DIR"
    mkdir -p "$WORK_DIR" "$(dirname "$ENV_FILE")"
    printf 'rpc credential sentinel\n' >"$ENV_FILE"
    printf 'service sentinel\n' >"$SERVICE_FILE"
    printf 'apache sentinel\n' >"$APACHE_SITE"
    printf 'ports sentinel\n' >"$APACHE_PORTS"
    printf 'bitcoin credential sentinel\n' >"$BITCOIN_CONF"
    cp "$ENV_FILE" "$EXPLORER_INSTALLER_TEST_ROOT/env.expected"
    cp "$SERVICE_FILE" "$EXPLORER_INSTALLER_TEST_ROOT/service.expected"
    cp "$APACHE_SITE" "$EXPLORER_INSTALLER_TEST_ROOT/apache.expected"
    cp "$APACHE_PORTS" "$EXPLORER_INSTALLER_TEST_ROOT/ports.expected"
    cp "$BITCOIN_CONF" "$EXPLORER_INSTALLER_TEST_ROOT/bitcoin.expected"
    SELECTED_TAG=$NEW_TEST_TAG
    SELECTED_COMMIT=$NEW_TEST_COMMIT
    OLD_TAG=$OLD_TEST_TAG
    OLD_COMMIT=$OLD_TEST_COMMIT
    MODE=update
    FAILURE_ARMED=yes
    OLD_STARTS=yes
    NEW_STARTS=yes
    SERVICE_ACTIVE=yes
    EXPLORER_WAS_ACTIVE=yes
    SYSTEMCTL_CALLS=(sentinel)
}

assert_configuration_unchanged() {
    cmp -s "$ENV_FILE" "$EXPLORER_INSTALLER_TEST_ROOT/env.expected"
    cmp -s "$SERVICE_FILE" "$EXPLORER_INSTALLER_TEST_ROOT/service.expected"
    cmp -s "$APACHE_SITE" "$EXPLORER_INSTALLER_TEST_ROOT/apache.expected"
    cmp -s "$APACHE_PORTS" "$EXPLORER_INSTALLER_TEST_ROOT/ports.expected"
    cmp -s "$BITCOIN_CONF" "$EXPLORER_INSTALLER_TEST_ROOT/bitcoin.expected"
}

assert_successful_update() {
    release_matches_commit "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    [[ ! -e $UPDATE_BACKUP && ! -e $WORK_DIR && ! -e $MARKER ]]
    [[ $(<"$TAG_RECORD") == "$NEW_TEST_TAG" ]]
    [[ $(<"$COMMIT_RECORD") == "$NEW_TEST_COMMIT" ]]
    assert_configuration_unchanged
}

test_prepared_recovery() {
    reset_case
    make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    make_release "$WORK_DIR/release" "$NEW_TEST_COMMIT"
    write_marker update prepared
    recover_update
    assert_successful_update
}

test_prepared_after_old_move() {
    reset_case
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$WORK_DIR/release" "$NEW_TEST_COMMIT"
    write_marker update prepared
    recover_update
    assert_successful_update
}

test_swapped_before_new_move() {
    reset_case
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$WORK_DIR/release" "$NEW_TEST_COMMIT"
    write_marker update swapped
    recover_update
    assert_successful_update
}

test_swapped_after_new_move() {
    reset_case
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker update swapped
    recover_update
    assert_successful_update
}

test_running_update() {
    reset_case
    make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    make_release "$WORK_DIR/release" "$NEW_TEST_COMMIT"
    write_marker update prepared
    commit_update
    assert_successful_update
    [[ $SERVICE_ACTIVE == yes ]]
    printf '%s\n' "${SYSTEMCTL_CALLS[@]}" | grep -q '^stop explorer.service$'
    printf '%s\n' "${SYSTEMCTL_CALLS[@]}" | grep -q '^start explorer.service --job-mode=ignore-dependencies$'
}

test_stopped_update() {
    reset_case
    SERVICE_ACTIVE=no
    EXPLORER_WAS_ACTIVE=no
    make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    make_release "$WORK_DIR/release" "$NEW_TEST_COMMIT"
    write_marker update prepared
    commit_update
    assert_successful_update
    [[ $SERVICE_ACTIVE == no ]]
    ! printf '%s\n' "${SYSTEMCTL_CALLS[@]}" | grep -Eq '^(start|stop|restart) explorer.service'
}

test_stopped_prepared_recovery() {
    reset_case
    SERVICE_ACTIVE=no
    EXPLORER_WAS_ACTIVE=no
    make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    make_release "$WORK_DIR/release" "$NEW_TEST_COMMIT"
    write_marker update prepared
    recover_update
    assert_successful_update
    [[ $SERVICE_ACTIVE == no ]]
}

test_stopped_swapped_recovery() {
    reset_case
    SERVICE_ACTIVE=no
    EXPLORER_WAS_ACTIVE=no
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker update swapped
    recover_update
    assert_successful_update
    [[ $SERVICE_ACTIVE == no ]]
}

test_successful_rollback() {
    reset_case
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker update swapped
    rollback_update
    release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    [[ ! -e $UPDATE_BACKUP && ! -e $WORK_DIR && ! -e $MARKER ]]
    [[ $(<"$TAG_RECORD") == "$OLD_TEST_TAG" ]]
    assert_configuration_unchanged
}

test_stopped_successful_rollback() {
    reset_case
    SERVICE_ACTIVE=no
    EXPLORER_WAS_ACTIVE=no
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker update swapped
    rollback_update
    release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    [[ $SERVICE_ACTIVE == no ]]
    [[ ! -e $UPDATE_BACKUP && ! -e $WORK_DIR && ! -e $MARKER ]]
    assert_configuration_unchanged
}

test_failed_rollback_preserves_releases() {
    reset_case
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker update swapped
    OLD_STARTS=no
    if rollback_update; then
        return 1
    fi
    [[ $ROLLBACK_RESULT == failed ]]
    release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    release_matches_commit "$WORK_DIR/failed-release" "$NEW_TEST_COMMIT"
    [[ ! -e $UPDATE_BACKUP && -f $MARKER ]]
    [[ $(marker_value phase) == rolling-back ]]
    assert_configuration_unchanged
}

test_failed_new_startup_restores_old_release() {
    reset_case
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker update swapped
    NEW_STARTS=no
    if (recover_update); then
        return 1
    fi
    release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    [[ ! -e $UPDATE_BACKUP && ! -e $WORK_DIR && ! -e $MARKER ]]
    [[ $(<"$TAG_RECORD") == "$OLD_TEST_TAG" ]]
    assert_configuration_unchanged
}

test_rollback_power_layouts() {
    local layout
    for layout in before-first-move between-moves after-second-move; do
        reset_case
        case $layout in
            before-first-move)
                make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
                make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
                ;;
            between-moves)
                make_release "$WORK_DIR/failed-release" "$NEW_TEST_COMMIT"
                make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
                ;;
            after-second-move)
                make_release "$WORK_DIR/failed-release" "$NEW_TEST_COMMIT"
                make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
                ;;
        esac
        write_marker update rolling-back
        recover_update
        release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
        [[ ! -e $MARKER && ! -e $WORK_DIR && ! -e $UPDATE_BACKUP ]]
        assert_configuration_unchanged
    done
}

test_complete_update_cleanup() {
    reset_case
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    make_release "$UPDATE_BACKUP" "$OLD_TEST_COMMIT"
    printf '%s\n' "$NEW_TEST_TAG" >"$TAG_RECORD"
    printf '%s\n' "$OLD_TEST_COMMIT" >"$COMMIT_RECORD"
    rm -rf -- "$WORK_DIR"
    OLD_STARTS=no
    NEW_STARTS=no
    SERVICE_ACTIVE=no
    EXPLORER_WAS_ACTIVE=no
    write_marker update complete
    recover_update
    assert_successful_update
}

test_complete_fresh_install_cleanup() {
    reset_case
    MODE=install
    make_release "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    write_marker install complete
    {
        printf 'env_sha256=%s\n' "$(sha256 "$ENV_FILE")"
        printf 'bitcoin_sha256=%s\n' "$(sha256 "$BITCOIN_CONF")"
        printf 'service_sha256=%s\n' "$(sha256 "$SERVICE_FILE")"
        printf 'apache_sha256=%s\n' "$(sha256 "$APACHE_SITE")"
        printf 'ports_sha256=%s\n' "$(sha256 "$APACHE_PORTS")"
    } >>"$MARKER"
    rm -rf -- "$WORK_DIR"
    OLD_STARTS=no
    NEW_STARTS=no
    SERVICE_ACTIVE=no
    recover_install
    release_matches_commit "$INSTALL_DIR" "$NEW_TEST_COMMIT"
    [[ ! -e $MARKER ]]
    assert_configuration_unchanged
}

test_rolled_back_cleanup_without_services_or_staging() {
    reset_case
    make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    printf '%s\n' "$NEW_TEST_TAG" >"$TAG_RECORD"
    printf '%s\n' "$NEW_TEST_COMMIT" >"$COMMIT_RECORD"
    rm -rf -- "$WORK_DIR" "$UPDATE_BACKUP"
    OLD_STARTS=no
    NEW_STARTS=no
    SERVICE_ACTIVE=no
    EXPLORER_WAS_ACTIVE=no
    write_marker update rolled-back
    recover_update
    release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    [[ ! -e $MARKER ]]
    [[ $(<"$TAG_RECORD") == "$OLD_TEST_TAG" ]]
    [[ $(<"$COMMIT_RECORD") == "$OLD_TEST_COMMIT" ]]
    assert_configuration_unchanged
}

test_rolled_back_cleanup_rejects_wrong_tag() {
    reset_case
    make_release "$INSTALL_DIR" "$OLD_TEST_COMMIT"
    printf '%s\n' "$NEW_TEST_COMMIT" >"$INSTALL_DIR/tag-commit"
    write_marker update rolled-back
    rm -rf -- "$WORK_DIR" "$UPDATE_BACKUP"
    if (recover_update); then
        return 1
    fi
    [[ -f $MARKER ]]
    release_matches_commit "$INSTALL_DIR" "$OLD_TEST_COMMIT"
}

test_terminal_dispatch_skips_service_prerequisites() {
    reset_case
    write_marker update complete
    TERMINAL_COMMANDS_CHECKED=no
    RECOVERY_DISPATCHED=no
    check_terminal_recovery_commands() { TERMINAL_COMMANDS_CHECKED=yes; }
    check_platform() { return 1; }
    check_templates() { return 1; }
    check_commands() { return 1; }
    check_prerequisites() { return 1; }
    recover_if_needed() { RECOVERY_DISPATCHED=yes; }
    recover_existing_operation
    [[ $TERMINAL_COMMANDS_CHECKED == yes && $RECOVERY_DISPATCHED == yes ]]
}

test_prepared_recovery
test_prepared_after_old_move
test_swapped_before_new_move
test_swapped_after_new_move
test_running_update
test_stopped_update
test_stopped_prepared_recovery
test_stopped_swapped_recovery
test_successful_rollback
test_stopped_successful_rollback
test_failed_rollback_preserves_releases
test_failed_new_startup_restores_old_release
test_rollback_power_layouts
test_complete_update_cleanup
test_complete_fresh_install_cleanup
test_rolled_back_cleanup_without_services_or_staging
test_rolled_back_cleanup_rejects_wrong_tag
test_terminal_dispatch_skips_service_prerequisites

! grep -Eq 'systemctl (start|stop|restart).*bitcoind|systemctl .*bitcoind.*(start|stop|restart)' "$INSTALLER_DIR/install-explorer.sh"

printf 'recovery and rollback tests passed\n'
