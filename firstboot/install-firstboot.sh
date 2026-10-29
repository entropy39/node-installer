#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: install-firstboot.sh must run as root.\n' >&2
    exit 1
fi

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snapshot_source=${1:-}
readonly INSTALL_DIR=/usr/local/lib/node-installer
readonly STAGING_DIR=/usr/local/lib/node-installer.staging
readonly STAGING_MARKER=$STAGING_DIR/.entropy39-snapshot-staging
readonly STATE_DIR=/var/lib/entropy39-node

metadata_value() {
    local directory=$1 key=$2
    [[ $(grep -c "^${key}=" "$directory/installer-build-info") -eq 1 ]] || return 1
    sed -n "s/^${key}=//p" "$directory/installer-build-info"
}

verify_snapshot() {
    local directory=$1
    [[ -d $directory && ! -L $directory ]] || return 1
    [[ -f $directory/installer-build-info && -f $directory/installer-files.sha256 && \
       -f $directory/installer-snapshot.sha256 ]] || return 1
    ! find "$directory" -type l -print -quit | grep -q . || return 1
    ! find "$directory" ! -user root -print -quit | grep -q . || return 1
    ! find "$directory" -perm /022 -print -quit | grep -q . || return 1
    (cd "$directory" && sha256sum --quiet -c installer-files.sha256 && \
        sha256sum --quiet -c installer-snapshot.sha256) || return 1
    [[ -x $directory/firstboot/setup && -r $directory/firstboot/app-catalog.sh ]] || return 1
}

deploy_snapshot() {
    local commit dirty snapshot_sha temporary
    [[ -n $snapshot_source ]] || {
        printf 'ERROR: install-firstboot.sh requires the embedded installer snapshot path.\n' >&2
        exit 1
    }
    [[ -d $snapshot_source && ! -L $snapshot_source ]] || {
        printf 'ERROR: Embedded installer snapshot is missing or unsafe.\n' >&2
        exit 1
    }

    if [[ -e $INSTALL_DIR ]]; then
        verify_snapshot "$INSTALL_DIR" || {
            printf 'ERROR: Existing installer snapshot failed verification and was left untouched.\n' >&2
            exit 1
        }
    else
        if [[ -e $STAGING_DIR ]]; then
            [[ -f $STAGING_MARKER ]] || {
                printf 'ERROR: Unexpected installer staging path was left untouched.\n' >&2
                exit 1
            }
            rm -rf -- "$STAGING_DIR"
        fi
        install -d -o root -g root -m 0700 "$STAGING_DIR"
        touch "$STAGING_MARKER"
        cp -a "$snapshot_source/." "$STAGING_DIR/"
        chown -R root:root "$STAGING_DIR"
        chmod -R go-w "$STAGING_DIR"
        verify_snapshot "$STAGING_DIR" || {
            printf 'ERROR: Embedded installer snapshot failed verification.\n' >&2
            exit 1
        }
        rm -f -- "$STAGING_MARKER"
        chmod 0755 "$STAGING_DIR"
        mv "$STAGING_DIR" "$INSTALL_DIR"
    fi

    commit=$(metadata_value "$INSTALL_DIR" installer_commit) || exit 1
    dirty=$(metadata_value "$INSTALL_DIR" installer_dirty) || exit 1
    snapshot_sha=$(sha256sum "$INSTALL_DIR/installer-files.sha256" | awk '{print $1}')
    [[ $commit =~ ^[0-9a-f]{40}$ && ( $dirty == yes || $dirty == no ) && $snapshot_sha =~ ^[0-9a-f]{64}$ ]] || {
        printf 'ERROR: Installer snapshot provenance is invalid.\n' >&2
        exit 1
    }

    install -d -o root -g root -m 0755 "$STATE_DIR"
    for record in \
        "installer-commit:$commit" \
        "installer-dirty:$dirty" \
        "installer-snapshot-sha256:$snapshot_sha"; do
        name=${record%%:*}
        value=${record#*:}
        temporary=$STATE_DIR/${name}.new
        printf '%s\n' "$value" >"$temporary"
        chown root:root "$temporary"
        chmod 0644 "$temporary"
        mv -f -- "$temporary" "$STATE_DIR/$name"
    done
}

deploy_snapshot

install -o root -g root -m 0755 \
    "${source_dir}/firstboot" \
    /usr/local/sbin/firstboot
install -o root -g root -m 0755 \
    "${source_dir}/firstboot-cleanup" \
    /usr/local/sbin/firstboot-cleanup
install -o root -g root -m 0644 \
    "${source_dir}/firstboot.service" \
    /etc/systemd/system/firstboot.service
install -o root -g root -m 0644 \
    "${source_dir}/getty-restore.service" \
    /etc/systemd/system/getty-restore.service
install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
install -o root -g root -m 0644 \
    "${source_dir}/99-no-root-login.conf" \
    /etc/ssh/sshd_config.d/99-no-root-login.conf
install -d -o root -g root -m 0755 \
    /etc/systemd/system/getty@tty1.service.d
install -o root -g root -m 0644 \
    "${source_dir}/firstboot.conf" \
    /etc/systemd/system/getty@tty1.service.d/firstboot.conf

systemctl enable getty@tty1.service
systemctl enable firstboot.service
