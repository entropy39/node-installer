#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPOSITORY_URL="https://github.com/entropy39/dashboard.git"
readonly REPOSITORY_BRANCH="main"

readonly INSTALL_PARENT="/srv/www"
readonly INSTALL_DIR="${INSTALL_PARENT}/dashboard"
readonly INCOMPLETE_MARKER="${INSTALL_DIR}/.entropy39-install-incomplete"
readonly INSTALLED_COMMIT_RECORD="/var/lib/entropy39-node/dashboard-installed-commit"
readonly APACHE_SITE="/etc/apache2/sites-available/dashboard.conf"
readonly SHUTDOWND_DIR="/usr/local/lib/shutdownd"
readonly SHUTDOWND_SCRIPT="${SHUTDOWND_DIR}/shutdownd.py"
readonly SHUTDOWND_UNIT="/etc/systemd/system/shutdownd.service"

work_dir=""
recovery_mode=false

log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        rm -rf -- "${work_dir}"
    fi
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

report_existing_installation() {
    local installed_commit="unknown"

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        installed_commit="$(git -C "${INSTALL_DIR}" rev-parse HEAD 2>/dev/null || true)"
        [[ -n "${installed_commit}" ]] || installed_commit="unknown"
    fi

    log "Dashboard is already installed at ${INSTALL_DIR} (commit: ${installed_commit})."
    log "No files were changed. Dashboard updates must use the separate update mechanism."
}

acquire_install_lock() {
    require_command flock
    exec 9>/run/lock/entropy39-dashboard-install.lock
    flock -n 9 || die "Another dashboard installation is already running."
}

remove_stale_staging_directories() {
    local stale_dir

    shopt -s nullglob
    for stale_dir in \
        "${INSTALL_PARENT}"/.dashboard-install.* \
        "${INSTALL_PARENT}"/.dashboard-recovery.*; do
        [[ -d "${stale_dir}" ]] || continue
        log "Removing stale installer staging directory ${stale_dir}"
        rm -rf -- "${stale_dir}"
    done
    shopt -u nullglob
}

load_recovery_state() {
    read -r source_branch source_commit <"${INCOMPLETE_MARKER}" || \
        die "Cannot read the incomplete-installation marker at ${INCOMPLETE_MARKER}."

    [[ "${source_branch}" == "${REPOSITORY_BRANCH}" ]] || \
        die "The incomplete-installation marker contains an unexpected source branch."
    [[ "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || \
        die "The incomplete-installation marker contains an invalid commit ID."
    [[ -d "${INSTALL_DIR}/.git" ]] || \
        die "The incomplete dashboard installation has no Git metadata and cannot be recovered safely."
    [[ "$(git -C "${INSTALL_DIR}" rev-parse HEAD 2>/dev/null)" == "${source_commit}" ]] || \
        die "The incomplete dashboard installation no longer matches its recorded commit. No files were changed."
    [[ -f "${INSTALL_DIR}/config/bitcoin-rpc.example.php" ]] || \
        die "The incomplete dashboard installation is missing its RPC configuration template."
    [[ -f "${INSTALL_DIR}/docs/examples/shutdownd/shutdownd.py" ]] || \
        die "The incomplete dashboard installation is missing shutdownd.py."
    [[ -f "${INSTALL_DIR}/docs/examples/shutdownd/shutdownd.service" ]] || \
        die "The incomplete dashboard installation is missing shutdownd.service."
    recovery_mode=true
    log "Detected an incomplete Dashboard installation at commit ${source_commit}. Its integrity will be verified before recovery."
}

check_preflight() {
    [[ "${EUID}" -eq 0 ]] || die "This installer must be run as root."

    [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] || \
        die "This installer supports Debian 13 only."

    case "$(dpkg --print-architecture)" in
        arm64|amd64) ;;
        *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
    esac

    [[ -d /run/systemd/system ]] || die "systemd is not running."
    require_command systemctl
    require_command apache2ctl
    require_command a2ensite
    require_command a2dissite
    acquire_install_lock

    dpkg-query -W -f='${Status}\n' apache2 2>/dev/null | grep -qx 'install ok installed' || \
        die "Apache2 must be installed before running this installer."
    systemctl is-active --quiet apache2 || die "Apache2 is installed but is not active."

    if [[ -e "${INSTALL_DIR}" ]]; then
        if [[ -f "${INCOMPLETE_MARKER}" ]]; then
            require_command git
            load_recovery_state
        else
            report_existing_installation
            exit 0
        fi
    fi

    if ${recovery_mode}; then
        remove_stale_staging_directories
    else
        [[ ! -e "${APACHE_SITE}" ]] || \
            die "${APACHE_SITE} already exists but ${INSTALL_DIR} does not. Resolve this partial installation first."
        mkdir -p "${INSTALL_PARENT}"
        remove_stale_staging_directories
    fi

    getent group www-data >/dev/null || die "The Apache group www-data does not exist."
    [[ "$(getent group www-data | cut -d: -f3)" == "33" ]] || \
        die "The shutdown daemon expects the Debian www-data group to have GID 33."
}

check_recovery_dependencies() {
    local command_name

    for command_name in curl git php python3; do
        require_command "${command_name}"
    done
    php -m | grep -Fqx curl || die "The PHP cURL extension is not enabled."
}

install_dependencies() {
    log "Installing dashboard dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libapache2-mod-php \
        php \
        php-curl \
        python3

    require_command curl
    require_command git
    require_command php
    php -m | grep -Fqx curl || die "The PHP cURL extension is not enabled."
}

enable_php_module() {
    local module_file module_name

    module_file="$(find /etc/apache2/mods-available -maxdepth 1 -type f -name 'php*.load' -print | sort -V | tail -n 1)"
    [[ -n "${module_file}" ]] || die "No Apache PHP module was installed."
    module_name="$(basename "${module_file}" .load)"
    a2enmod "${module_name}" >/dev/null
}

download_and_verify_source() {
    work_dir="$(mktemp -d "${INSTALL_PARENT}/.dashboard-install.XXXXXX")"
    chmod 0700 "${work_dir}"

    log "Downloading the current ${REPOSITORY_BRANCH} branch into a staging directory"
    git -C "${work_dir}" init --quiet dashboard
    git -C "${work_dir}/dashboard" remote add origin "${REPOSITORY_URL}"
    git -C "${work_dir}/dashboard" fetch --quiet --depth 1 origin \
        "refs/heads/${REPOSITORY_BRANCH}" || \
        die "Could not fetch the Dashboard ${REPOSITORY_BRANCH} branch."
    source_commit="$(git -C "${work_dir}/dashboard" rev-parse FETCH_HEAD^{commit})"
    [[ "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || die "Git returned an invalid Dashboard commit ID."
    git -C "${work_dir}/dashboard" checkout --quiet --detach "${source_commit}"
    git -C "${work_dir}/dashboard" fsck --full --no-dangling >/dev/null || \
        die "The downloaded Dashboard Git object database failed its integrity check."
    git -C "${work_dir}/dashboard" diff --quiet "${source_commit}" -- . || \
        die "The downloaded Dashboard working tree does not match commit ${source_commit}."
    log "Selected Dashboard commit: ${source_commit}"

    [[ -f "${work_dir}/dashboard/config/bitcoin-rpc.example.php" ]] || \
        die "The downloaded Dashboard source is missing config/bitcoin-rpc.example.php."
    [[ -f "${work_dir}/dashboard/docs/examples/shutdownd/shutdownd.py" ]] || \
        die "The downloaded Dashboard source is missing shutdownd.py."
    [[ -f "${work_dir}/dashboard/docs/examples/shutdownd/shutdownd.service" ]] || \
        die "The downloaded Dashboard source is missing shutdownd.service."
}

verify_recovery_source() {
    local untracked_file
    local -a unexpected_untracked_files=()

    log "Verifying the incomplete Dashboard source before recovery"
    git -C "${INSTALL_DIR}" fsck --full --no-dangling >/dev/null || \
        die "The incomplete dashboard Git object database failed its integrity check. No files were changed."

    git -C "${INSTALL_DIR}" cat-file -e "${source_commit}^{commit}" 2>/dev/null || \
        die "The recorded Dashboard commit is missing from the incomplete installation. No files were changed."
    git -C "${INSTALL_DIR}" diff --quiet "${source_commit}" -- . || \
        die "Tracked dashboard files were modified after the interrupted installation. They will not be overwritten."

    while IFS= read -r -d '' untracked_file; do
        case "${untracked_file}" in
            .entropy39-install-incomplete|config/bitcoin-rpc.php) ;;
            *) unexpected_untracked_files+=("${untracked_file}") ;;
        esac
    done < <(git -C "${INSTALL_DIR}" ls-files --others -z)

    if [[ "${#unexpected_untracked_files[@]}" -ne 0 ]]; then
        printf 'ERROR: Unexpected untracked files were found in the incomplete dashboard installation:\n' >&2
        printf '  %s\n' "${unexpected_untracked_files[@]}" >&2
        die "Recovery stopped without deleting or overwriting these files."
    fi
    log "The incomplete Dashboard Git data and application files are intact."
}

check_existing_shutdown_files() {
    local source_script source_unit

    if ${recovery_mode}; then
        source_script="${INSTALL_DIR}/docs/examples/shutdownd/shutdownd.py"
        source_unit="${INSTALL_DIR}/docs/examples/shutdownd/shutdownd.service"
    else
        source_script="${work_dir}/dashboard/docs/examples/shutdownd/shutdownd.py"
        source_unit="${work_dir}/dashboard/docs/examples/shutdownd/shutdownd.service"
    fi

    if [[ -e "${SHUTDOWND_SCRIPT}" ]] && ! cmp -s "${source_script}" "${SHUTDOWND_SCRIPT}"; then
        die "${SHUTDOWND_SCRIPT} already exists and differs from the Dashboard source."
    fi
    if [[ -e "${SHUTDOWND_UNIT}" ]] && ! cmp -s "${source_unit}" "${SHUTDOWND_UNIT}"; then
        die "${SHUTDOWND_UNIT} already exists and differs from the Dashboard source."
    fi
}

prepare_and_install_application() {
    local staged_dashboard
    staged_dashboard="${work_dir}/dashboard"

    log "Preparing dashboard configuration and permissions"
    cp "${staged_dashboard}/config/bitcoin-rpc.example.php" \
        "${staged_dashboard}/config/bitcoin-rpc.php"
    chown -R root:root "${staged_dashboard}"
    chmod -R go-w "${staged_dashboard}"
    chown root:www-data "${staged_dashboard}/config/bitcoin-rpc.php"
    chmod 0640 "${staged_dashboard}/config/bitcoin-rpc.php"
    printf '%s %s\n' "${REPOSITORY_BRANCH}" "${source_commit}" > \
        "${staged_dashboard}/.entropy39-install-incomplete"
    chmod 0600 "${staged_dashboard}/.entropy39-install-incomplete"

    log "Installing dashboard at ${INSTALL_DIR}"
    mv "${staged_dashboard}" "${INSTALL_DIR}"
}

prepare_recovered_configuration() {
    if [[ ! -e "${INSTALL_DIR}/config/bitcoin-rpc.php" ]]; then
        log "Restoring the missing placeholder Bitcoin RPC configuration"
        cp "${INSTALL_DIR}/config/bitcoin-rpc.example.php" \
            "${INSTALL_DIR}/config/bitcoin-rpc.php"
    fi
    chown root:www-data "${INSTALL_DIR}/config/bitcoin-rpc.php"
    chmod 0640 "${INSTALL_DIR}/config/bitcoin-rpc.php"
}

install_apache_site() {
    local apache_config site_created=false
    local dashboard_was_enabled=false default_was_enabled=false
    apache_config="${INSTALL_DIR}/docs/examples/apache/dashboard.conf"

    log "Installing the dashboard Apache virtual host"
    [[ -f "${apache_config}" ]] || die "The Dashboard source is missing ${apache_config}."
    if [[ -e "${APACHE_SITE}" ]]; then
        cmp -s "${apache_config}" "${APACHE_SITE}" || \
            die "${APACHE_SITE} exists and differs from the required configuration. No file was overwritten."
    else
        install -o root -g root -m 0644 "${apache_config}" "${APACHE_SITE}"
        site_created=true
    fi

    [[ -L /etc/apache2/sites-enabled/dashboard.conf ]] && dashboard_was_enabled=true
    [[ -L /etc/apache2/sites-enabled/000-default.conf ]] && default_was_enabled=true

    enable_php_module
    a2ensite dashboard.conf >/dev/null
    a2dissite 000-default.conf >/dev/null

    log "Testing the Apache configuration"
    if ! apache2ctl configtest; then
        if ! ${dashboard_was_enabled}; then
            a2dissite dashboard.conf >/dev/null || true
        fi
        if ${default_was_enabled}; then
            a2ensite 000-default.conf >/dev/null || true
        fi
        if ${site_created}; then
            rm -f -- "${APACHE_SITE}"
        fi
        die "Apache rejected the dashboard configuration. Previous site enablement was restored."
    fi
    systemctl reload apache2
}

install_shutdown_daemon() {
    local source_script source_unit
    source_script="${INSTALL_DIR}/docs/examples/shutdownd/shutdownd.py"
    source_unit="${INSTALL_DIR}/docs/examples/shutdownd/shutdownd.service"

    log "Installing and starting the dashboard shutdown daemon"
    install -d -o root -g root -m 0755 "${SHUTDOWND_DIR}"
    install -o root -g root -m 0755 "${source_script}" "${SHUTDOWND_SCRIPT}"
    install -o root -g root -m 0644 "${source_unit}" "${SHUTDOWND_UNIT}"

    systemctl daemon-reload
    systemctl enable --now shutdownd.service
}

verify_installation() {
    local attempt dashboard_page status_json socket_owner socket_mode

    log "Verifying the installation"
    systemctl is-active --quiet apache2 || die "Apache2 is not active after installation."
    systemctl is-active --quiet shutdownd.service || die "shutdownd is not active after installation."

    for ((attempt = 0; attempt < 20; attempt++)); do
        [[ -S /run/shutdownd.sock ]] && break
        sleep 0.5
    done
    [[ -S /run/shutdownd.sock ]] || \
        die "shutdownd did not create /run/shutdownd.sock within 10 seconds."
    socket_owner="$(stat -c '%U:%G' /run/shutdownd.sock)"
    socket_mode="$(stat -c '%a' /run/shutdownd.sock)"
    [[ "${socket_owner}" == "root:www-data" ]] || \
        die "Unexpected shutdown socket ownership: ${socket_owner}"
    [[ "${socket_mode}" == "660" ]] || die "Unexpected shutdown socket mode: ${socket_mode}"

    dashboard_page="$(curl --fail --show-error --silent http://127.0.0.1/)" || \
        die "The dashboard did not return a successful HTTP response."
    grep -Fq '<title>Entropy39</title>' <<<"${dashboard_page}" || \
        die "The HTTP response did not contain the expected dashboard page."

    status_json="$(curl --fail --show-error --silent \
        http://127.0.0.1/api/bitcoin-node-status.php)" || \
        die "The Bitcoin status endpoint did not return a successful HTTP response."
    bitcoin_status="$(php -r '
        $response = json_decode(stream_get_contents(STDIN), true);
        if (!is_array($response) || ($response["ok"] ?? false) !== true) {
            exit(1);
        }
        $status = $response["data"]["service"]["status"] ?? null;
        if (!is_string($status) || $status === "") {
            exit(1);
        }
        echo $status;
    ' <<<"${status_json}")" || die "The Bitcoin status endpoint returned invalid data."
}

print_summary() {
    printf '\nDashboard installation completed successfully.\n'
    printf '  Branch:                %s\n' "${REPOSITORY_BRANCH}"
    printf '  Commit:                %s\n' "${source_commit}"
    printf '  Apache:               active; configuration valid\n'
    printf '  Dashboard HTTP:       OK\n'
    printf '  Bitcoin status:       %s\n' "${bitcoin_status}"
    printf '  Shutdown service:     active\n'
}

complete_installation() {
    install -d -o root -g root -m 0755 "$(dirname "${INSTALLED_COMMIT_RECORD}")"
    printf '%s\n' "${source_commit}" >"${INSTALLED_COMMIT_RECORD}"
    chown root:root "${INSTALLED_COMMIT_RECORD}"
    chmod 0644 "${INSTALLED_COMMIT_RECORD}"
    rm -f -- "${INCOMPLETE_MARKER}"
}

main() {
    check_preflight
    if ${recovery_mode}; then
        check_recovery_dependencies
        work_dir="$(mktemp -d "${INSTALL_PARENT}/.dashboard-recovery.XXXXXX")"
        chmod 0700 "${work_dir}"
        verify_recovery_source
        prepare_recovered_configuration
    else
        install_dependencies
        download_and_verify_source
    fi
    check_existing_shutdown_files
    ${recovery_mode} || prepare_and_install_application
    install_apache_site
    install_shutdown_daemon
    verify_installation
    complete_installation
    print_summary
}

main "$@"
