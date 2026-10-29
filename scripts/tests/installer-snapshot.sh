#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ROOT_DIR=$(cd "$TEST_DIR/../.." && pwd)
readonly TEMPORARY_DIR=$(mktemp -d)
readonly UNTRACKED_RELATIVE=installers/apps/explorer/.snapshot-test-untracked-$$
readonly UNTRACKED_SOURCE=$ROOT_DIR/$UNTRACKED_RELATIVE
readonly SNAPSHOT=$TEMPORARY_DIR/node-installer

cleanup() {
    rm -f -- "$UNTRACKED_SOURCE"
    rm -rf -- "$TEMPORARY_DIR"
}
trap cleanup EXIT

printf 'untracked runtime snapshot test\n' >"$UNTRACKED_SOURCE"
"$ROOT_DIR/scripts/stage-installer-snapshot.sh" "$SNAPSHOT" >"$TEMPORARY_DIR/info"

cmp -s "$ROOT_DIR/firstboot/setup" "$SNAPSHOT/firstboot/setup"
cmp -s "$UNTRACKED_SOURCE" "$SNAPSHOT/$UNTRACKED_RELATIVE"
if ! git -C "$ROOT_DIR" diff --quiet -- firstboot/setup; then
    printf 'verified modified tracked runtime file inclusion\n'
fi
[[ ! -e $SNAPSHOT/firstboot/tests/app-catalog.sh ]]
[[ ! -e $SNAPSHOT/installers/apps/explorer/tests/recovery.sh ]]
[[ ! -e $SNAPSHOT/installers/.DS_Store ]]
grep -qx 'installer_dirty=yes' "$TEMPORARY_DIR/info"
grep -Eq '^installer_commit=[0-9a-f]{40}$' "$TEMPORARY_DIR/info"
grep -Eq '^installer_snapshot_sha256=[0-9a-f]{64}$' "$TEMPORARY_DIR/info"

(
    cd "$SNAPSHOT"
    sha256sum --quiet -c installer-files.sha256
    sha256sum --quiet -c installer-snapshot.sha256
)

if find "$SNAPSHOT" -type l -print -quit | grep -q .; then
    printf 'snapshot unexpectedly contains a symbolic link\n' >&2
    exit 1
fi
if find "$SNAPSHOT" -perm -0022 -print -quit | grep -q .; then
    printf 'snapshot unexpectedly contains a group/world-writable path\n' >&2
    exit 1
fi

printf 'installer snapshot tests passed\n'
