#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ROOT_DIR=$(cd "$TEST_DIR/../.." && pwd)

grep -Fq -- '-map "$INSTALLER_SNAPSHOT" /entropy39/node-installer' "$ROOT_DIR/scripts/build-iso.sh"
grep -Fq 'cp -r /cdrom/entropy39/node-installer /target/root/node-installer' "$ROOT_DIR/debian/preseed.cfg"
grep -Fq 'install-firstboot.sh /root/node-installer' "$ROOT_DIR/debian/preseed.cfg"
grep -Fq 'verify_installer_snapshot' "$ROOT_DIR/firstboot/firstboot"
grep -Fq '"$INSTALL_DIR/firstboot/setup"' "$ROOT_DIR/firstboot/firstboot"

if grep -Eq 'github[.]com/entropy39/node-installer|git[[:space:]]+(fetch|clone)' \
        "$ROOT_DIR/firstboot/firstboot" "$ROOT_DIR/firstboot/install-firstboot.sh"; then
    printf 'first-boot bootstrap still contains a GitHub retrieval path\n' >&2
    exit 1
fi

printf 'bootstrap snapshot tests passed\n'
