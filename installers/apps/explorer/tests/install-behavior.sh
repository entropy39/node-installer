#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly INSTALLER_DIR=$(dirname "$TEST_DIR")
EXPLORER_INSTALLER_TEST_ROOT=$(mktemp -d)
export EXPLORER_INSTALLER_TEST_ROOT
trap 'rm -rf -- "$EXPLORER_INSTALLER_TEST_ROOT"' EXIT

# shellcheck source=../install-explorer.sh
source "$INSTALLER_DIR/install-explorer.sh"

MODE=
PASSWORD_FILE=
parse_args --install
[[ $MODE == install ]]

if (MODE=; PASSWORD_FILE=; parse_args --install --defer-start) 2>/dev/null; then
    printf 'install mode incorrectly accepted removed --defer-start option\n' >&2
    exit 1
fi

mkdir -p "$(dirname "$BITCOIN_CONF")" "$(dirname "$BITCOIND_PATH")" "$WORK_DIR/release"
printf 'server=1\n' >"$BITCOIN_CONF"
: >"$BITCOIND_PATH"
chmod 0755 "$BITCOIND_PATH"
SELECTED_COMMIT=1111111111111111111111111111111111111111
SYSTEMCTL_CALLS=()
CORE_ACTIVE=no

dpkg-query() { printf 'install ok installed\n'; }
chown() { :; }
ACCOUNT_MODIFIED=no
getent() {
    case "$1:$2" in
        group:explorer) printf 'explorer:x:995:\n' ;;
        passwd:explorer) printf 'explorer:x:995:995::/nonexistent:/usr/sbin/nologin\n' ;;
        *) return 2 ;;
    esac
}
id() { [[ $1 == -gn && $2 == explorer ]] && printf 'explorer\n'; }
groupadd() { ACCOUNT_MODIFIED=yes; }
useradd() { ACCOUNT_MODIFIED=yes; }
ensure_explorer_cache() { :; }
verify_release_tree() { :; }
install_or_verify() { :; }
install_bitcoin_configuration() { :; }
install_ports_configuration() { :; }
a2enmod() { :; }
a2ensite() { :; }
apache2ctl() { :; }
systemctl() {
    if [[ $1 == is-active ]]; then
        [[ ${*: -1} == apache2 || ${*: -1} == apache2.service || $CORE_ACTIVE == yes ]]
        return
    fi
    SYSTEMCTL_CALLS+=("$*")
}
verify_installed_configuration() { :; }
complete_operation() { :; }

for CORE_ACTIVE in no yes; do
    MODE=install
    check_prerequisites
    SYSTEMCTL_CALLS=()
    output_file=$EXPLORER_INSTALLER_TEST_ROOT/output
    commit_install >"$output_file"
    output=$(<"$output_file")
    calls=$(printf '%s\n' "${SYSTEMCTL_CALLS[@]}")
    grep -qx 'daemon-reload' <<<"$calls"
    grep -qx 'reload apache2.service' <<<"$calls"
    grep -qx 'enable explorer.service' <<<"$calls"
    ! grep -Eq '(^| )(start|stop|restart)( |$)|--now' <<<"$calls"
    if [[ $CORE_ACTIVE == yes ]]; then
        grep -Fq 'must be restarted' <<<"$output"
    else
        grep -Fq 'will take effect when it next starts' <<<"$output"
    fi
done
[[ $ACCOUNT_MODIFIED == no ]]

# Update prerequisites also accept a stopped Bitcoin Core instance.
MODE=update
CORE_ACTIVE=no
check_prerequisites

# An interrupted initial installation resumes through the same non-starting
# commit path, regardless of whether Core happens to be running.
load_common_marker() {
    SELECTED_TAG=v1.0.0-entropy39.1
    SELECTED_COMMIT=1111111111111111111111111111111111111111
}
marker_value() {
    case $1 in
        phase) printf 'committing\n' ;;
        port_added) printf 'no\n' ;;
        *) return 1 ;;
    esac
}
verify_staged_file() { :; }
prepare_keyring() { :; }
verify_tag() { :; }
stat() { printf 'root:root:700\n'; }

for CORE_ACTIVE in no yes; do
    mkdir -p "$WORK_DIR"
    SYSTEMCTL_CALLS=()
    recover_install >"$EXPLORER_INSTALLER_TEST_ROOT/recovery-output"
    calls=$(printf '%s\n' "${SYSTEMCTL_CALLS[@]}")
    grep -qx 'enable explorer.service' <<<"$calls"
    ! grep -Eq '(^| )(start|stop|restart)( |$)|--now' <<<"$calls"
done

printf 'install behavior tests passed\n'
