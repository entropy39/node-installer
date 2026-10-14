#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: install-firstboot.sh must run as root.\n' >&2
    exit 1
fi

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
