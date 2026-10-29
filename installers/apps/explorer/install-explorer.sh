#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly REPOSITORY_URL=https://github.com/entropy39/btc-rpc-explorer.git
readonly KEY_URL=https://github.com/dgnelsonoz.gpg
readonly TRUSTED_FINGERPRINT=FF1D7E574592ACB0CE68FED62536465B3430EEB0
readonly TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+-entropy39\.[0-9]+$'

if [[ ${BASH_SOURCE[0]} != "$0" && -n ${EXPLORER_INSTALLER_TEST_ROOT:-} ]]; then
    readonly INSTALL_DIR=$EXPLORER_INSTALLER_TEST_ROOT/install
    readonly ENV_FILE=$EXPLORER_INSTALLER_TEST_ROOT/etc/btc-rpc-explorer.env
    readonly SERVICE_FILE=$EXPLORER_INSTALLER_TEST_ROOT/etc/explorer.service
    readonly APACHE_SITE=$EXPLORER_INSTALLER_TEST_ROOT/etc/explorer.conf
    readonly APACHE_ENABLED=$EXPLORER_INSTALLER_TEST_ROOT/etc/sites-enabled/explorer.conf
    readonly APACHE_PORTS=$EXPLORER_INSTALLER_TEST_ROOT/etc/ports.conf
    readonly APACHE_CONFIG_DIR=$EXPLORER_INSTALLER_TEST_ROOT/etc
    readonly BITCOIN_CONF=$EXPLORER_INSTALLER_TEST_ROOT/etc/bitcoin.conf
    readonly BITCOIND_PATH=$EXPLORER_INSTALLER_TEST_ROOT/usr/local/bin/bitcoind
    readonly CACHE_DIR=$EXPLORER_INSTALLER_TEST_ROOT/cache
    readonly STATE_DIR=$EXPLORER_INSTALLER_TEST_ROOT/state
    readonly UPDATE_BACKUP=$EXPLORER_INSTALLER_TEST_ROOT/update-backup
else
    readonly INSTALL_DIR=/usr/local/lib/btc-rpc-explorer
    readonly ENV_FILE=/etc/btc-rpc-explorer.env
    readonly SERVICE_FILE=/etc/systemd/system/explorer.service
    readonly APACHE_SITE=/etc/apache2/sites-available/explorer.conf
    readonly APACHE_ENABLED=/etc/apache2/sites-enabled/explorer.conf
    readonly APACHE_PORTS=/etc/apache2/ports.conf
    readonly APACHE_CONFIG_DIR=/etc/apache2
    readonly BITCOIN_CONF=/etc/bitcoin.conf
    readonly BITCOIND_PATH=/usr/local/bin/bitcoind
    readonly CACHE_DIR=/var/cache/btc-rpc-explorer
    readonly STATE_DIR=/var/lib/entropy39-node
    readonly UPDATE_BACKUP=/usr/local/lib/.btc-rpc-explorer-update-backup
fi
readonly WORK_DIR=$STATE_DIR/explorer-install-work
readonly MARKER=$STATE_DIR/explorer-install-incomplete
readonly TAG_RECORD=$STATE_DIR/explorer-installed-tag
readonly COMMIT_RECORD=$STATE_DIR/explorer-installed-commit
readonly PORT_RECORD=$STATE_DIR/explorer-managed-port-4082
readonly UNINSTALL_WORK_DIR=$STATE_DIR/explorer-uninstall-work
readonly UNKNOWN_EXPLORER_STATE_DIR=$STATE_DIR/explorer

MODE=
PASSWORD_FILE=
SELECTED_TAG=
SELECTED_COMMIT=
OLD_TAG=
OLD_COMMIT=
WEB_PASSWORD=
RPCAUTH_LINE=
FAILURE_ARMED=no
ROLLBACK_RESULT=failed
EXPLORER_WAS_ACTIVE=
PORT_WAS_ADDED=no

say() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $PROGRAM --install [--password-file FILE]
  $PROGRAM --update
  $PROGRAM --uninstall

Install, update or uninstall BTC RPC Explorer for Entropy39 Node.

Options:
  --install              Perform a fresh installation
  --update               Update an installation made by this installer
  --uninstall            Safely remove an installation made by this installer
  --password-file FILE   Read the Explorer web password from a root-owned
                         mode-600 file (install mode only)
  --help                 Show this help
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --install|--update|--uninstall)
                [[ -z $MODE ]] || die "Choose exactly one of --install and --update."
                MODE=${1#--}
                shift
                ;;
            --password-file)
                (($# >= 2)) || die "--password-file requires a path."
                PASSWORD_FILE=$2
                shift 2
                ;;
            --help|-h) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)." ;;
        esac
    done
    [[ -n $MODE ]] || die "Choose exactly one of --install and --update."
    [[ $MODE == install || -z $PASSWORD_FILE ]] || die "--password-file is valid only with --install."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This installer must be run as root."
}

acquire_lock() {
    exec 9>/run/lock/entropy39-explorer-install.lock
    flock -n 9 || die "Another Explorer installer operation is already running."
}

check_platform() {
    [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || die "This installer supports Debian 13 only."
    case $(dpkg --print-architecture) in
        amd64|arm64) ;;
        *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
    esac
    [[ -d /run/systemd/system ]] || die "systemd is not running."
}

write_environment_template() {
    cat >"$1" <<'EOF'
BTCEXP_HOST=127.0.0.1
BTCEXP_PORT=3002

BTCEXP_BITCOIND_HOST=127.0.0.1
BTCEXP_BITCOIND_PORT=8332
BTCEXP_BITCOIND_USER=explorer
BTCEXP_BITCOIND_PASS=RPC-PASSWORD-HERE
BTCEXP_BITCOIND_RPC_TIMEOUT=10000
BTCEXP_FILESYSTEM_CACHE_DIR=/var/cache/btc-rpc-explorer

BTCEXP_PRIVACY_MODE=true
BTCEXP_NO_RATES=true
BTCEXP_SLOW_DEVICE_MODE=true

BTCEXP_UI_TIMEZONE=local
BTCEXP_UI_THEME=dark

BTCEXP_BASIC_AUTH_PASSWORD=EXPLORER-PASSWORD-HERE
EOF
}

write_service_template() {
    cat >"$1" <<'EOF'
[Unit]
Description=BTC RPC Explorer
After=network-online.target bitcoind.service
Wants=network-online.target bitcoind.service

[Service]
User=explorer
Group=explorer
WorkingDirectory=/usr/local/lib/btc-rpc-explorer
EnvironmentFile=/etc/btc-rpc-explorer.env
ExecStart=/usr/bin/npm start
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_apache_template() {
    cat >"$1" <<'EOF'
<VirtualHost *:4082>

    ProxyPreserveHost On
    ProxyRequests Off

    ProxyPass        / http://127.0.0.1:3002/
    ProxyPassReverse / http://127.0.0.1:3002/

    ErrorLog  ${APACHE_LOG_DIR}/explorer-error.log
    CustomLog ${APACHE_LOG_DIR}/explorer-access.log combined

</VirtualHost>
EOF
}

check_templates() {
    local directory environment_template
    directory=$(mktemp -d)
    environment_template=$directory/btc-rpc-explorer.env
    write_environment_template "$environment_template"
    write_service_template "$directory/explorer.service"
    write_apache_template "$directory/explorer.conf"
    [[ $(grep -Foc 'RPC-PASSWORD-HERE' "$environment_template") -eq 1 ]] || {
        rm -rf -- "$directory"
        die "The embedded environment template must contain exactly one RPC password placeholder."
    }
    [[ $(grep -Foc 'EXPLORER-PASSWORD-HERE' "$environment_template") -eq 1 ]] || {
        rm -rf -- "$directory"
        die "The embedded environment template must contain exactly one web password placeholder."
    }
    rm -rf -- "$directory"
}

install_dependencies() {
    say "Installing Explorer dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends apache2 ca-certificates curl git gnupg nodejs npm python3
}

check_commands() {
    local command_name
    for command_name in a2enmod a2ensite apache2ctl curl dpkg-query flock getent git gpg groupadd id npm node pgrep python3 readlink runuser sha256sum stat systemctl useradd; do
        require_command "$command_name"
    done
    local node_major
    node_major=$(node --version | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')
    [[ $node_major =~ ^[0-9]+$ && $node_major -ge 18 ]] || die "BTC RPC Explorer requires Node.js 18 or newer."
}

check_prerequisites() {
    [[ -f $BITCOIN_CONF && ! -L $BITCOIN_CONF ]] || die "Bitcoin Core must be installed first: $BITCOIN_CONF is missing or unsafe."
    [[ -x $BITCOIND_PATH ]] || die "Bitcoin Core must be installed first: bitcoind is missing."
    dpkg-query -W -f='${Status}\n' apache2 2>/dev/null | grep -qx 'install ok installed' || \
        die "Apache2 must be installed before Explorer."
}

check_uninstall_commands() {
    local command_name
    for command_name in a2dissite apache2ctl awk cmp find flock git mktemp readlink sha256sum stat systemctl; do require_command "$command_name"; done
}

check_uninstall_prerequisites() {
    [[ -f $BITCOIN_CONF && ! -L $BITCOIN_CONF ]] || die "Bitcoin Core configuration is missing or unsafe: $BITCOIN_CONF"
    [[ -f $APACHE_PORTS && ! -L $APACHE_PORTS ]] || die "Apache ports configuration is missing or unsafe: $APACHE_PORTS"
}

latest_tag() {
    local tags
    tags=$(git ls-remote --tags --refs "$REPOSITORY_URL" | awk '{sub("refs/tags/", "", $2); print $2}' | grep -E "$TAG_PATTERN" || true)
    [[ -n $tags ]] || die "No stable Entropy39 Explorer tags were found."
    printf '%s\n' "$tags" | sort -V | tail -n 1
}

prepare_keyring() {
    local key_file=$WORK_DIR/entropy39-signing-key.asc
    local fingerprint_count
    rm -rf -- "$WORK_DIR/gnupg"
    install -d -o root -g root -m 0700 "$WORK_DIR/gnupg"
    if [[ ! -f $key_file ]]; then
        curl --fail --location --silent --show-error "$KEY_URL" -o "$key_file"
    fi

    mapfile -t key_fingerprints < <(
        GNUPGHOME=$WORK_DIR/gnupg gpg --batch --with-colons --import-options show-only --import "$key_file" 2>/dev/null |
            awk -F: '$1 == "pub" {want=1; next} want && $1 == "fpr" {print $10; want=0}'
    )
    fingerprint_count=${#key_fingerprints[@]}
    [[ $fingerprint_count -eq 1 && ${key_fingerprints[0]} == "$TRUSTED_FINGERPRINT" ]] || \
        die "The downloaded signing key does not match the trusted Entropy39 fingerprint."
    GNUPGHOME=$WORK_DIR/gnupg gpg --batch --import "$key_file" >/dev/null 2>&1
}

verify_tag() {
    local repo=$1 tag=$2 status_file=$WORK_DIR/tag-status
    [[ $tag =~ $TAG_PATTERN ]] || die "Unexpected Explorer tag format: $tag"
    GNUPGHOME=$WORK_DIR/gnupg git -C "$repo" verify-tag --raw "$tag" 2>"$status_file" || \
        die "Explorer tag $tag does not have an acceptable signature."
    grep -Eq "^\[GNUPG:\] VALIDSIG [0-9A-F]+ .* ${TRUSTED_FINGERPRINT}$" "$status_file" || \
        die "Explorer tag $tag was not signed by the trusted Entropy39 primary key."
    if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|KEYREVOKED|KEYEXPIRED|SIGEXPIRED)' "$status_file"; then
        die "Explorer tag $tag has an expired, revoked, invalid, or otherwise unacceptable signature."
    fi
}

prepare_release() {
    local release_dir=$WORK_DIR/release
    SELECTED_TAG=$(latest_tag)
    say "Downloading and verifying BTC RPC Explorer $SELECTED_TAG"
    rm -rf -- "$release_dir"
    git clone --quiet --filter=blob:none --no-checkout "$REPOSITORY_URL" "$release_dir"
    prepare_keyring
    verify_tag "$release_dir" "$SELECTED_TAG"
    SELECTED_COMMIT=$(git -C "$release_dir" rev-parse "$SELECTED_TAG^{commit}")
    [[ $SELECTED_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "Git returned an invalid Explorer commit."
    git -C "$release_dir" checkout --quiet --detach "$SELECTED_COMMIT"
    git -C "$release_dir" fsck --full --no-dangling >/dev/null || die "The Explorer Git data failed its integrity check."
    git -C "$release_dir" diff --quiet "$SELECTED_COMMIT" -- . || die "The Explorer checkout differs from its signed commit."
    [[ -f $release_dir/package.json && -f $release_dir/npm-shrinkwrap.json ]] || \
        die "The signed Explorer release lacks its package metadata or npm shrinkwrap file."
    say "Installing the locked production dependencies in staging"
    npm --prefix "$release_dir" ci --omit=dev --no-audit --no-fund
    # The installer uses a restrictive umask for credentials. Restore normal
    # read/execute permissions on application code before the service uses it.
    chmod -R u=rwX,go=rX "$release_dir"
}

validate_web_password() {
    [[ -n $WEB_PASSWORD ]] || die "The Explorer web password cannot be empty."
}

read_web_password() {
    local confirmation password_mode
    if [[ -n $PASSWORD_FILE ]]; then
        [[ -f $PASSWORD_FILE && ! -L $PASSWORD_FILE ]] || die "The password file must be a regular file, not a symbolic link."
        password_mode=$(stat -c '%U:%G:%a' "$PASSWORD_FILE")
        [[ $password_mode == root:root:600 ]] || die "The password file must be owned by root:root with mode 600."
        [[ $(wc -l <"$PASSWORD_FILE") -le 1 ]] || die "The password file must contain one line."
        IFS= read -r WEB_PASSWORD <"$PASSWORD_FILE" || [[ -n $WEB_PASSWORD ]]
    else
        [[ -t 0 && -t 1 ]] || die "Interactive installation requires a terminal or --password-file."
        read -r -s -p "Set a password for the Explorer: " WEB_PASSWORD
        printf '\n'
        read -r -s -p "Confirm the password for the Explorer: " confirmation
        printf '\n'
        [[ $WEB_PASSWORD == "$confirmation" ]] || die "The Explorer web passwords do not match."
    fi
    validate_web_password
}

active_rpcauth_script() {
    local bitcoind_path version_dir script
    bitcoind_path=$(readlink -f /usr/local/bin/bitcoind)
    version_dir=$(dirname "$(dirname "$bitcoind_path")")
    script=$version_dir/share/rpcauth/rpcauth.py
    [[ -x $script ]] || die "The active Bitcoin Core installation does not contain rpcauth.py."
    printf '%s\n' "$script"
}

write_environment_value() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//\$/\\\$}
    printf '"%s"' "$value"
}

write_environment_file() {
    local template=$1 output=$2 rpc_password=$3 web_password=$4
    local line prefix suffix
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            *RPC-PASSWORD-HERE*)
                prefix=${line%%RPC-PASSWORD-HERE*}
                suffix=${line#*RPC-PASSWORD-HERE}
                printf '%s' "$prefix"
                write_environment_value "$rpc_password"
                printf '%s\n' "$suffix"
                ;;
            *EXPLORER-PASSWORD-HERE*)
                prefix=${line%%EXPLORER-PASSWORD-HERE*}
                suffix=${line#*EXPLORER-PASSWORD-HERE}
                printf '%s' "$prefix"
                write_environment_value "$web_password"
                printf '%s\n' "$suffix"
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$template" >"$output"
}

stage_install_configuration() {
    local environment_template rpc_output rpc_password rpcauth_script
    read_web_password
    grep -q '^rpcauth=explorer:' "$BITCOIN_CONF" && die "Bitcoin Core already has an Explorer rpcauth entry."

    rpcauth_script=$(active_rpcauth_script)
    rpc_output=$WORK_DIR/rpcauth-output
    python3 "$rpcauth_script" explorer >"$rpc_output"
    RPCAUTH_LINE=$(grep '^rpcauth=explorer:' "$rpc_output")
    rpc_password=$(awk '/^Your password:/{getline; print; exit}' "$rpc_output")
    [[ -n $RPCAUTH_LINE && -n $rpc_password ]] || die "rpcauth.py did not produce the expected credentials."

    environment_template=$WORK_DIR/btc-rpc-explorer.env.template
    write_environment_template "$environment_template"
    write_environment_file "$environment_template" \
        "$WORK_DIR/btc-rpc-explorer.env" "$rpc_password" "$WEB_PASSWORD"
    rm -f -- "$environment_template"
    chmod 0600 "$WORK_DIR/btc-rpc-explorer.env"

    cp --preserve=mode,ownership,timestamps "$BITCOIN_CONF" "$WORK_DIR/bitcoin.conf.original"
    cp "$BITCOIN_CONF" "$WORK_DIR/bitcoin.conf"
    printf '\n%s\n' "$RPCAUTH_LINE" >>"$WORK_DIR/bitcoin.conf"
    chmod 0600 "$WORK_DIR/bitcoin.conf" "$WORK_DIR/bitcoin.conf.original"

    write_service_template "$WORK_DIR/explorer.service"
    write_apache_template "$WORK_DIR/explorer.conf"
    cp --preserve=mode,ownership,timestamps "$APACHE_PORTS" "$WORK_DIR/ports.conf.original"
    cp "$APACHE_PORTS" "$WORK_DIR/ports.conf"
    if ! grep -Eq '^[[:space:]]*Listen[[:space:]]+4082([[:space:]]|$)' "$WORK_DIR/ports.conf"; then
        printf '\nListen 4082\n' >>"$WORK_DIR/ports.conf"
        PORT_WAS_ADDED=yes
    else
        PORT_WAS_ADDED=no
    fi
    chmod 0600 "$WORK_DIR"/*.{conf,service,original} 2>/dev/null || true
}

sha256() { sha256sum "$1" | awk '{print $1}'; }

write_marker() {
    local mode=$1 phase=$2 temporary=${MARKER}.new
    install -d -o root -g root -m 0700 "$STATE_DIR" || return 1
    {
        printf 'mode=%s\n' "$mode"
        printf 'phase=%s\n' "$phase"
        printf 'tag=%s\n' "$SELECTED_TAG"
        printf 'commit=%s\n' "$SELECTED_COMMIT"
        [[ -z $OLD_TAG ]] || printf 'old_tag=%s\n' "$OLD_TAG"
        [[ -z $OLD_COMMIT ]] || printf 'old_commit=%s\n' "$OLD_COMMIT"
        [[ $mode != update ]] || printf 'explorer_was_active=%s\n' "$EXPLORER_WAS_ACTIVE"
        if [[ $mode == install ]]; then
            printf 'env_sha256=%s\n' "$(sha256 "$WORK_DIR/btc-rpc-explorer.env")"
            printf 'bitcoin_sha256=%s\n' "$(sha256 "$WORK_DIR/bitcoin.conf")"
            printf 'bitcoin_original_sha256=%s\n' "$(sha256 "$WORK_DIR/bitcoin.conf.original")"
            printf 'service_sha256=%s\n' "$(sha256 "$WORK_DIR/explorer.service")"
            printf 'apache_sha256=%s\n' "$(sha256 "$WORK_DIR/explorer.conf")"
            printf 'ports_sha256=%s\n' "$(sha256 "$WORK_DIR/ports.conf")"
            printf 'ports_original_sha256=%s\n' "$(sha256 "$WORK_DIR/ports.conf.original")"
            printf 'port_added=%s\n' "$PORT_WAS_ADDED"
        fi
    } >"$temporary" || return 1
    chmod 0600 "$temporary" || return 1
    mv -f -- "$temporary" "$MARKER" || return 1
}

marker_value() {
    local key=$1
    [[ $(grep -c "^${key}=" "$MARKER") -eq 1 ]] || return 1
    sed -n "s/^${key}=//p" "$MARKER"
}

verify_staged_file() {
    local file=$1 key=$2 expected
    expected=$(marker_value "$key") || die "The recovery marker is missing $key."
    [[ $expected =~ ^[0-9a-f]{64}$ && -f $file && $(sha256 "$file") == "$expected" ]] || \
        die "Staged recovery file failed verification: $file"
}

verify_recorded_file() {
    local file=$1 key=$2 expected
    expected=$(marker_value "$key") || die "The recovery marker is missing $key."
    [[ $expected =~ ^[0-9a-f]{64}$ && -f $file && $(sha256 "$file") == "$expected" ]] || \
        die "Installed recovery file failed verification: $file"
}

verify_release_tree() {
    local repo=$1 expected=$2 status
    release_matches_commit "$repo" "$expected" || die "The staged Explorer release failed verification."
}

release_matches_commit() {
    local repo=$1 expected=$2 status
    [[ -d $repo/.git ]] || return 1
    [[ $(git -C "$repo" rev-parse HEAD 2>/dev/null) == "$expected" ]] || return 1
    git -C "$repo" fsck --full --no-dangling >/dev/null 2>&1 || return 1
    git -C "$repo" diff --quiet "$expected" -- . || return 1
    status=$(git -C "$repo" status --porcelain --untracked-files=normal)
    [[ -z $status || $status == '?? node_modules/' ]]
}

release_tag_matches_commit() {
    local repo=$1 tag=$2 expected=$3
    [[ $(git -C "$repo" rev-parse "$tag^{commit}" 2>/dev/null) == "$expected" ]]
}

ensure_explorer_account() {
    local entry group_entry
    group_entry=$(getent group explorer || true)
    if [[ -z $group_entry ]]; then
        groupadd --system explorer
    fi
    entry=$(getent passwd explorer || true)
    if [[ -z $entry ]]; then
        useradd --system --gid explorer --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin explorer
    else
        [[ $(id -gn explorer) == explorer ]] || die "Existing explorer user does not have primary group explorer."
        [[ $(getent passwd explorer | cut -d: -f6) == /nonexistent ]] || die "Existing explorer user has an unexpected home directory."
        [[ $(getent passwd explorer | cut -d: -f7) == /usr/sbin/nologin ]] || die "Existing explorer user has an unexpected login shell."
    fi
}

ensure_explorer_cache() {
    if [[ -e $CACHE_DIR ]]; then
        [[ -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die "Explorer cache path is not a safe directory: $CACHE_DIR"
        [[ $(stat -c '%U:%G:%a' "$CACHE_DIR") == explorer:explorer:750 ]] || \
            die "Explorer cache directory has unexpected ownership or permissions."
    else
        install -d -o explorer -g explorer -m 0750 "$CACHE_DIR"
    fi
}

verify_explorer_cache() {
    [[ -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die "Explorer cache directory is missing or unsafe."
    [[ $(stat -c '%U:%G:%a' "$CACHE_DIR") == explorer:explorer:750 ]] || \
        die "Explorer cache directory has unexpected ownership or permissions."
    runuser -u explorer -- test -w "$CACHE_DIR" || die "Explorer cannot write to its cache directory."
}

verify_update_cache_compatibility() {
    if [[ -f $ENV_FILE ]] && grep -Fqx 'BTCEXP_FILESYSTEM_CACHE_DIR=/var/cache/btc-rpc-explorer' "$ENV_FILE"; then
        ensure_explorer_cache
        verify_explorer_cache
    else
        warn "The existing Explorer environment does not configure the installer-managed cache; it was preserved unchanged."
    fi
}

install_or_verify() {
    local source=$1 target=$2 owner=$3 group=$4 mode=$5 description=$6
    if [[ -e $target ]]; then
        [[ -f $target && ! -L $target && $(sha256 "$source") == $(sha256 "$target") ]] || \
            die "$target differs from the staged $description; it was not overwritten."
        [[ $(stat -c '%U:%G:%a' "$target") == "$owner:$group:${mode#0}" ]] || \
            die "$target has unexpected ownership or permissions; it was not overwritten."
    else
        atomic_install "$source" "$target" "$owner" "$group" "$mode"
    fi
}

atomic_install() {
    local source=$1 target=$2 owner=$3 group=$4 mode=$5
    local temporary=${target}.entropy39-new
    if [[ -e $temporary ]]; then
        [[ -f $temporary && ! -L $temporary && $(sha256 "$source") == $(sha256 "$temporary") ]] || \
            die "Unexpected interrupted-install file at $temporary; it was not overwritten."
    else
        install -o "$owner" -g "$group" -m "$mode" "$source" "$temporary"
    fi
    mv -f -- "$temporary" "$target"
}

install_bitcoin_configuration() {
    local current original staged
    current=$(sha256 "$BITCOIN_CONF")
    original=$(sha256 "$WORK_DIR/bitcoin.conf.original")
    staged=$(sha256 "$WORK_DIR/bitcoin.conf")
    if [[ $current == "$original" ]]; then
        atomic_install "$WORK_DIR/bitcoin.conf" "$BITCOIN_CONF" root bitcoin 0640
    elif [[ $current != "$staged" ]]; then
        die "$BITCOIN_CONF changed during installation; no RPC credential was overwritten."
    fi
}

install_ports_configuration() {
    local current original staged
    current=$(sha256 "$APACHE_PORTS")
    original=$(sha256 "$WORK_DIR/ports.conf.original")
    staged=$(sha256 "$WORK_DIR/ports.conf")
    if [[ $current == "$original" ]]; then
        atomic_install "$WORK_DIR/ports.conf" "$APACHE_PORTS" root root 0644
    elif [[ $current != "$staged" ]]; then
        die "$APACHE_PORTS changed during installation; it was not overwritten."
    fi
}

wait_for_explorer() {
    local attempt code
    for ((attempt=0; attempt<20; attempt++)); do
        code=$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:3002/ || true)
        [[ $code == 200 || $code == 401 ]] && return 0
        sleep 0.5
    done
    return 1
}

verify_running_installation() {
    systemctl is-active --quiet explorer.service || die "Explorer is not active."
    systemctl is-enabled --quiet explorer.service || die "Explorer is not enabled."
    [[ $(stat -c '%U:%G:%a' "$ENV_FILE") == root:explorer:640 ]] || die "Explorer environment permissions are incorrect."
    [[ -r $INSTALL_DIR/package.json ]] || die "Explorer package metadata is missing."
    verify_explorer_cache
    wait_for_explorer || die "Explorer did not respond on port 3002 within 10 seconds."
    local proxy_code
    proxy_code=$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:4082/ || true)
    [[ $proxy_code == 200 || $proxy_code == 401 ]] || die "The Explorer Apache proxy did not respond successfully."
}

restore_explorer_service_state() {
    if [[ $EXPLORER_WAS_ACTIVE == yes ]]; then
        if ! systemctl is-active --quiet explorer.service; then
            # Avoid activating bitcoind through the service unit's Wants= edge.
            systemctl start explorer.service --job-mode=ignore-dependencies || return 1
        fi
        systemctl is-active --quiet explorer.service || return 1
        wait_for_explorer || return 1
    else
        if systemctl is-active --quiet explorer.service; then
            systemctl stop explorer.service || return 1
        fi
        ! systemctl is-active --quiet explorer.service
    fi
}

verify_installed_configuration() {
    systemctl is-enabled --quiet explorer.service || die "Explorer is not enabled for future boots."
    [[ $(stat -c '%U:%G:%a' "$ENV_FILE") == root:explorer:640 ]] || die "Explorer environment permissions are incorrect."
    [[ $(stat -c '%U:%G:%a' "$SERVICE_FILE") == root:root:644 ]] || die "Explorer service permissions are incorrect."
    [[ $(stat -c '%U:%G:%a' "$APACHE_SITE") == root:root:644 ]] || die "Explorer Apache site permissions are incorrect."
    [[ -r $INSTALL_DIR/package.json ]] || die "Explorer package metadata is missing."
    verify_explorer_cache
    [[ $(stat -c '%U:%G:%a' "$BITCOIN_CONF") == root:bitcoin:640 ]] || die "Bitcoin Core configuration permissions are incorrect."
    [[ $(grep -Ec '^rpcauth=explorer:[0-9a-fA-F]+\$[0-9a-fA-F]+$' "$BITCOIN_CONF") -eq 1 ]] || die "Bitcoin Core does not contain exactly one valid Explorer rpcauth entry."
    grep -Eq '^BTCEXP_BITCOIND_USER=explorer$' "$ENV_FILE" || die "Explorer RPC user configuration is incorrect."
    ! grep -Eq 'EXPLORER-PASSWORD-HERE|RPC-PASSWORD-HERE' "$ENV_FILE" || die "Explorer environment contains an unresolved credential placeholder."
    apache2ctl configtest
}

failure_handler() {
    local result=$? recorded_mode recorded_phase current staged
    trap - EXIT ERR INT TERM HUP
    if [[ $FAILURE_ARMED == yes ]]; then
        warn "Explorer did not complete; verified staged files and the recovery marker were preserved."
        if [[ -e $SERVICE_FILE ]]; then
            systemctl stop explorer.service >/dev/null 2>&1 || warn "Explorer could not be stopped; installed files were preserved for recovery."
        fi
        recorded_mode=$(marker_value mode 2>/dev/null || true)
        recorded_phase=$(marker_value phase 2>/dev/null || true)
        if [[ $recorded_mode == install && $recorded_phase != complete ]] && \
                ! systemctl is-active --quiet explorer.service; then
            if [[ -f $WORK_DIR/bitcoin.conf && -f $WORK_DIR/bitcoin.conf.original && -f $BITCOIN_CONF ]]; then
                current=$(sha256 "$BITCOIN_CONF")
                staged=$(sha256 "$WORK_DIR/bitcoin.conf")
                if [[ $current == "$staged" ]]; then
                    atomic_install "$WORK_DIR/bitcoin.conf.original" "$BITCOIN_CONF" root bitcoin 0640 || true
                fi
            fi
            if [[ -f $WORK_DIR/ports.conf && -f $WORK_DIR/ports.conf.original && -f $APACHE_PORTS ]]; then
                current=$(sha256 "$APACHE_PORTS")
                staged=$(sha256 "$WORK_DIR/ports.conf")
                if [[ $current == "$staged" ]]; then
                    atomic_install "$WORK_DIR/ports.conf.original" "$APACHE_PORTS" root root 0644 || true
                fi
            fi
            a2dissite explorer.conf >/dev/null 2>&1 || true
            apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 >/dev/null 2>&1 || true
            rm -f -- "$PORT_RECORD"
        fi
    elif [[ ! -e $MARKER ]]; then
        [[ ! -d $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
        if [[ -d $UNINSTALL_WORK_DIR && ! -L $UNINSTALL_WORK_DIR && \
                $(stat -c '%U:%G:%a' "$UNINSTALL_WORK_DIR" 2>/dev/null || true) == root:root:700 ]]; then
            rm -rf -- "$UNINSTALL_WORK_DIR"
        fi
    fi
    exit "$result"
}

write_release_records() {
    local tag=$1 commit=$2 tag_temporary=${TAG_RECORD}.new commit_temporary=${COMMIT_RECORD}.new
    printf '%s\n' "$tag" >"$tag_temporary" || return 1
    printf '%s\n' "$commit" >"$commit_temporary" || return 1
    chown root:root "$tag_temporary" "$commit_temporary" || return 1
    chmod 0644 "$tag_temporary" "$commit_temporary" || return 1
    mv -f -- "$tag_temporary" "$TAG_RECORD" || return 1
    mv -f -- "$commit_temporary" "$COMMIT_RECORD" || return 1
}

finish_operation() {
    local tag=$1 commit=$2
    write_release_records "$tag" "$commit" || return 1
    rm -rf -- "$WORK_DIR" "$UPDATE_BACKUP" || return 1
    rm -f -- "$MARKER" || return 1
    FAILURE_ARMED=no
}

complete_operation() {
    write_marker "$MODE" complete || \
        die "Explorer installation completed, but completion could not be recorded; existing recovery information was preserved."
    FAILURE_ARMED=no
    finish_operation "$SELECTED_TAG" "$SELECTED_COMMIT" || \
        die "Explorer installation completed, but completion cleanup failed; recovery information was preserved."
}

commit_install() {
    ensure_explorer_account
    ensure_explorer_cache
    if [[ ! -e $INSTALL_DIR ]]; then
        mv "$WORK_DIR/release" "$INSTALL_DIR"
        chown -R root:root "$INSTALL_DIR"
    else
        verify_release_tree "$INSTALL_DIR" "$SELECTED_COMMIT"
    fi

    install_or_verify "$WORK_DIR/btc-rpc-explorer.env" "$ENV_FILE" root explorer 0640 "Explorer environment"
    install_or_verify "$WORK_DIR/explorer.service" "$SERVICE_FILE" root root 0644 "Explorer service"
    install_or_verify "$WORK_DIR/explorer.conf" "$APACHE_SITE" root root 0644 "Explorer Apache site"
    install_bitcoin_configuration
    install_ports_configuration
    if [[ $PORT_WAS_ADDED == yes ]]; then
        printf 'Listen 4082\n' >"${PORT_RECORD}.new"
        chown root:root "${PORT_RECORD}.new"
        chmod 0644 "${PORT_RECORD}.new"
        mv -f -- "${PORT_RECORD}.new" "$PORT_RECORD"
    fi

    a2enmod proxy proxy_http >/dev/null
    a2ensite explorer.conf >/dev/null
    apache2ctl configtest
    systemctl daemon-reload
    if systemctl is-active --quiet apache2.service; then
        systemctl reload apache2.service
    else
        say "Apache is not running; its validated Explorer configuration will take effect when Apache starts."
    fi
    systemctl enable explorer.service >/dev/null
    verify_installed_configuration
    complete_operation
    say "BTC RPC Explorer $SELECTED_TAG was installed successfully."
    say "Explorer was enabled for future boots but was not started by this installer."
    if systemctl is-active --quiet bitcoind.service; then
        say "Bitcoin Core is currently running and must be restarted before the new Explorer RPC credentials take effect."
    else
        say "Bitcoin Core is not running; the new Explorer RPC credentials will take effect when it next starts."
    fi
}

fresh_install() {
    local path
    for path in "$INSTALL_DIR" "$ENV_FILE" "$SERVICE_FILE" "$APACHE_SITE" "$APACHE_ENABLED" "$TAG_RECORD" "$COMMIT_RECORD" "$PORT_RECORD"; do
        [[ ! -e $path && ! -L $path ]] || die "An existing Explorer installation or configuration was detected at $path. Nothing was changed."
    done
    ! pgrep -f '/usr/local/lib/btc-rpc-explorer' >/dev/null 2>&1 || \
        die "A BTC RPC Explorer process is already running. Nothing was changed."
    [[ ! -e $UPDATE_BACKUP ]] || die "An unexpected Explorer update backup exists at $UPDATE_BACKUP."
    rm -rf -- "$WORK_DIR"
    install -d -o root -g root -m 0700 "$WORK_DIR"
    prepare_release
    stage_install_configuration
    write_marker install committing
    FAILURE_ARMED=yes
    commit_install
}

load_common_marker() {
    SELECTED_TAG=$(marker_value tag) || die "The recovery marker has no valid tag."
    SELECTED_COMMIT=$(marker_value commit) || die "The recovery marker has no valid commit."
    [[ $SELECTED_TAG =~ $TAG_PATTERN && $SELECTED_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "The recovery marker contains invalid release data."
}

recover_install() {
    local phase
    say "Recovering an interrupted Explorer installation"
    load_common_marker
    phase=$(marker_value phase) || die "The recovery marker has no phase."
    if [[ $phase == complete ]]; then
        if ! release_matches_commit "$INSTALL_DIR" "$SELECTED_COMMIT" || \
                ! release_tag_matches_commit "$INSTALL_DIR" "$SELECTED_TAG" "$SELECTED_COMMIT"; then
            die "The completed Explorer installation failed release verification; recovery information was preserved."
        fi
        verify_recorded_file "$ENV_FILE" env_sha256
        verify_recorded_file "$BITCOIN_CONF" bitcoin_sha256
        verify_recorded_file "$SERVICE_FILE" service_sha256
        verify_recorded_file "$APACHE_SITE" apache_sha256
        verify_recorded_file "$APACHE_PORTS" ports_sha256
        verify_explorer_cache
        finish_operation "$SELECTED_TAG" "$SELECTED_COMMIT" || \
            die "The completed Explorer installation could not finish cleanup; recovery information was preserved."
        say "Completed Explorer installation recovery successfully."
        return
    fi
    [[ $phase == committing ]] || die "Unknown Explorer installation recovery phase: $phase"
    [[ -d $WORK_DIR && ! -L $WORK_DIR && $(stat -c '%U:%G:%a' "$WORK_DIR") == root:root:700 ]] || \
        die "The Explorer recovery directory is missing or unsafe."
    verify_staged_file "$WORK_DIR/btc-rpc-explorer.env" env_sha256
    verify_staged_file "$WORK_DIR/bitcoin.conf" bitcoin_sha256
    verify_staged_file "$WORK_DIR/bitcoin.conf.original" bitcoin_original_sha256
    verify_staged_file "$WORK_DIR/explorer.service" service_sha256
    verify_staged_file "$WORK_DIR/explorer.conf" apache_sha256
    verify_staged_file "$WORK_DIR/ports.conf" ports_sha256
    verify_staged_file "$WORK_DIR/ports.conf.original" ports_original_sha256
    PORT_WAS_ADDED=$(marker_value port_added 2>/dev/null || true)
    if [[ -z $PORT_WAS_ADDED ]]; then
        if [[ $(sha256 "$WORK_DIR/ports.conf") == $(sha256 "$WORK_DIR/ports.conf.original") ]]; then PORT_WAS_ADDED=no; else PORT_WAS_ADDED=yes; fi
    fi
    [[ $PORT_WAS_ADDED == yes || $PORT_WAS_ADDED == no ]] || die "The recovery marker has an invalid Apache listener state."
    prepare_keyring
    if [[ -d $WORK_DIR/release ]]; then
        verify_tag "$WORK_DIR/release" "$SELECTED_TAG"
        verify_release_tree "$WORK_DIR/release" "$SELECTED_COMMIT"
    elif [[ -d $INSTALL_DIR ]]; then
        verify_tag "$INSTALL_DIR" "$SELECTED_TAG"
        verify_release_tree "$INSTALL_DIR" "$SELECTED_COMMIT"
    else
        die "The authenticated Explorer release is missing."
    fi
    FAILURE_ARMED=yes
    commit_install
}

verify_existing_update_source() {
    [[ -d $INSTALL_DIR/.git ]] || die "The Explorer installation has no Git metadata and cannot be updated safely."
    [[ -f $TAG_RECORD && -f $COMMIT_RECORD ]] || die "This Explorer installation was not recorded by the installer and cannot be updated automatically."
    OLD_TAG=$(<"$TAG_RECORD")
    OLD_COMMIT=$(<"$COMMIT_RECORD")
    [[ $OLD_TAG =~ $TAG_PATTERN && $OLD_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "The installed Explorer release record is invalid."
    [[ $(git -C "$INSTALL_DIR" rev-parse HEAD) == "$OLD_COMMIT" ]] || die "The Explorer checkout does not match its recorded commit."
    verify_release_tree "$INSTALL_DIR" "$OLD_COMMIT"
    verify_update_cache_compatibility
}

rollback_update() {
    ROLLBACK_RESULT=failed
    warn "The Explorer update failed; restoring the previous verified checkout."
    if ! write_marker update rolling-back; then
        warn "The rollback marker could not be written; both releases were left in place."
        return 1
    fi
    systemctl stop explorer.service >/dev/null 2>&1 || true

    if [[ -e $INSTALL_DIR ]] && release_matches_commit "$INSTALL_DIR" "$SELECTED_COMMIT"; then
        if [[ -e $WORK_DIR/failed-release ]]; then
            warn "The failed Explorer release already has a preserved copy; automatic rollback stopped."
            return 1
        fi
        if ! mv "$INSTALL_DIR" "$WORK_DIR/failed-release"; then
            warn "The failed Explorer release could not be preserved; automatic rollback stopped."
            return 1
        fi
    elif [[ -e $INSTALL_DIR ]] && ! release_matches_commit "$INSTALL_DIR" "$OLD_COMMIT"; then
        warn "The active Explorer directory is not a verified old or new release; automatic rollback stopped."
        return 1
    elif [[ ! -e $INSTALL_DIR && -d $WORK_DIR/release ]]; then
        if [[ -e $WORK_DIR/failed-release ]] || ! mv "$WORK_DIR/release" "$WORK_DIR/failed-release"; then
            warn "The failed Explorer release could not be preserved; automatic rollback stopped."
            return 1
        fi
    fi

    if [[ ! -e $INSTALL_DIR ]]; then
        if [[ ! -d $UPDATE_BACKUP ]] || ! mv "$UPDATE_BACKUP" "$INSTALL_DIR"; then
            warn "The previous Explorer checkout could not be restored; both releases and recovery information were preserved."
            return 1
        fi
    fi
    if ! release_matches_commit "$INSTALL_DIR" "$OLD_COMMIT"; then
        warn "The restored Explorer checkout failed verification; both releases and recovery information were preserved."
        return 1
    fi
    if ! restore_explorer_service_state; then
        warn "The previous Explorer checkout was restored but its original service state could not be restored; both releases and recovery information were preserved."
        [[ $EXPLORER_WAS_ACTIVE != yes ]] || systemctl stop explorer.service >/dev/null 2>&1 || true
        return 1
    fi

    ROLLBACK_RESULT=restored
    if ! write_marker update rolled-back; then
        warn "The previous Explorer version was restored, but rollback completion could not be recorded."
        return 1
    fi
    FAILURE_ARMED=no
    if ! finish_operation "$OLD_TAG" "$OLD_COMMIT"; then
        warn "The previous Explorer version was restored, but rollback cleanup did not complete; recovery information was preserved."
        return 1
    fi
    return 0
}

report_failed_update() {
    local context=$1
    if rollback_update; then
        die "$context; the previous checkout was restored successfully."
    fi
    if [[ $ROLLBACK_RESULT == restored ]]; then
        die "$context; the previous checkout was restored, but rollback cleanup did not complete and recovery information was preserved."
    fi
    die "$context; automatic rollback failed, and both releases and recovery information were preserved."
}

finish_recovered_rollback() {
    if ! release_matches_commit "$INSTALL_DIR" "$OLD_COMMIT" || \
            ! release_tag_matches_commit "$INSTALL_DIR" "$OLD_TAG" "$OLD_COMMIT"; then
        die "The rolled-back Explorer checkout failed verification; recovery information was preserved."
    fi
    restore_explorer_service_state || \
        die "The rolled-back Explorer service state could not be restored; recovery information was preserved."
    finish_operation "$OLD_TAG" "$OLD_COMMIT" || \
        die "The completed Explorer rollback could not finish cleanup; recovery information was preserved."
    say "The previous Explorer version was restored successfully."
}

commit_update() {
    if [[ $EXPLORER_WAS_ACTIVE == yes ]]; then
        systemctl stop explorer.service || die "Explorer could not be stopped; no application files were changed."
    fi
    [[ ! -e $UPDATE_BACKUP ]] || die "The Explorer update backup path already exists."
    mv "$INSTALL_DIR" "$UPDATE_BACKUP"
    write_marker update swapped
    mv "$WORK_DIR/release" "$INSTALL_DIR"
    chown -R root:root "$INSTALL_DIR"
    if ! restore_explorer_service_state; then
        report_failed_update "The new Explorer release failed service-state verification"
    fi
    complete_operation
    say "BTC RPC Explorer was updated from $OLD_TAG to $SELECTED_TAG successfully."
}

update_installation() {
    verify_existing_update_source
    [[ -f $ENV_FILE && -f $SERVICE_FILE && -f $APACHE_SITE ]] || die "The Explorer configuration is incomplete; update was refused."
    [[ ! -e $UPDATE_BACKUP ]] || die "An unexpected Explorer update backup exists at $UPDATE_BACKUP."
    rm -rf -- "$WORK_DIR"
    install -d -o root -g root -m 0700 "$WORK_DIR"
    prepare_release
    verify_tag "$INSTALL_DIR" "$OLD_TAG"
    [[ $(git -C "$INSTALL_DIR" rev-parse "$OLD_TAG^{commit}") == "$OLD_COMMIT" ]] || \
        die "The recorded Explorer tag no longer resolves to its installed commit."
    if [[ $SELECTED_COMMIT == "$OLD_COMMIT" ]]; then
        rm -rf -- "$WORK_DIR"
        say "BTC RPC Explorer is already current at $SELECTED_TAG."
        return
    fi
    if systemctl is-active --quiet explorer.service; then EXPLORER_WAS_ACTIVE=yes; else EXPLORER_WAS_ACTIVE=no; fi
    write_marker update prepared
    FAILURE_ARMED=yes
    commit_update
}

recover_update() {
    local phase
    say "Recovering an interrupted Explorer update"
    load_common_marker
    OLD_TAG=$(marker_value old_tag) || die "The recovery marker has no previous tag."
    OLD_COMMIT=$(marker_value old_commit) || die "The recovery marker has no previous commit."
    EXPLORER_WAS_ACTIVE=$(marker_value explorer_was_active) || die "The recovery marker has no original Explorer service state."
    [[ $EXPLORER_WAS_ACTIVE == yes || $EXPLORER_WAS_ACTIVE == no ]] || die "The recovery marker has an invalid original Explorer service state."
    phase=$(marker_value phase) || die "The recovery marker has no phase."
    [[ $OLD_TAG =~ $TAG_PATTERN && $OLD_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "The recovery marker contains invalid previous-release data."
    verify_update_cache_compatibility

    case $phase in
        complete)
            if ! release_matches_commit "$INSTALL_DIR" "$SELECTED_COMMIT" || \
                    ! release_tag_matches_commit "$INSTALL_DIR" "$SELECTED_TAG" "$SELECTED_COMMIT"; then
                die "The completed Explorer update failed release verification; recovery information was preserved."
            fi
            restore_explorer_service_state || \
                die "The updated Explorer service state could not be restored; recovery information was preserved."
            finish_operation "$SELECTED_TAG" "$SELECTED_COMMIT" || \
                die "The completed Explorer update could not finish cleanup; recovery information was preserved."
            say "Completed Explorer update recovery successfully."
            return
            ;;
        rolling-back)
            if rollback_update; then
                say "The previous Explorer version was restored successfully."
                return
            fi
            if [[ $ROLLBACK_RESULT == restored ]]; then
                die "The previous Explorer version was restored, but rollback cleanup did not complete and recovery information was preserved."
            fi
            die "Automatic Explorer rollback failed; both releases and recovery information were preserved."
            ;;
        rolled-back)
            finish_recovered_rollback
            return
            ;;
        prepared|swapped) ;;
        *) die "Unknown Explorer update recovery phase: $phase" ;;
    esac
    prepare_keyring

    if [[ $phase == prepared ]]; then
        if [[ -d $UPDATE_BACKUP && ! -e $INSTALL_DIR ]]; then
            verify_tag "$UPDATE_BACKUP" "$OLD_TAG"
            [[ $(git -C "$UPDATE_BACKUP" rev-parse "$OLD_TAG^{commit}") == "$OLD_COMMIT" ]] || \
                die "The previous Explorer tag does not resolve to its recorded commit."
            verify_release_tree "$UPDATE_BACKUP" "$OLD_COMMIT"
            verify_tag "$WORK_DIR/release" "$SELECTED_TAG"
            verify_release_tree "$WORK_DIR/release" "$SELECTED_COMMIT"
            write_marker update swapped
            mv "$WORK_DIR/release" "$INSTALL_DIR"
            chown -R root:root "$INSTALL_DIR"
            if ! restore_explorer_service_state; then
                report_failed_update "The interrupted update failed service-state verification"
            fi
            complete_operation
            say "Interrupted Explorer update to $SELECTED_TAG recovered successfully."
            return
        fi
        verify_tag "$INSTALL_DIR" "$OLD_TAG"
        [[ $(git -C "$INSTALL_DIR" rev-parse "$OLD_TAG^{commit}") == "$OLD_COMMIT" ]] || \
            die "The previous Explorer tag does not resolve to its recorded commit."
        verify_release_tree "$INSTALL_DIR" "$OLD_COMMIT"
        verify_tag "$WORK_DIR/release" "$SELECTED_TAG"
        verify_release_tree "$WORK_DIR/release" "$SELECTED_COMMIT"
        FAILURE_ARMED=yes
        commit_update
        return
    fi
    [[ -d $UPDATE_BACKUP ]] || die "The previous Explorer checkout is missing; no files were changed."
    verify_tag "$UPDATE_BACKUP" "$OLD_TAG"
    [[ $(git -C "$UPDATE_BACKUP" rev-parse "$OLD_TAG^{commit}") == "$OLD_COMMIT" ]] || \
        die "The previous Explorer tag does not resolve to its recorded commit."
    verify_release_tree "$UPDATE_BACKUP" "$OLD_COMMIT"
    if [[ -d $INSTALL_DIR ]]; then
        verify_tag "$INSTALL_DIR" "$SELECTED_TAG"
        verify_release_tree "$INSTALL_DIR" "$SELECTED_COMMIT"
    elif [[ -d $WORK_DIR/release ]]; then
        verify_tag "$WORK_DIR/release" "$SELECTED_TAG"
        verify_release_tree "$WORK_DIR/release" "$SELECTED_COMMIT"
        mv "$WORK_DIR/release" "$INSTALL_DIR"
        chown -R root:root "$INSTALL_DIR"
    else
        die "The new authenticated Explorer checkout is missing; the previous checkout was preserved."
    fi
    if ! restore_explorer_service_state; then
        report_failed_update "The interrupted update failed service-state verification"
    fi
    complete_operation
    say "Interrupted Explorer update to $SELECTED_TAG recovered successfully."
}

validate_managed_environment() {
    [[ -f $ENV_FILE && ! -L $ENV_FILE ]] || die "Explorer environment file is missing or unsafe."
    [[ $(stat -c '%U:%G:%a' "$ENV_FILE") == root:explorer:640 ]] || die "Explorer environment permissions are unexpected."
    local key
    for key in BTCEXP_HOST BTCEXP_PORT BTCEXP_BITCOIND_HOST BTCEXP_BITCOIND_PORT BTCEXP_BITCOIND_USER \
            BTCEXP_BITCOIND_PASS BTCEXP_BASIC_AUTH_PASSWORD; do
        [[ $(grep -c "^${key}=" "$ENV_FILE") -eq 1 ]] || die "Explorer environment has an unexpected $key definition."
    done
    grep -Eq '^BTCEXP_BITCOIND_USER=explorer$' "$ENV_FILE" || die "Explorer environment has an unexpected RPC user."
}

verify_exact_template() {
    local target=$1 generator=$2 description=$3 expected=$UNINSTALL_WORK_DIR/expected
    [[ -f $target && ! -L $target ]] || die "$description is missing or unsafe."
    "$generator" "$expected"
    cmp -s "$target" "$expected" || die "$description differs from the installer-managed template."
    rm -f -- "$expected"
}

other_apache_4082_reference_exists() {
    local file
    while IFS= read -r -d '' file; do
        [[ $file == "$APACHE_PORTS" || $file == "$APACHE_SITE" || $file == "$APACHE_ENABLED" ]] && continue
        grep -Eq '(^|[^0-9])4082([^0-9]|$)' "$file" 2>/dev/null && return 0
    done < <(find "$APACHE_CONFIG_DIR" -type f -print0)
    return 1
}

stage_uninstall() {
    local rpc_count port_count
    [[ -f $TAG_RECORD && -f $COMMIT_RECORD ]] || die "Explorer installation records are missing; unmanaged files were not removed."
    SELECTED_TAG=$(<"$TAG_RECORD")
    SELECTED_COMMIT=$(<"$COMMIT_RECORD")
    [[ $SELECTED_TAG =~ $TAG_PATTERN && $SELECTED_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "Explorer installation records are invalid."
    if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
        [[ -d $INSTALL_DIR && ! -L $INSTALL_DIR ]] || die "Explorer application path is unsafe."
        verify_release_tree "$INSTALL_DIR" "$SELECTED_COMMIT"
    fi
    if [[ -e $ENV_FILE || -L $ENV_FILE ]]; then validate_managed_environment; cp --preserve=mode,ownership,timestamps "$ENV_FILE" "$UNINSTALL_WORK_DIR/environment.original"; else : >"$UNINSTALL_WORK_DIR/environment.original"; fi
    if [[ -e $SERVICE_FILE || -L $SERVICE_FILE ]]; then verify_exact_template "$SERVICE_FILE" write_service_template "Explorer systemd unit"; cp --preserve=mode,ownership,timestamps "$SERVICE_FILE" "$UNINSTALL_WORK_DIR/service.original"; else : >"$UNINSTALL_WORK_DIR/service.original"; fi
    if [[ -e $APACHE_SITE || -L $APACHE_SITE ]]; then verify_exact_template "$APACHE_SITE" write_apache_template "Explorer Apache site"; cp --preserve=mode,ownership,timestamps "$APACHE_SITE" "$UNINSTALL_WORK_DIR/apache.original"; else : >"$UNINSTALL_WORK_DIR/apache.original"; fi
    cp --preserve=mode,ownership,timestamps "$BITCOIN_CONF" "$UNINSTALL_WORK_DIR/bitcoin.original"
    rpc_count=$(grep -c '^rpcauth=explorer:' "$BITCOIN_CONF" || true)
    [[ $rpc_count -le 1 ]] || die "bitcoin.conf contains multiple Explorer rpcauth entries."
    if ((rpc_count == 1)); then
        grep -Eq '^rpcauth=explorer:[0-9a-fA-F]+\$[0-9a-fA-F]+$' "$BITCOIN_CONF" || die "The Explorer rpcauth entry is malformed."
    fi
    awk '$0 !~ /^rpcauth=explorer:/' "$BITCOIN_CONF" >"$UNINSTALL_WORK_DIR/bitcoin.cleaned"

    PORT_WAS_ADDED=no
    if [[ -e $PORT_RECORD ]]; then
        [[ -f $PORT_RECORD && ! -L $PORT_RECORD && $(stat -c '%U:%G:%a' "$PORT_RECORD") == root:root:644 ]] || \
            die "The Explorer Apache listener ownership record is unsafe."
        [[ $(<"$PORT_RECORD") == 'Listen 4082' ]] || die "The Explorer Apache listener ownership record is invalid."
        port_count=$(grep -Ec '^[[:space:]]*Listen[[:space:]]+4082([[:space:]]|$)' "$APACHE_PORTS" || true)
        [[ $port_count -le 1 ]] || die "Apache contains multiple port 4082 listeners; none were removed."
        if ((port_count == 1)) && ! other_apache_4082_reference_exists; then
            PORT_WAS_ADDED=yes
            cp --preserve=mode,ownership,timestamps "$APACHE_PORTS" "$UNINSTALL_WORK_DIR/ports.original"
            awk '$0 !~ /^[[:space:]]*Listen[[:space:]]+4082([[:space:]]|$)/' "$APACHE_PORTS" >"$UNINSTALL_WORK_DIR/ports.cleaned"
        fi
    elif grep -Eq '^[[:space:]]*Listen[[:space:]]+4082([[:space:]]|$)' "$APACHE_PORTS"; then
        warn "Apache port 4082 has no installer ownership record and was retained."
    fi
    chmod 0600 "$UNINSTALL_WORK_DIR"/*

    {
        printf 'mode=uninstall\nphase=staged\ntag=%s\ncommit=%s\n' "$SELECTED_TAG" "$SELECTED_COMMIT"
        printf 'env_sha256=%s\nservice_sha256=%s\napache_sha256=%s\n' \
            "$(sha256 "$UNINSTALL_WORK_DIR/environment.original")" "$(sha256 "$UNINSTALL_WORK_DIR/service.original")" \
            "$(sha256 "$UNINSTALL_WORK_DIR/apache.original")"
        printf 'bitcoin_original_sha256=%s\nbitcoin_cleaned_sha256=%s\nport_added=%s\n' \
            "$(sha256 "$UNINSTALL_WORK_DIR/bitcoin.original")" "$(sha256 "$UNINSTALL_WORK_DIR/bitcoin.cleaned")" "$PORT_WAS_ADDED"
        if [[ $PORT_WAS_ADDED == yes ]]; then
            printf 'ports_original_sha256=%s\nports_cleaned_sha256=%s\n' \
                "$(sha256 "$UNINSTALL_WORK_DIR/ports.original")" "$(sha256 "$UNINSTALL_WORK_DIR/ports.cleaned")"
        fi
    } >"${MARKER}.new"
    chmod 0600 "${MARKER}.new"
    mv -f -- "${MARKER}.new" "$MARKER"
}

set_uninstall_phase() {
    local phase=$1 temporary=${MARKER}.new
    sed "s/^phase=.*/phase=$phase/" "$MARKER" >"$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$MARKER"
}

remove_verified_managed_file() {
    local target=$1 backup=$2 key=$3 description=$4 expected
    [[ -e $target || -L $target ]] || return 0
    [[ -f $target && ! -L $target ]] || die "$description became unsafe; uninstall state was preserved."
    expected=$(marker_value "$key") || die "The uninstall marker is missing $key."
    [[ $(sha256 "$target") == "$expected" && $(sha256 "$backup") == "$expected" ]] || \
        die "$description changed during uninstall; it was not removed."
    rm -f -- "$target"
}

apply_uninstall_configuration() {
    local current original cleaned
    original=$(marker_value bitcoin_original_sha256)
    cleaned=$(marker_value bitcoin_cleaned_sha256)
    current=$(sha256 "$BITCOIN_CONF")
    if [[ $current == "$original" ]]; then
        [[ $(sha256 "$UNINSTALL_WORK_DIR/bitcoin.cleaned") == "$cleaned" ]] || die "Staged bitcoin.conf cleanup failed verification."
        atomic_install "$UNINSTALL_WORK_DIR/bitcoin.cleaned" "$BITCOIN_CONF" root bitcoin 0640
    elif [[ $current != "$cleaned" ]]; then
        die "bitcoin.conf changed during uninstall; unrelated configuration was not overwritten."
    fi

    PORT_WAS_ADDED=$(marker_value port_added)
    if [[ $PORT_WAS_ADDED == yes ]]; then
        original=$(marker_value ports_original_sha256)
        cleaned=$(marker_value ports_cleaned_sha256)
        current=$(sha256 "$APACHE_PORTS")
        if [[ $current == "$original" ]]; then
            [[ $(sha256 "$UNINSTALL_WORK_DIR/ports.cleaned") == "$cleaned" ]] || die "Staged Apache listener cleanup failed verification."
            atomic_install "$UNINSTALL_WORK_DIR/ports.cleaned" "$APACHE_PORTS" root root 0644
        elif [[ $current != "$cleaned" ]]; then
            die "Apache ports configuration changed during uninstall; it was not overwritten."
        fi
    fi
}

commit_uninstall() {
    set_uninstall_phase cleaning
    systemctl disable --now explorer.service >/dev/null 2>&1 || true
    ! systemctl is-active --quiet explorer.service || die "Explorer could not be stopped."
    ! systemctl is-enabled --quiet explorer.service || die "Explorer could not be disabled."
    a2dissite explorer.conf >/dev/null 2>&1 || true

    remove_verified_managed_file "$ENV_FILE" "$UNINSTALL_WORK_DIR/environment.original" env_sha256 "Explorer environment file"
    remove_verified_managed_file "$SERVICE_FILE" "$UNINSTALL_WORK_DIR/service.original" service_sha256 "Explorer systemd unit"
    remove_verified_managed_file "$APACHE_SITE" "$UNINSTALL_WORK_DIR/apache.original" apache_sha256 "Explorer Apache site"
    apply_uninstall_configuration

    if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
        [[ -d $INSTALL_DIR && ! -L $INSTALL_DIR ]] || die "Explorer application path became unsafe."
        release_matches_commit "$INSTALL_DIR" "$SELECTED_COMMIT" || die "Explorer application files changed during uninstall; they were not removed."
        rm -rf -- "$INSTALL_DIR"
    fi
    if [[ -d $CACHE_DIR && ! -L $CACHE_DIR && $(stat -c '%U:%G:%a' "$CACHE_DIR") == explorer:explorer:750 ]]; then
        if ! rmdir "$CACHE_DIR" 2>/dev/null; then warn "Explorer cache contains data and was retained at $CACHE_DIR."; fi
    elif [[ -e $CACHE_DIR || -L $CACHE_DIR ]]; then
        warn "Explorer cache has unexpected type, ownership, or permissions and was retained at $CACHE_DIR."
    fi
    [[ ! -e $UNKNOWN_EXPLORER_STATE_DIR ]] || warn "$UNKNOWN_EXPLORER_STATE_DIR is not owned by this installer and was retained."

    systemctl daemon-reload
    apache2ctl configtest
    if systemctl is-active --quiet apache2.service; then systemctl reload apache2.service; fi
    set_uninstall_phase complete
    rm -f -- "$TAG_RECORD" "$COMMIT_RECORD" "$PORT_RECORD"
    rm -f -- "$MARKER"
    rm -rf -- "$UNINSTALL_WORK_DIR"
    FAILURE_ARMED=no
    say "BTC RPC Explorer was uninstalled successfully."
    say "The explorer user and group were retained for safe reinstallation."
    if systemctl is-active --quiet bitcoind.service; then
        say "Bitcoin Core is currently running and must be restarted before removal of the Explorer RPC credential takes effect."
    fi
}

remove_orphaned_apache_site_link() {
    local resolved
    [[ -e $APACHE_ENABLED || -L $APACHE_ENABLED ]] || return 0
    [[ -L $APACHE_ENABLED ]] || die "$APACHE_ENABLED is not an installer-managed symbolic link and was not removed."
    resolved=$(readlink -m "$APACHE_ENABLED") || die "Cannot resolve $APACHE_ENABLED safely."
    [[ $resolved == "$APACHE_SITE" ]] || die "$APACHE_ENABLED points to an unexpected target and was not removed."
    a2dissite explorer.conf >/dev/null 2>&1 || true
    [[ ! -e $APACHE_ENABLED && ! -L $APACHE_ENABLED ]] || rm -f -- "$APACHE_ENABLED"
}

remove_orphaned_explorer_rpcauth() {
    local count temporary
    count=$(grep -c '^rpcauth=explorer:' "$BITCOIN_CONF" || true)
    ((count > 0)) || return 1
    [[ $count -eq 1 ]] || die "bitcoin.conf contains multiple Explorer rpcauth entries; none were removed."
    grep -Eq '^rpcauth=explorer:[0-9a-fA-F]+\$[0-9a-fA-F]+$' "$BITCOIN_CONF" || \
        die "The remaining Explorer rpcauth entry is malformed and was not removed."
    [[ $(stat -c '%U:%G:%a' "$BITCOIN_CONF") == root:bitcoin:640 ]] || \
        die "bitcoin.conf has unexpected ownership or permissions and was not modified."
    temporary=$(mktemp "$(dirname "$BITCOIN_CONF")/.bitcoin.conf.explorer-uninstall.XXXXXX")
    if ! awk '$0 !~ /^rpcauth=explorer:/' "$BITCOIN_CONF" >"$temporary"; then
        rm -f -- "$temporary"
        die "Could not stage removal of the Explorer RPC credential."
    fi
    chown root:bitcoin "$temporary"
    chmod 0640 "$temporary"
    mv -f -- "$temporary" "$BITCOIN_CONF"
    return 0
}

uninstall_explorer() {
    if [[ ! -e $TAG_RECORD && ! -L $TAG_RECORD && ! -e $COMMIT_RECORD && ! -L $COMMIT_RECORD && \
            ! -e $INSTALL_DIR && ! -L $INSTALL_DIR && ! -e $ENV_FILE && ! -L $ENV_FILE && \
            ! -e $SERVICE_FILE && ! -L $SERVICE_FILE && ! -e $APACHE_SITE && ! -L $APACHE_SITE ]]; then
        systemctl disable --now explorer.service >/dev/null 2>&1 || true
        remove_orphaned_apache_site_link
        if remove_orphaned_explorer_rpcauth; then
            say "Removed the remaining Explorer RPC credential from bitcoin.conf."
            if systemctl is-active --quiet bitcoind.service; then
                say "Bitcoin Core is currently running and must be restarted before removal of the Explorer RPC credential takes effect."
            fi
        fi
        [[ ! -e $UNKNOWN_EXPLORER_STATE_DIR ]] || warn "$UNKNOWN_EXPLORER_STATE_DIR is not owned by this installer and was retained."
        say "BTC RPC Explorer is already uninstalled."
        return
    fi
    [[ ! -e $WORK_DIR && ! -L $WORK_DIR ]] || die "Explorer install/update work state exists without a recovery marker; uninstall was refused."
    [[ ! -e $UPDATE_BACKUP && ! -L $UPDATE_BACKUP ]] || die "Explorer update backup exists without a recovery marker; uninstall was refused."
    [[ ! -e $UNINSTALL_WORK_DIR ]] || die "Unexpected uninstall work directory exists without a recovery marker."
    install -d -o root -g root -m 0700 "$UNINSTALL_WORK_DIR"
    stage_uninstall
    FAILURE_ARMED=yes
    commit_uninstall
}

recover_uninstall() {
    local phase
    phase=$(marker_value phase) || die "The Explorer uninstall marker has no phase."
    SELECTED_TAG=$(marker_value tag) || die "The Explorer uninstall marker has no tag."
    SELECTED_COMMIT=$(marker_value commit) || die "The Explorer uninstall marker has no commit."
    [[ $SELECTED_TAG =~ $TAG_PATTERN && $SELECTED_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "The Explorer uninstall marker has invalid release data."
    if [[ $phase == complete ]]; then
        rm -f -- "$TAG_RECORD" "$COMMIT_RECORD" "$PORT_RECORD" "$MARKER"
        rm -rf -- "$UNINSTALL_WORK_DIR"
        say "Completed Explorer uninstall cleanup successfully."
        return
    fi
    [[ $phase == staged || $phase == cleaning ]] || die "Unknown Explorer uninstall recovery phase: $phase"
    [[ -d $UNINSTALL_WORK_DIR && ! -L $UNINSTALL_WORK_DIR && $(stat -c '%U:%G:%a' "$UNINSTALL_WORK_DIR") == root:root:700 ]] || \
        die "The Explorer uninstall recovery directory is missing or unsafe."
    FAILURE_ARMED=yes
    commit_uninstall
}

recover_if_needed() {
    local recorded_mode
    [[ -e $MARKER ]] || return 1
    recorded_mode=$(marker_value mode) || die "The Explorer recovery marker has no mode."
    [[ $MODE == "$recorded_mode" ]] || die "An interrupted Explorer $recorded_mode operation exists; rerun with --$recorded_mode."
    case $recorded_mode in
        install) recover_install ;;
        update) recover_update ;;
        uninstall) recover_uninstall ;;
        *) die "Unknown Explorer recovery mode: $recorded_mode" ;;
    esac
    return 0
}

terminal_recovery_pending() {
    local phase
    [[ -e $MARKER ]] || return 1
    phase=$(marker_value phase 2>/dev/null) || return 1
    [[ $phase == complete || $phase == rolled-back ]]
}

check_terminal_recovery_commands() {
    local recorded_mode
    require_command git
    recorded_mode=$(marker_value mode) || die "The Explorer recovery marker has no mode."
    [[ $recorded_mode != install && $recorded_mode != uninstall ]] || require_command sha256sum
}

recover_existing_operation() {
    if terminal_recovery_pending; then
        check_terminal_recovery_commands
    else
        check_platform
        check_templates
        if [[ $MODE == uninstall ]]; then check_uninstall_commands; check_uninstall_prerequisites
        else check_commands; check_prerequisites; fi
    fi
    recover_if_needed
}

main() {
    parse_args "$@"
    require_root
    require_command flock
    acquire_lock
    trap failure_handler EXIT ERR INT TERM HUP

    if [[ -e $MARKER ]]; then
        recover_existing_operation
        return
    fi

    check_platform
    check_templates
    if [[ $MODE == uninstall ]]; then
        check_uninstall_commands
        check_uninstall_prerequisites
        uninstall_explorer
        return
    fi
    install_dependencies
    check_commands
    check_prerequisites
    case $MODE in
        install) fresh_install ;;
        update) update_installation ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
