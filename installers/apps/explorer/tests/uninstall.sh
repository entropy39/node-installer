#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly INSTALLER_DIR=$(dirname "$TEST_DIR")
EXPLORER_INSTALLER_TEST_ROOT=$(mktemp -d)
export EXPLORER_INSTALLER_TEST_ROOT
trap 'rm -rf -- "$EXPLORER_INSTALLER_TEST_ROOT"' EXIT

# shellcheck source=../install-explorer.sh
source "$INSTALLER_DIR/install-explorer.sh"

readonly TEST_TAG=v1.0.0-entropy39.1
readonly TEST_COMMIT=1111111111111111111111111111111111111111
SERVICE_ACTIVE=yes
SERVICE_ENABLED=yes
GROUPADD_CALLED=no
USERADD_CALLED=no

chown() { :; }
cp() {
    local arguments=()
    while (($#)); do
        case $1 in --preserve=*) shift ;; *) arguments+=("$1"); shift ;; esac
    done
    /bin/cp "${arguments[@]}"
}
install() {
    local mode=0755 directory=no target= argument
    while (($#)); do
        case $1 in
            -d) directory=yes; shift ;;
            -m) mode=$2; shift 2 ;;
            -o|-g) shift 2 ;;
            *) target=$1; shift ;;
        esac
    done
    [[ $directory == yes ]] || return 1
    mkdir -p "$target"
    chmod "$mode" "$target"
}
stat() {
    local target=${*: -1}
    case $target in
        "$ENV_FILE") printf 'root:explorer:640\n' ;;
        "$CACHE_DIR") printf 'explorer:explorer:750\n' ;;
        "$UNINSTALL_WORK_DIR") printf 'root:root:700\n' ;;
        "$BITCOIN_CONF") printf 'root:bitcoin:640\n' ;;
        *) printf 'root:root:644\n' ;;
    esac
}
git() { return 0; }
release_matches_commit() { [[ -f $1/commit && $(<"$1/commit") == "$2" ]]; }
verify_release_tree() { release_matches_commit "$1" "$2" || die "test release mismatch"; }
systemctl() {
    case $1 in
        disable) SERVICE_ACTIVE=no; SERVICE_ENABLED=no ;;
        is-active)
            [[ ${*: -1} == bitcoind.service ]] && return 1
            [[ ${*: -1} == apache2.service ]] && return 1
            [[ $SERVICE_ACTIVE == yes ]]
            ;;
        is-enabled) [[ $SERVICE_ENABLED == yes ]] ;;
        daemon-reload) : ;;
        *) : ;;
    esac
}
a2dissite() { rm -f -- "$APACHE_ENABLED"; }
apache2ctl() { :; }
atomic_install() { cp "$1" "$2"; chmod "$5" "$2"; }
readlink() {
    if [[ $1 == -m ]]; then
        local link=$2 target
        target=$(/usr/bin/readlink "$link")
        (cd "$(dirname "$link")" && cd "$(dirname "$target")" && printf '%s/%s\n' "$PWD" "$(basename "$target")")
    else
        /usr/bin/readlink "$@"
    fi
}
groupadd() { GROUPADD_CALLED=yes; }
useradd() { USERADD_CALLED=yes; }
id() { [[ $1 == -gn && $2 == explorer ]] && printf 'explorer\n'; }
getent() {
    case "$1:$2" in
        group:explorer) printf 'explorer:x:995:\n' ;;
        passwd:explorer) printf 'explorer:x:995:995::/nonexistent:/usr/sbin/nologin\n' ;;
        *) return 2 ;;
    esac
}

setup_installation() {
    rm -rf -- "$INSTALL_DIR" "$ENV_FILE" "$SERVICE_FILE" "$APACHE_SITE" "$APACHE_ENABLED" \
        "$CACHE_DIR" "$STATE_DIR" "$UPDATE_BACKUP"
    mkdir -p "$INSTALL_DIR/.git" "$(dirname "$ENV_FILE")" "$(dirname "$APACHE_ENABLED")" "$CACHE_DIR" "$STATE_DIR"
    printf '%s\n' "$TEST_COMMIT" >"$INSTALL_DIR/commit"
    write_environment_template "$ENV_FILE"
    sed -i.bak 's/RPC-PASSWORD-HERE/rpc-secret/; s/EXPLORER-PASSWORD-HERE/web-secret/' "$ENV_FILE"
    rm -f -- "$ENV_FILE.bak"
    write_service_template "$SERVICE_FILE"
    write_apache_template "$APACHE_SITE"
    ln -s "$APACHE_SITE" "$APACHE_ENABLED"
    printf 'Listen 80\nListen 4082\n' >"$APACHE_PORTS"
    printf 'server=1\nrpcauth=dashboard:aa$bb\nrpcauth=explorer:cc$dd\nprune=1000\n' >"$BITCOIN_CONF"
    printf '%s\n' "$TEST_TAG" >"$TAG_RECORD"
    printf '%s\n' "$TEST_COMMIT" >"$COMMIT_RECORD"
    printf 'Listen 4082\n' >"$PORT_RECORD"
    SERVICE_ACTIVE=yes
    SERVICE_ENABLED=yes
    MODE=uninstall
    FAILURE_ARMED=no
}

assert_uninstalled() {
    [[ ! -e $INSTALL_DIR && ! -e $ENV_FILE && ! -e $SERVICE_FILE && ! -e $APACHE_SITE ]]
    [[ ! -e $TAG_RECORD && ! -e $COMMIT_RECORD && ! -e $PORT_RECORD && ! -e $MARKER ]]
    [[ $SERVICE_ACTIVE == no && $SERVICE_ENABLED == no ]]
    grep -Fqx 'rpcauth=dashboard:aa$bb' "$BITCOIN_CONF"
    grep -Fqx 'prune=1000' "$BITCOIN_CONF"
    ! grep -q '^rpcauth=explorer:' "$BITCOIN_CONF"
    ! grep -Eq '^[[:space:]]*Listen[[:space:]]+4082([[:space:]]|$)' "$APACHE_PORTS"
}

MODE=
PASSWORD_FILE=
parse_args --uninstall
[[ $MODE == uninstall ]]

# A valid pre-existing dedicated account is reused without modification.
ensure_explorer_account
[[ $GROUPADD_CALLED == no && $USERADD_CALLED == no ]]
if (
    getent() {
        case "$1:$2" in
            group:explorer) printf 'explorer:x:995:\n' ;;
            passwd:explorer) printf 'explorer:x:995:995::/home/explorer:/bin/bash\n' ;;
        esac
    }
    ensure_explorer_account
) 2>/dev/null; then
    printf 'unsafe existing Explorer account was accepted\n' >&2
    exit 1
fi

setup_installation
mkdir -p "$UNKNOWN_EXPLORER_STATE_DIR"
uninstall_explorer
assert_uninstalled
[[ -d $UNKNOWN_EXPLORER_STATE_DIR ]]
GROUPADD_CALLED=no
USERADD_CALLED=no
ensure_explorer_account
[[ $GROUPADD_CALLED == no && $USERADD_CALLED == no ]]

# Repeated uninstall is harmless and does not touch unknown state.
uninstall_explorer
[[ -d $UNKNOWN_EXPLORER_STATE_DIR ]]

# A broken enabled-site link left by partial cleanup is verified and removed.
mkdir -p "$(dirname "$APACHE_ENABLED")"
ln -s "$APACHE_SITE" "$APACHE_ENABLED"
uninstall_explorer
[[ ! -e $APACHE_ENABLED && ! -L $APACHE_ENABLED ]]

# A valid orphaned Explorer RPC entry is removed without changing other lines.
printf 'server=1\nrpcauth=dashboard:aa$bb\nrpcauth=explorer:cc$dd\nprune=1000\n' >"$BITCOIN_CONF"
uninstall_explorer
! grep -q '^rpcauth=explorer:' "$BITCOIN_CONF"
grep -Fqx 'rpcauth=dashboard:aa$bb' "$BITCOIN_CONF"
grep -Fqx 'prune=1000' "$BITCOIN_CONF"

# Partial removal is accepted when the remaining resources still verify.
setup_installation
rm -rf -- "$INSTALL_DIR" "$SERVICE_FILE" "$CACHE_DIR"
uninstall_explorer
assert_uninstalled

# Interrupted cleanup resumes from its verified staging data.
setup_installation
install -d -m 0700 "$UNINSTALL_WORK_DIR"
stage_uninstall
set_uninstall_phase cleaning
rm -f -- "$ENV_FILE"
apply_uninstall_configuration
recover_uninstall
assert_uninstalled

# Unexpected cache data is retained rather than deleted.
setup_installation
printf 'user cache data\n' >"$CACHE_DIR/retained"
uninstall_explorer
assert_uninstalled
[[ -f $CACHE_DIR/retained ]]

printf 'uninstall and reinstall-safety tests passed\n'
