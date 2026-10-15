#!/bin/bash

set -Eeuo pipefail
umask 077

PROGRAM=${0##*/}
BITCOIN_USER=bitcoin
BITCOIN_GROUP=bitcoin
BITCOIN_HOME=/var/lib/bitcoin
BITCOIN_LOG_DIR=/var/log/bitcoin
BITCOIN_CONF=/etc/bitcoin.conf
BITCOIN_SERVICE=/etc/systemd/system/bitcoind.service
BITCOIN_LOGROTATE=/etc/logrotate.d/bitcoin
INSTALL_ROOT=/usr/local/lib/bitcoin
BIN_DIR=/usr/local/bin
DASHBOARD_RPC=/srv/www/dashboard/config/bitcoin-rpc.php
STATE_DIR=/var/lib/entropy39-node
INCOMPLETE_MARKER=$STATE_DIR/bitcoin-core-install-incomplete
RECOVERY_WORK_DIR=$STATE_DIR/bitcoin-core-install-work
RELEASES_URL=https://bitcoincore.org/en/releases/
DOWNLOAD_ROOT=https://bitcoincore.org/bin
GUIX_SIGS_URL=https://github.com/bitcoin-core/guix.sigs.git
FULL_GROWTH_MONTHS=24
FULL_ASSOCIATED_GIB=64
PRUNED_OVERHEAD_GIB=20
FULL_BLOCKCHAIN_GB_FALLBACK=600
FULL_MONTHLY_GROWTH_GB_FALLBACK=10
FULL_ESTIMATE_AS_OF=2026-10-13

DASHBOARD_BITCOIN_TEMPLATES=/srv/www/dashboard/docs/examples/bitcoin
BITCOIN_CONF_TEMPLATE=$DASHBOARD_BITCOIN_TEMPLATES/bitcoin.conf
SERVICE_TEMPLATE=$DASHBOARD_BITCOIN_TEMPLATES/bitcoind.service
LOGROTATE_TEMPLATE=$DASHBOARD_BITCOIN_TEMPLATES/bitcoin.logrotate

# Entropy39 trusted Bitcoin Core release signers.
#
# Provenance: primary fingerprints were independently cross-checked on
# 2026-10-13 against the signatures on the official Bitcoin Core 31.1, 31.0,
# and 30.3 SHA256SUMS manifests, the corresponding public keys published in
# bitcoin-core/guix.sigs, and the public OpenPGP key service. The Entropy39
# project owner explicitly approved this trust set. The guix.sigs repository
# supplies key material only; membership in that repository does not confer
# trust. At least three distinct fingerprints below must sign a manifest.
# Sources used for the cross-check:
#   https://bitcoincore.org/bin/bitcoin-core-{31.1,31.0,30.3}/SHA256SUMS.asc
#   https://github.com/bitcoin-core/guix.sigs/tree/main/builder-keys
#   https://keys.openpgp.org/
# Bitcoin Core's verification policy and trust-model documentation:
#   https://github.com/bitcoin/bitcoin/blob/master/contrib/verify-binaries/README.md
TRUSTED_FINGERPRINTS=(
    152812300785C96444D3334D17565732E08E5E41 # Ava Chow
    67AA5B46E7AF78053167FE343B8F814A784218F8 # Will Clark
    D1DBF2C4B96F2DEBF4C16654410108112E7EA81F # Hennadii Stepanov
    E61773CD6E01040E2F1BD78CE7E2984B6289C93A # Matthew Zipkin
    E777299FC265DD04793070EB944D35F9AC3DB76A # Michael Ford
    ED9BDF7AD6A55E232E84524257FF9BDBCC301009 # Sjors Provoost
    F4FC70F07310028424EFC20A8E4256593F177720 # Oliver Gugger
)

VERSION=
NODE_MODE=
PRUNE_SIZE=20480
DBCACHE=
START_SERVICE=yes
START_SPECIFIED=no
UNATTENDED=no
WORK_DIR=
COMMIT_STARTED=no
COMMIT_COMPLETE=no
CREATED_USER=no
CREATED_GROUP=no
CREATED_HOME=no
CREATED_LOG_DIR=no
CREATED_INSTALL_ROOT=no
CREATED_VERSION_DIR=no
CREATED_ARCHIVE=no
CREATED_CONF=no
CREATED_SERVICE=no
CREATED_LOGROTATE=no
ENABLED_SERVICE=no
SERVICE_MAY_BE_RUNNING=no
CREATED_LINKS=()
DASHBOARD_BACKUP=
DASHBOARD_ORIGINAL_SHA=
ARCHIVE_SHA=
STAGED_CONF_SHA=
STAGED_SERVICE_SHA=
STAGED_LOGROTATE_SHA=
STAGED_DASHBOARD_SHA=

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $PROGRAM [OPTIONS]

Install a fresh official Bitcoin Core release for Entropy39 Node.

Options:
  --version VERSION     Stable Bitcoin Core version (otherwise prompt)
  --full                Install a full, unpruned node
  --pruned              Install a pruned node
  --prune-size MIB      Pruning target in MiB (default: 20480)
  --dbcache MIB         Bitcoin Core database cache in MiB
  --start               Start Bitcoin Core after installation (default)
  --no-start            Enable but do not start Bitcoin Core
  --unattended          Do not prompt; --full or --pruned is required
  --help                Show this help

Use --unattended with --full or --pruned for noninteractive installation.
Any omitted version, dbcache, pruning target, or startup choice then uses its
documented default.
EOF
}

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

parse_args() {
    while (($#)); do
        case $1 in
            --version) (($# >= 2)) || die "--version requires a value"; VERSION=$2; shift 2 ;;
            --full) [[ -z $NODE_MODE || $NODE_MODE == full ]] || die "Choose only one of --full and --pruned"; NODE_MODE=full; shift ;;
            --pruned) [[ -z $NODE_MODE || $NODE_MODE == pruned ]] || die "Choose only one of --full and --pruned"; NODE_MODE=pruned; shift ;;
            --prune-size) (($# >= 2)) || die "--prune-size requires a value"; PRUNE_SIZE=$2; shift 2 ;;
            --dbcache) (($# >= 2)) || die "--dbcache requires a value"; DBCACHE=$2; shift 2 ;;
            --start) START_SERVICE=yes; START_SPECIFIED=yes; shift ;;
            --no-start) START_SERVICE=no; START_SPECIFIED=yes; shift ;;
            --unattended) UNATTENDED=yes; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
    done
    if [[ $UNATTENDED == yes && -z $NODE_MODE ]]; then
        die "--unattended requires an explicit --full or --pruned selection"
    fi
}

require_root() { [[ $EUID -eq 0 ]] || die "Run this installer as root"; }

install_dependencies() {
    local package missing=()
    for package in ca-certificates curl git gnupg python3; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed' || missing+=("$package")
    done
    if ((${#missing[@]})); then
        say "Installing required Debian packages: ${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
}

require_commands() {
    local command
    for command in awk cmp curl cut date df diff dpkg find getent git gpg grep groupadd groupdel id install mktemp pgrep python3 readlink runuser sed sha256sum sort stat systemctl tar useradd userdel; do
        command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
    done
}

preflight_templates() {
    local template
    for template in "$BITCOIN_CONF_TEMPLATE" "$SERVICE_TEMPLATE" "$LOGROTATE_TEMPLATE"; do
        [[ -f $template ]] || die "Missing authoritative Dashboard template: $template"
    done
    [[ -f $DASHBOARD_RPC ]] || die "The Entropy39 Dashboard RPC configuration is missing: $DASHBOARD_RPC"

    local count
    count=$(grep -Foc 'RPC-PASSWORD-HERE' "$DASHBOARD_RPC" || true)
    [[ $count -eq 1 ]] || die "Expected exactly one RPC-PASSWORD-HERE placeholder in $DASHBOARD_RPC; found $count"
}

detect_existing_installation() {
    local found=()
    [[ ! -e $INCOMPLETE_MARKER ]] || die "Internal error: interrupted installation recovery was not attempted"
    [[ -e $BITCOIN_CONF ]] && found+=("$BITCOIN_CONF")
    [[ -e $BITCOIN_SERVICE ]] && found+=("$BITCOIN_SERVICE")
    [[ -e $BITCOIN_LOGROTATE ]] && found+=("$BITCOIN_LOGROTATE")
    [[ -e $BIN_DIR/bitcoind || -L $BIN_DIR/bitcoind ]] && found+=("$BIN_DIR/bitcoind")
    [[ -e $BIN_DIR/bitcoin-cli || -L $BIN_DIR/bitcoin-cli ]] && found+=("$BIN_DIR/bitcoin-cli")
    [[ -e $BIN_DIR/bitcoin-wallet || -L $BIN_DIR/bitcoin-wallet ]] && found+=("$BIN_DIR/bitcoin-wallet")
    if [[ -d $INSTALL_ROOT ]] && find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        found+=("non-empty $INSTALL_ROOT")
    fi
    if [[ -d $BITCOIN_HOME ]] && find "$BITCOIN_HOME" -mindepth 1 -print -quit | grep -q .; then
        found+=("non-empty $BITCOIN_HOME")
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -x bitcoind >/dev/null 2>&1; then found+=("running bitcoind process"); fi
    ((${#found[@]} == 0)) || die "Existing Bitcoin Core installation or data detected: ${found[*]}. This installer only performs fresh installations."
}

fetch_stable_versions() {
    curl --fail --silent --show-error --location "$RELEASES_URL" |
        grep -Eo 'Bitcoin Core [0-9]+\.[0-9]+(\.[0-9]+)?' |
        awk '{print $3}' |
        awk -F. '!seen[$1]++'
}

release_is_official() {
    local release_page
    [[ $1 =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    release_page=$(curl --fail --silent --show-error --location "$RELEASES_URL") || return 1
    grep -Eq "Bitcoin Core $1([^0-9.]|$)" <<<"$release_page" || return 1
    curl --fail --silent --show-error --location --output /dev/null "$DOWNLOAD_ROOT/bitcoin-core-$1/SHA256SUMS" || return 1
    curl --fail --silent --show-error --location --output /dev/null "$DOWNLOAD_ROOT/bitcoin-core-$1/SHA256SUMS.asc" || return 1
}

choose_version() {
    local versions=() answer index
    mapfile -t versions < <(fetch_stable_versions)
    ((${#versions[@]} >= 5)) || die "Could not discover the latest stable Bitcoin Core release from five release series"
    versions=("${versions[@]:0:5}")

    if [[ -z $VERSION ]]; then
        if [[ $UNATTENDED == yes ]]; then
            VERSION=${versions[0]}
        else
            say "Latest stable Bitcoin Core release from each recent release series:"
            for index in 0 1 2 3 4; do printf '  %d) %s%s\n' "$((index + 1))" "${versions[$index]}" "$([[ $index -eq 0 ]] && printf ' (default)')"; done
            say "  6) Enter another stable version"
            read -r -p "Select a version [1]: " answer
            answer=${answer:-1}
            case $answer in
                1|2|3|4|5) VERSION=${versions[$((answer - 1))]} ;;
                6) read -r -p "Stable Bitcoin Core version: " VERSION ;;
                *) die "Invalid version selection" ;;
            esac
        fi
    fi
    release_is_official "$VERSION" || die "Bitcoin Core $VERSION is not a validated official stable release"
}

detect_architecture() {
    local deb_arch
    deb_arch=$(dpkg --print-architecture)
    case $deb_arch in
        amd64) BTC_ARCH=x86_64-linux-gnu ;;
        arm64) BTC_ARCH=aarch64-linux-gnu ;;
        armhf) BTC_ARCH=arm-linux-gnueabihf ;;
        riscv64) BTC_ARCH=riscv64-linux-gnu ;;
        *) die "No compatible official Bitcoin Core binary mapping is available for Debian architecture '$deb_arch'" ;;
    esac
    ARCHIVE=bitcoin-$VERSION-$BTC_ARCH.tar.gz
}

available_mib() {
    local probe=$BITCOIN_HOME
    while [[ ! -e $probe ]]; do probe=${probe%/*}; [[ -n $probe ]] || probe=/; done
    df -Pk "$probe" | awk 'NR==2 {printf "%.0f\n", int($4 / 1024)}'
}

official_full_required_mib() {
    local page base_gb growth_gb
    page=$(curl --fail --silent --show-error --location https://bitcoincore.org/en/download/ 2>/dev/null || true)
    base_gb=$(sed -nE 's/.*download of about ([0-9]+)GB.*/\1/p' <<<"$page" | head -n1)
    growth_gb=$(sed -nE 's/.*further [0-9]+-([0-9]+)GB per month.*/\1/p' <<<"$page" | head -n1)
    if [[ -z $base_gb || -z $growth_gb ]]; then
        base_gb=$FULL_BLOCKCHAIN_GB_FALLBACK
        growth_gb=$FULL_MONTHLY_GROWTH_GB_FALLBACK
        warn "Could not refresh the official Bitcoin Core storage estimate; using the dated $FULL_ESTIMATE_AS_OF fallback of $base_gb GB plus $growth_gb GB/month"
    fi
    printf '%d\n' "$(((base_gb + growth_gb * FULL_GROWTH_MONTHS + FULL_ASSOCIATED_GIB) * 1024))"
}

format_gib() { awk -v mib="$1" 'BEGIN {printf "%.1f GiB", mib / 1024}'; }

choose_node_mode() {
    local answer available required minimum
    if [[ -z $NODE_MODE ]]; then
        say "Node operation:"
        say "  1) Full (unpruned)"
        say "  2) Pruned"
        read -r -p "Select operation [1]: " answer
        case ${answer:-1} in 1) NODE_MODE=full ;; 2) NODE_MODE=pruned ;; *) die "Invalid node mode" ;; esac
    fi

    available=$(available_mib)
    is_uint "$available" || die "Could not determine available storage for $BITCOIN_HOME"
    if [[ $NODE_MODE == full ]]; then
        required=$(official_full_required_mib)
        say "Available storage: $(format_gib "$available")"
        say "Required for a full node, including 24 months of upper-range growth and associated data: $(format_gib "$required")"
        if ((available < required)); then
            if [[ $UNATTENDED == yes ]]; then
                die "Insufficient storage for full operation: $(format_gib "$available") available, $(format_gib "$required") required"
            fi
            read -r -p "Insufficient space. Return and select pruned operation? [Y/n]: " answer
            case ${answer:-y} in y|Y|yes|YES) NODE_MODE=pruned ;; *) die "Installation cancelled because full-node storage is insufficient" ;; esac
        fi
    fi

    if [[ $NODE_MODE == pruned ]]; then
        if [[ $UNATTENDED != yes ]]; then
            say "Available storage: $(format_gib "$available")"
            say "Recommended pruning target: 20480 MiB (20 GiB), plus at least $PRUNED_OVERHEAD_GIB GiB for chainstate, logs, and other data."
            read -r -p "Pruning target in MiB [$PRUNE_SIZE]: " answer
            PRUNE_SIZE=${answer:-$PRUNE_SIZE}
        fi
        is_uint "$PRUNE_SIZE" && ((${#PRUNE_SIZE} <= 12)) || die "Pruning target must be a practical integer value in MiB"
        PRUNE_SIZE=$((10#$PRUNE_SIZE))
        ((PRUNE_SIZE >= 550)) || die "Pruning target must be an integer of at least 550 MiB"
        minimum=$((PRUNE_SIZE + PRUNED_OVERHEAD_GIB * 1024))
        ((available >= minimum)) || die "Insufficient storage for pruning target: $(format_gib "$available") available, $(format_gib "$minimum") required including supporting data"
    fi
}

recommend_dbcache() {
    local mem_kib mem_gib
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    [[ -n $mem_kib ]] || die "Could not determine installed RAM from /proc/meminfo"
    mem_gib=$((mem_kib / 1024 / 1024))
    if ((mem_gib < 2)); then RECOMMENDED_DBCACHE=128
    elif ((mem_gib < 4)); then RECOMMENDED_DBCACHE=256
    elif ((mem_gib < 8)); then RECOMMENDED_DBCACHE=1024
    elif ((mem_gib < 16)); then RECOMMENDED_DBCACHE=2048
    else RECOMMENDED_DBCACHE=4096
    fi
    say "Installed RAM: $(awk -v kib="$mem_kib" 'BEGIN {printf "%.1f GiB", kib/1048576}')"
    say "Recommended dbcache: $RECOMMENDED_DBCACHE MiB"
    if [[ -z $DBCACHE ]]; then
        if [[ $UNATTENDED == yes ]]; then
            DBCACHE=$RECOMMENDED_DBCACHE
        else
            local answer
            read -r -p "dbcache in MiB [$RECOMMENDED_DBCACHE]: " answer
            DBCACHE=${answer:-$RECOMMENDED_DBCACHE}
        fi
    fi
    is_uint "$DBCACHE" && ((${#DBCACHE} <= 9)) || die "dbcache must be a practical integer value in MiB"
    DBCACHE=$((10#$DBCACHE))
    ((DBCACHE >= 4)) || die "dbcache must be an integer of at least 4 MiB"
    ((DBCACHE * 1024 < mem_kib)) || die "dbcache must be smaller than installed physical RAM"
}

choose_start() {
    [[ $UNATTENDED == yes || $START_SPECIFIED == yes ]] && return
    local answer
    read -r -p "Start Bitcoin Core after installation? [Y/n]: " answer
    case ${answer:-y} in y|Y|yes|YES) START_SERVICE=yes ;; n|N|no|NO) START_SERVICE=no ;; *) die "Invalid response" ;; esac
}

key_component_is_acceptable() {
    local primary_fpr=$1 signing_fpr=$2 records primary_record signing_record
    local type validity expiry capabilities fingerprint now record

    records=$(gpg --batch --with-colons --list-keys "$primary_fpr" 2>/dev/null |
        awk -F: '
            $1 == "pub" || $1 == "sub" {
                type=$1; validity=$2; expiry=$7; capabilities=$12
            }
            $1 == "fpr" {
                print type "|" validity "|" expiry "|" capabilities "|" $10
            }
        ')
    primary_record=$(awk -F'|' -v wanted="$primary_fpr" '$1=="pub" && $5==wanted {print; exit}' <<<"$records")
    signing_record=$(awk -F'|' -v wanted="$signing_fpr" '$5==wanted {print; exit}' <<<"$records")
    [[ -n $primary_record && -n $signing_record ]] || return 1

    now=$(date +%s)
    for record in "$primary_record" "$signing_record"; do
        IFS='|' read -r type validity expiry capabilities fingerprint <<<"$record"
        case $validity in e|r|d|i) return 1 ;; esac
        [[ -z $expiry || $expiry == 0 || $expiry -gt $now ]] || return 1
    done
    [[ $capabilities == *s* || $capabilities == *S* ]] || return 1
}

download_and_verify() {
    local base status_file fpr imported primary valid_count=0 signing_fpr signing_keyid accepted
    local signature_expiry now
    base=$DOWNLOAD_ROOT/bitcoin-core-$VERSION
    say "Downloading Bitcoin Core release metadata..."
    curl --fail --silent --show-error --location "$base/SHA256SUMS" -o "$WORK_DIR/SHA256SUMS"
    curl --fail --silent --show-error --location "$base/SHA256SUMS.asc" -o "$WORK_DIR/SHA256SUMS.asc"
    grep -Eq "^[0-9a-fA-F]{64}  $ARCHIVE$" "$WORK_DIR/SHA256SUMS" || die "No $BTC_ARCH binary is published for Bitcoin Core $VERSION"
    say "Downloading Bitcoin Core archive..."
    if [[ $UNATTENDED == yes ]]; then
        curl --fail --silent --show-error --location "$base/$ARCHIVE" -o "$WORK_DIR/$ARCHIVE"
    else
        curl --fail --show-error --location --progress-bar "$base/$ARCHIVE" -o "$WORK_DIR/$ARCHIVE"
    fi
    say "Retrieving Bitcoin Core release signer data..."
    git clone --quiet --depth 1 "$GUIX_SIGS_URL" "$WORK_DIR/guix.sigs"

    export GNUPGHOME=$WORK_DIR/gnupg
    mkdir -m 700 "$GNUPGHOME"
    for fpr in "${TRUSTED_FINGERPRINTS[@]}"; do
        imported=no
        while IFS= read -r keyfile; do
            if gpg --batch --with-colons --show-keys "$keyfile" 2>/dev/null | awk -F: -v wanted="$fpr" '$1=="fpr" && $10==wanted {found=1} END {exit !found}'; then
                gpg --batch --import "$keyfile" >/dev/null 2>&1
                imported=yes
                break
            fi
        done < <(find "$WORK_DIR/guix.sigs/builder-keys" -type f -print)
        [[ $imported == yes ]] || die "Trusted signer key $fpr was not found in guix.sigs"
        primary=$(gpg --batch --with-colons --list-keys "$fpr" | awk -F: '$1=="fpr" {print $10; exit}')
        [[ $primary == "$fpr" ]] || die "Imported key does not match trusted primary fingerprint $fpr"
    done

    status_file=$WORK_DIR/gpg-status
    say "Verifying Bitcoin Core release signatures..."
    gpg --batch --status-fd 1 --verify "$WORK_DIR/SHA256SUMS.asc" "$WORK_DIR/SHA256SUMS" >"$status_file" 2>"$WORK_DIR/gpg-errors" || true
    now=$(date +%s)
    for fpr in "${TRUSTED_FINGERPRINTS[@]}"; do
        accepted=no
        while read -r signing_fpr signature_expiry; do
            [[ -n $signing_fpr ]] || continue
            signing_keyid=${signing_fpr: -16}
            if grep -Eq "^\\[GNUPG:\\] (EXPSIG|EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG) $signing_keyid([[:space:]]|$)" "$status_file"; then
                continue
            fi
            [[ $signature_expiry == 0 || $signature_expiry -gt $now ]] || continue
            key_component_is_acceptable "$fpr" "$signing_fpr" || continue
            accepted=yes
            break
        done < <(awk -v wanted="$fpr" '$1=="[GNUPG:]" && $2=="VALIDSIG" && $12==wanted {print $3, $6}' "$status_file")
        if [[ $accepted == yes ]]; then
            valid_count=$((valid_count + 1))
        fi
    done
    ((valid_count >= 3)) || die "Only $valid_count trusted distinct signatures validated; at least 3 are required"

    say "Verifying Bitcoin Core archive checksum..."
    (cd "$WORK_DIR" && sha256sum --ignore-missing --check SHA256SUMS | grep -Fx "$ARCHIVE: OK" >/dev/null) || die "SHA256 verification failed for $ARCHIVE"
    ARCHIVE_SHA=$(sha256sum "$WORK_DIR/$ARCHIVE" | awk '{print $1}')
    say "Checking and extracting the Bitcoin Core archive..."
    tar -tzf "$WORK_DIR/$ARCHIVE" >/dev/null || die "The downloaded archive is invalid"
    tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR"
    [[ -x $WORK_DIR/bitcoin-$VERSION/bin/bitcoind && -x $WORK_DIR/bitcoin-$VERSION/bin/bitcoin-cli && -x $WORK_DIR/bitcoin-$VERSION/bin/bitcoin-wallet ]] || die "The release archive lacks required executable binaries"
    [[ -x $WORK_DIR/bitcoin-$VERSION/share/rpcauth/rpcauth.py ]] || die "The release archive lacks rpcauth.py"
    if [[ -f $WORK_DIR/bitcoin-$VERSION/bitcoin.conf ]]; then
        mv "$WORK_DIR/bitcoin-$VERSION/bitcoin.conf" "$WORK_DIR/bitcoin-$VERSION/bitcoin.conf.example"
    fi
}

prepare_files() {
    local rpc_output placeholder_count
    install -m 600 /dev/null "$WORK_DIR/rpcauth-output"
    "$WORK_DIR/bitcoin-$VERSION/share/rpcauth/rpcauth.py" dashboard >"$WORK_DIR/rpcauth-output"
    RPCAUTH_LINE=$(grep '^rpcauth=dashboard:' "$WORK_DIR/rpcauth-output")
    RPC_PASSWORD=$(awk '/^Your password:/{getline; print; exit}' "$WORK_DIR/rpcauth-output")
    [[ -n $RPCAUTH_LINE && -n $RPC_PASSWORD ]] || die "rpcauth.py did not produce the expected credentials"

    cp "$BITCOIN_CONF_TEMPLATE" "$WORK_DIR/bitcoin.conf"
    sed -i "s/^dbcache=.*/dbcache=$DBCACHE/" "$WORK_DIR/bitcoin.conf"
    if [[ $NODE_MODE == full ]]; then
        [[ $(grep -c '^txindex=1$' "$WORK_DIR/bitcoin.conf") -eq 1 ]] || die "Full-node configuration must contain exactly one txindex=1 setting"
        ! grep -q '^prune=' "$WORK_DIR/bitcoin.conf" || die "Full-node configuration cannot enable pruning"
    else
        sed -i "/^txindex=/d" "$WORK_DIR/bitcoin.conf"
        sed -i "/^server=1$/a\\
prune=$PRUNE_SIZE" "$WORK_DIR/bitcoin.conf"
    fi
    sed -i "/^rpcallowip=127.0.0.1$/a\\
$RPCAUTH_LINE" "$WORK_DIR/bitcoin.conf"
    [[ $(grep -c '^rpcauth=dashboard:' "$WORK_DIR/bitcoin.conf") -eq 1 ]] || die "Staged bitcoin.conf has an invalid rpcauth entry"
    if [[ $NODE_MODE == pruned ]]; then
        ! grep -q '^txindex=1$' "$WORK_DIR/bitcoin.conf" || die "Pruned configuration cannot enable txindex"
        grep -qx "prune=$PRUNE_SIZE" "$WORK_DIR/bitcoin.conf" || die "Pruned configuration is missing its pruning target"
    fi

    DASHBOARD_ORIGINAL_SHA=$(sha256sum "$DASHBOARD_RPC" | awk '{print $1}')
    cp "$DASHBOARD_RPC" "$WORK_DIR/bitcoin-rpc.php"
    placeholder_count=$(grep -Foc 'RPC-PASSWORD-HERE' "$WORK_DIR/bitcoin-rpc.php")
    [[ $placeholder_count -eq 1 ]] || die "Dashboard password placeholder changed during staging"
    RPC_PASSWORD=$RPC_PASSWORD awk '{gsub(/RPC-PASSWORD-HERE/, ENVIRON["RPC_PASSWORD"]); print}' "$WORK_DIR/bitcoin-rpc.php" >"$WORK_DIR/bitcoin-rpc.php.new"
    mv "$WORK_DIR/bitcoin-rpc.php.new" "$WORK_DIR/bitcoin-rpc.php"
    chmod 600 "$WORK_DIR/bitcoin.conf" "$WORK_DIR/bitcoin-rpc.php"
    cp --preserve=mode,ownership,timestamps "$DASHBOARD_RPC" "$WORK_DIR/bitcoin-rpc.php.original"
    chmod 600 "$WORK_DIR/bitcoin-rpc.php.original"
    cp "$SERVICE_TEMPLATE" "$WORK_DIR/bitcoind.service"
    cp "$LOGROTATE_TEMPLATE" "$WORK_DIR/logrotate-bitcoin"

    STAGED_CONF_SHA=$(sha256sum "$WORK_DIR/bitcoin.conf" | awk '{print $1}')
    STAGED_SERVICE_SHA=$(sha256sum "$WORK_DIR/bitcoind.service" | awk '{print $1}')
    STAGED_LOGROTATE_SHA=$(sha256sum "$WORK_DIR/logrotate-bitcoin" | awk '{print $1}')
    STAGED_DASHBOARD_SHA=$(sha256sum "$WORK_DIR/bitcoin-rpc.php" | awk '{print $1}')
}

record_phase() {
    install -d -m 700 "$STATE_DIR"
    {
        printf 'version=%s\n' "$VERSION"
        printf 'phase=%s\n' "$1"
        printf 'architecture=%s\n' "$BTC_ARCH"
        printf 'archive=%s\n' "$ARCHIVE"
        printf 'archive_sha256=%s\n' "$ARCHIVE_SHA"
        printf 'start_service=%s\n' "$START_SERVICE"
        printf 'bitcoin_conf_sha256=%s\n' "$STAGED_CONF_SHA"
        printf 'service_sha256=%s\n' "$STAGED_SERVICE_SHA"
        printf 'logrotate_sha256=%s\n' "$STAGED_LOGROTATE_SHA"
        printf 'dashboard_original_sha256=%s\n' "$DASHBOARD_ORIGINAL_SHA"
        printf 'dashboard_staged_sha256=%s\n' "$STAGED_DASHBOARD_SHA"
    } >"$INCOMPLETE_MARKER"
    chmod 600 "$INCOMPLETE_MARKER"
}

rollback() {
    local result=$? link
    trap - EXIT ERR INT TERM HUP
    if [[ $COMMIT_STARTED == yes && $COMMIT_COMPLETE != yes ]]; then
        warn "Installation did not complete; rolling back only artifacts created by this run"
        if [[ $SERVICE_MAY_BE_RUNNING == yes || $ENABLED_SERVICE == yes ]]; then
            systemctl stop bitcoind.service >/dev/null 2>&1 || warn "Could not confirm that Bitcoin Core stopped; installed files will be preserved"
            if systemctl is-active --quiet bitcoind.service || pgrep -x bitcoind >/dev/null 2>&1; then
                warn "Bitcoin Core is still running; preserving its binaries, configuration, and matching Dashboard RPC credentials for recovery"
                exit "$result"
            fi
            systemctl disable bitcoind.service >/dev/null 2>&1 || true
        fi
        if [[ -n $DASHBOARD_BACKUP && -f $DASHBOARD_BACKUP ]]; then cp --preserve=mode,ownership,timestamps "$DASHBOARD_BACKUP" "$DASHBOARD_RPC" || true; fi
        for link in "${CREATED_LINKS[@]}"; do [[ -L $link ]] && rm -f -- "$link"; done
        [[ $CREATED_CONF == yes && -f $BITCOIN_CONF ]] && rm -f -- "$BITCOIN_CONF"
        [[ $CREATED_SERVICE == yes && -f $BITCOIN_SERVICE ]] && rm -f -- "$BITCOIN_SERVICE"
        [[ $CREATED_LOGROTATE == yes && -f $BITCOIN_LOGROTATE ]] && rm -f -- "$BITCOIN_LOGROTATE"
        [[ $CREATED_ARCHIVE == yes && -f $INSTALL_ROOT/$ARCHIVE ]] && rm -f -- "$INSTALL_ROOT/$ARCHIVE"
        [[ $CREATED_VERSION_DIR == yes && -d $INSTALL_ROOT/bitcoin-$VERSION ]] && rm -rf -- "$INSTALL_ROOT/bitcoin-$VERSION"
        [[ $CREATED_LOG_DIR == yes && -d $BITCOIN_LOG_DIR ]] && rmdir -- "$BITCOIN_LOG_DIR" 2>/dev/null || true
        # Never recursively remove the data directory. It is removed only when
        # this run created it and it is still empty.
        [[ $CREATED_HOME == yes && -d $BITCOIN_HOME ]] && rmdir -- "$BITCOIN_HOME" 2>/dev/null || true
        [[ $CREATED_INSTALL_ROOT == yes && -d $INSTALL_ROOT ]] && rmdir -- "$INSTALL_ROOT" 2>/dev/null || true
        [[ $CREATED_USER == yes ]] && userdel "$BITCOIN_USER" 2>/dev/null || true
        [[ $CREATED_GROUP == yes ]] && groupdel "$BITCOIN_GROUP" 2>/dev/null || true
        rm -f -- "$INCOMPLETE_MARKER"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    [[ -n ${WORK_DIR:-} && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
    exit "$result"
}

ensure_bitcoin_account() {
    local user_entry group_entry
    group_entry=$(getent group "$BITCOIN_GROUP" || true)
    if [[ -z $group_entry ]]; then groupadd --system "$BITCOIN_GROUP"; CREATED_GROUP=yes; fi
    user_entry=$(getent passwd "$BITCOIN_USER" || true)
    if [[ -z $user_entry ]]; then
        useradd --system --gid "$BITCOIN_GROUP" --home-dir "$BITCOIN_HOME" --shell /usr/sbin/nologin "$BITCOIN_USER"
        CREATED_USER=yes
    else
        [[ $(id -gn "$BITCOIN_USER") == "$BITCOIN_GROUP" ]] || die "Existing bitcoin user does not have primary group bitcoin"
        [[ $(getent passwd "$BITCOIN_USER" | cut -d: -f6) == "$BITCOIN_HOME" ]] || die "Existing bitcoin user has an unexpected home directory"
        [[ $(getent passwd "$BITCOIN_USER" | cut -d: -f7) == /usr/sbin/nologin ]] || die "Existing bitcoin user has an unexpected login shell"
    fi
}

marker_value() {
    local key=$1
    [[ $(grep -c "^${key}=" "$INCOMPLETE_MARKER") -eq 1 ]] || return 1
    sed -n "s/^${key}=//p" "$INCOMPLETE_MARKER"
}

verify_recovery_file() {
    local path=$1 expected_sha=$2 description=$3
    [[ -f $path ]] || die "Recovery data is missing $description: $path"
    [[ $(sha256sum "$path" | awk '{print $1}') == "$expected_sha" ]] || \
        die "Recovery data failed integrity verification: $description"
}

install_or_verify_recovery_file() {
    local source=$1 target=$2 owner=$3 group=$4 mode=$5 description=$6
    if [[ -e $target ]]; then
        [[ -f $target && ! -L $target ]] || die "Unexpected $description at $target; no file was overwritten"
        cmp -s "$source" "$target" || die "$target differs from the staged $description; no file was overwritten"
        [[ $(stat -c '%U:%G:%a' "$target") == "$owner:$group:$mode" ]] || \
            die "$target has unexpected ownership or permissions; no file was overwritten"
    else
        install -o "$owner" -g "$group" -m "$mode" "$source" "$target"
    fi
}

load_recovery_state() {
    VERSION=$(marker_value version) || die "The Bitcoin Core recovery marker has no valid version"
    BTC_ARCH=$(marker_value architecture) || die "The Bitcoin Core recovery marker has no valid architecture"
    ARCHIVE=$(marker_value archive) || die "The Bitcoin Core recovery marker has no valid archive"
    ARCHIVE_SHA=$(marker_value archive_sha256) || die "The Bitcoin Core recovery marker has no archive checksum"
    START_SERVICE=$(marker_value start_service) || die "The Bitcoin Core recovery marker has no startup choice"
    STAGED_CONF_SHA=$(marker_value bitcoin_conf_sha256) || die "The Bitcoin Core recovery marker has no configuration checksum"
    STAGED_SERVICE_SHA=$(marker_value service_sha256) || die "The Bitcoin Core recovery marker has no service checksum"
    STAGED_LOGROTATE_SHA=$(marker_value logrotate_sha256) || die "The Bitcoin Core recovery marker has no logrotate checksum"
    DASHBOARD_ORIGINAL_SHA=$(marker_value dashboard_original_sha256) || die "The Bitcoin Core recovery marker has no original Dashboard checksum"
    STAGED_DASHBOARD_SHA=$(marker_value dashboard_staged_sha256) || die "The Bitcoin Core recovery marker has no staged Dashboard checksum"

    [[ $VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Invalid version in the Bitcoin Core recovery marker"
    [[ $BTC_ARCH =~ ^[a-z0-9_]+-linux-gnu(eabihf)?$ ]] || die "Invalid architecture in the Bitcoin Core recovery marker"
    [[ $ARCHIVE == "bitcoin-$VERSION-$BTC_ARCH.tar.gz" ]] || die "Invalid archive in the Bitcoin Core recovery marker"
    [[ $START_SERVICE == yes || $START_SERVICE == no ]] || die "Invalid startup choice in the Bitcoin Core recovery marker"
    for checksum in "$ARCHIVE_SHA" "$STAGED_CONF_SHA" "$STAGED_SERVICE_SHA" "$STAGED_LOGROTATE_SHA" "$DASHBOARD_ORIGINAL_SHA" "$STAGED_DASHBOARD_SHA"; do
        [[ $checksum =~ ^[0-9a-f]{64}$ ]] || die "Invalid checksum in the Bitcoin Core recovery marker"
    done
}

prepare_recovery_tree() {
    local archive_path expected_dir extraction_dir

    if [[ -f $WORK_DIR/$ARCHIVE ]]; then
        archive_path=$WORK_DIR/$ARCHIVE
    elif [[ -f $INSTALL_ROOT/$ARCHIVE ]]; then
        archive_path=$INSTALL_ROOT/$ARCHIVE
    else
        die "The authenticated Bitcoin Core archive is missing; partial files were left untouched"
    fi
    [[ $(sha256sum "$archive_path" | awk '{print $1}') == "$ARCHIVE_SHA" ]] || \
        die "The retained Bitcoin Core archive failed its recorded checksum"

    expected_dir=$WORK_DIR/bitcoin-$VERSION
    if [[ ! -d $expected_dir ]]; then
        extraction_dir=$WORK_DIR/recovery-extract
        [[ ! -e $extraction_dir ]] || rm -rf -- "$extraction_dir"
        install -d -m 0700 "$extraction_dir"
        tar -xzf "$archive_path" -C "$extraction_dir"
        expected_dir=$extraction_dir/bitcoin-$VERSION
        [[ -d $expected_dir ]] || die "The retained archive does not contain the expected Bitcoin Core directory"
        if [[ -f $expected_dir/bitcoin.conf ]]; then
            mv "$expected_dir/bitcoin.conf" "$expected_dir/bitcoin.conf.example"
        fi
    fi
    RECOVERY_EXPECTED_DIR=$expected_dir
}

recover_incomplete_installation() {
    local current_dashboard_sha link target

    say "Recovering an interrupted Bitcoin Core installation"
    WORK_DIR=$RECOVERY_WORK_DIR
    [[ -d $WORK_DIR && ! -L $WORK_DIR ]] || die "The persistent Bitcoin Core recovery directory is missing"
    [[ $(stat -c '%U:%G:%a' "$WORK_DIR") == root:root:700 ]] || die "The Bitcoin Core recovery directory has unsafe ownership or permissions"
    load_recovery_state

    verify_recovery_file "$WORK_DIR/bitcoin.conf" "$STAGED_CONF_SHA" "bitcoin.conf"
    verify_recovery_file "$WORK_DIR/bitcoind.service" "$STAGED_SERVICE_SHA" "systemd service"
    verify_recovery_file "$WORK_DIR/logrotate-bitcoin" "$STAGED_LOGROTATE_SHA" "logrotate configuration"
    verify_recovery_file "$WORK_DIR/bitcoin-rpc.php" "$STAGED_DASHBOARD_SHA" "Dashboard RPC configuration"
    verify_recovery_file "$WORK_DIR/bitcoin-rpc.php.original" "$DASHBOARD_ORIGINAL_SHA" "original Dashboard RPC configuration"
    [[ -f $DASHBOARD_RPC ]] || die "The installed Dashboard RPC configuration is missing"

    if systemctl is-active --quiet bitcoind.service || pgrep -x bitcoind >/dev/null 2>&1; then
        warn "Stopping Bitcoin Core before interrupted-installation recovery"
        systemctl stop bitcoind.service || die "Bitcoin Core could not be stopped; all installed files and credentials were preserved"
        if systemctl is-active --quiet bitcoind.service || pgrep -x bitcoind >/dev/null 2>&1; then
            die "Bitcoin Core is still running; all installed files and credentials were preserved"
        fi
    fi

    prepare_recovery_tree
    ensure_bitcoin_account
    if [[ ! -d $BITCOIN_HOME ]]; then install -d -m 750 -o bitcoin -g bitcoin "$BITCOIN_HOME"; fi
    [[ $(stat -c '%U:%G' "$BITCOIN_HOME") == bitcoin:bitcoin ]] || die "$BITCOIN_HOME has unexpected ownership"
    if [[ ! -d $BITCOIN_LOG_DIR ]]; then install -d -m 750 -o bitcoin -g bitcoin "$BITCOIN_LOG_DIR"; fi
    [[ $(stat -c '%U:%G' "$BITCOIN_LOG_DIR") == bitcoin:bitcoin ]] || die "$BITCOIN_LOG_DIR has unexpected ownership"
    install -d -m 755 "$INSTALL_ROOT"

    target=$INSTALL_ROOT/bitcoin-$VERSION
    if [[ -e $target ]]; then
        [[ -d $target && ! -L $target ]] || die "Unexpected versioned installation path $target"
        diff -qr "$RECOVERY_EXPECTED_DIR" "$target" >/dev/null || \
            die "$target differs from the authenticated release; no files were overwritten"
    else
        mv "$RECOVERY_EXPECTED_DIR" "$target"
        chown -R root:root "$target"
    fi

    if [[ -e $INSTALL_ROOT/$ARCHIVE ]]; then
        [[ -f $INSTALL_ROOT/$ARCHIVE && $(sha256sum "$INSTALL_ROOT/$ARCHIVE" | awk '{print $1}') == "$ARCHIVE_SHA" ]] || \
            die "The retained archive differs from its authenticated checksum"
    else
        mv "$WORK_DIR/$ARCHIVE" "$INSTALL_ROOT/$ARCHIVE"
        chown root:root "$INSTALL_ROOT/$ARCHIVE"
        chmod 0644 "$INSTALL_ROOT/$ARCHIVE"
    fi

    for link in bitcoind bitcoin-cli bitcoin-wallet; do
        if [[ -e $BIN_DIR/$link || -L $BIN_DIR/$link ]]; then
            [[ -L $BIN_DIR/$link && $(readlink -f "$BIN_DIR/$link") == "$target/bin/$link" ]] || \
                die "$BIN_DIR/$link is unexpected; no link was overwritten"
        else
            ln -s "$target/bin/$link" "$BIN_DIR/$link"
        fi
    done

    install_or_verify_recovery_file "$WORK_DIR/bitcoin.conf" "$BITCOIN_CONF" root bitcoin 640 "Bitcoin configuration"
    install_or_verify_recovery_file "$WORK_DIR/bitcoind.service" "$BITCOIN_SERVICE" root root 644 "systemd service"
    install_or_verify_recovery_file "$WORK_DIR/logrotate-bitcoin" "$BITCOIN_LOGROTATE" root root 644 "logrotate configuration"

    current_dashboard_sha=$(sha256sum "$DASHBOARD_RPC" | awk '{print $1}')
    if [[ $current_dashboard_sha == "$DASHBOARD_ORIGINAL_SHA" ]]; then
        install -m 640 -o root -g www-data "$WORK_DIR/bitcoin-rpc.php" "$DASHBOARD_RPC"
    elif [[ $current_dashboard_sha != "$STAGED_DASHBOARD_SHA" ]]; then
        die "$DASHBOARD_RPC was modified after interruption; no credential was overwritten"
    fi

    RPC_PASSWORD=$(sed -n "s/^[[:space:]]*'password'[[:space:]]*=>[[:space:]]*'\([^']*\)'.*/\1/p" "$WORK_DIR/bitcoin-rpc.php")
    RPCAUTH_LINE=$(grep '^rpcauth=dashboard:' "$WORK_DIR/bitcoin.conf")
    [[ -n $RPC_PASSWORD && -n $RPCAUTH_LINE ]] || die "Could not recover the staged RPC credentials"

    systemctl daemon-reload
    systemctl enable bitcoind.service >/dev/null
    verify_installation
    rm -rf -- "$WORK_DIR"
    say "Interrupted Bitcoin Core $VERSION installation recovered successfully."
    [[ $START_SERVICE == yes ]] && say "Bitcoin Core is running; blockchain synchronization will continue in the background." || say "Bitcoin Core is enabled and will start at the next boot."
}

commit_installation() {
    local target link
    COMMIT_STARTED=yes
    record_phase committing
    ensure_bitcoin_account

    if [[ ! -d $BITCOIN_HOME ]]; then install -d -m 750 -o bitcoin -g bitcoin "$BITCOIN_HOME"; CREATED_HOME=yes; fi
    if [[ ! -d $BITCOIN_LOG_DIR ]]; then install -d -m 750 -o bitcoin -g bitcoin "$BITCOIN_LOG_DIR"; CREATED_LOG_DIR=yes; fi
    if [[ ! -d $INSTALL_ROOT ]]; then install -d -m 755 "$INSTALL_ROOT"; CREATED_INSTALL_ROOT=yes; fi

    target=$INSTALL_ROOT/bitcoin-$VERSION
    [[ ! -e $target ]] || die "Versioned installation path appeared during installation: $target"
    mv "$WORK_DIR/bitcoin-$VERSION" "$target"
    CREATED_VERSION_DIR=yes
    chown -R root:root "$target"

    [[ ! -e $INSTALL_ROOT/$ARCHIVE ]] || die "Downloaded archive path appeared during installation: $INSTALL_ROOT/$ARCHIVE"
    mv "$WORK_DIR/$ARCHIVE" "$INSTALL_ROOT/$ARCHIVE"
    chmod 644 "$INSTALL_ROOT/$ARCHIVE"
    chown root:root "$INSTALL_ROOT/$ARCHIVE"
    CREATED_ARCHIVE=yes

    for link in bitcoind bitcoin-cli bitcoin-wallet; do
        [[ ! -e $BIN_DIR/$link && ! -L $BIN_DIR/$link ]] || die "Executable path appeared during installation: $BIN_DIR/$link"
        ln -s "$target/bin/$link" "$BIN_DIR/$link"
        CREATED_LINKS+=("$BIN_DIR/$link")
    done
    [[ -f $INSTALL_ROOT/$ARCHIVE ]] || die "The verified release archive was not retained"
    [[ $(stat -c '%U:%G:%a' "$INSTALL_ROOT/$ARCHIVE") == root:root:644 ]] || die "The retained release archive permissions are incorrect"

    install -m 640 -o root -g bitcoin "$WORK_DIR/bitcoin.conf" "$BITCOIN_CONF"; CREATED_CONF=yes
    install -m 644 -o root -g root "$WORK_DIR/bitcoind.service" "$BITCOIN_SERVICE"; CREATED_SERVICE=yes
    install -m 644 -o root -g root "$WORK_DIR/logrotate-bitcoin" "$BITCOIN_LOGROTATE"; CREATED_LOGROTATE=yes

    [[ $(sha256sum "$DASHBOARD_RPC" | awk '{print $1}') == "$DASHBOARD_ORIGINAL_SHA" ]] || die "$DASHBOARD_RPC changed during installation; refusing to overwrite it"
    DASHBOARD_BACKUP=$WORK_DIR/bitcoin-rpc.php.original
    install -m 640 -o root -g www-data "$WORK_DIR/bitcoin-rpc.php" "$DASHBOARD_RPC"

    record_phase configuring-systemd
    systemctl daemon-reload
    systemctl enable bitcoind.service >/dev/null
    ENABLED_SERVICE=yes
    record_phase verifying
}

verify_installation() {
    local link
    for link in bitcoind bitcoin-cli bitcoin-wallet; do
        [[ -x $BIN_DIR/$link ]] || die "$BIN_DIR/$link is not executable"
        [[ $(readlink -f "$BIN_DIR/$link") == "$INSTALL_ROOT/bitcoin-$VERSION/bin/$link" ]] || die "$BIN_DIR/$link resolves incorrectly"
    done
    [[ $(stat -c '%U:%G:%a' "$BITCOIN_CONF") == root:bitcoin:640 ]] || die "$BITCOIN_CONF permissions are incorrect"
    runuser -u bitcoin -- test -r "$BITCOIN_CONF" || die "The bitcoin service user cannot read $BITCOIN_CONF"
    [[ $(stat -c '%U:%G' "$BITCOIN_HOME") == bitcoin:bitcoin ]] || die "$BITCOIN_HOME ownership is incorrect"
    [[ $(stat -c '%U:%G' "$BITCOIN_LOG_DIR") == bitcoin:bitcoin ]] || die "$BITCOIN_LOG_DIR ownership is incorrect"
    systemctl is-enabled --quiet bitcoind.service || die "bitcoind.service is not enabled"
    grep -Fqx "$RPCAUTH_LINE" "$BITCOIN_CONF" || die "Bitcoin Core rpcauth entry is missing"
    grep -Fq "'password' => '$RPC_PASSWORD'" "$DASHBOARD_RPC" || die "Dashboard RPC password was not installed"

    if [[ $START_SERVICE == yes ]]; then
        SERVICE_MAY_BE_RUNNING=yes
        systemctl start bitcoind.service || { systemctl status bitcoind.service --no-pager >&2 || true; die "Bitcoin Core failed to start"; }
        systemctl is-active --quiet bitcoind.service || { systemctl status bitcoind.service --no-pager >&2 || true; die "Bitcoin Core is not active"; }
    fi
    COMMIT_COMPLETE=yes
    rm -f -- "$INCOMPLETE_MARKER"
}

main() {
    parse_args "$@"
    require_root
    if [[ -e $INCOMPLETE_MARKER ]]; then
        require_commands
        recover_incomplete_installation
        exit 0
    fi
    preflight_templates
    detect_existing_installation
    command -v apt-get >/dev/null 2>&1 || die "apt-get is required"
    command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query is required"
    install_dependencies
    require_commands
    if [[ -e $RECOVERY_WORK_DIR ]]; then
        warn "Removing staged Bitcoin Core files left before permanent installation began"
        rm -rf -- "$RECOVERY_WORK_DIR"
    fi
    install -d -o root -g root -m 0700 "$RECOVERY_WORK_DIR"
    WORK_DIR=$RECOVERY_WORK_DIR
    trap rollback EXIT ERR INT TERM HUP

    choose_version
    detect_architecture
    choose_node_mode
    recommend_dbcache
    choose_start
    say "Downloading and verifying Bitcoin Core $VERSION for $BTC_ARCH..."
    download_and_verify
    prepare_files
    commit_installation
    verify_installation
    say "Bitcoin Core $VERSION was installed successfully."
    [[ $START_SERVICE == yes ]] && say "Bitcoin Core is running; blockchain synchronization will continue in the background." || say "Bitcoin Core is enabled and will start at the next boot."
}

main "$@"
