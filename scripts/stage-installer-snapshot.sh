#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

PROGRAM=${0##*/}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
    printf 'Usage: %s DESTINATION\n' "$PROGRAM"
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(($# == 1)) || { usage >&2; exit 2; }
DESTINATION=$1
[[ ! -e $DESTINATION ]] || die "Snapshot destination already exists: $DESTINATION"

for command_name in awk cp dirname find git grep install sha256sum sort; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

INSTALLER_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null) || die "Cannot determine the installer Git commit"
[[ $INSTALLER_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "Git returned an invalid installer commit"

INSTALLER_DIRTY=no
if [[ -n $(git -C "$ROOT_DIR" status --porcelain --untracked-files=all -- \
        firstboot installers scripts/build-iso.sh scripts/stage-installer-snapshot.sh debian/preseed.cfg) ]]; then
    INSTALLER_DIRTY=yes
fi

if find "$ROOT_DIR/firstboot" "$ROOT_DIR/installers" -type l -print -quit | grep -q .; then
    die "Runtime installer sources must not contain symbolic links"
fi

install -d -m 0755 "$DESTINATION"
SOURCE_LIST=$DESTINATION/.source-files
find "$ROOT_DIR/firstboot" "$ROOT_DIR/installers" -type f \
    ! -path '*/tests/*' \
    ! -name '.DS_Store' \
    ! -name '*.swp' \
    ! -name '*~' -print | sort >"$SOURCE_LIST"

while IFS= read -r source; do
    relative=${source#"$ROOT_DIR/"}
    [[ $relative != "$source" && $relative != *$'\n'* ]] || die "Unsafe runtime source path: $source"
    install -d -m 0755 "$DESTINATION/$(dirname "$relative")"
    if [[ -x $source ]]; then mode=0755; else mode=0644; fi
    install -m "$mode" "$source" "$DESTINATION/$relative"
done <"$SOURCE_LIST"
rm -f -- "$SOURCE_LIST"

cat >"$DESTINATION/installer-build-info" <<EOF
installer_commit=$INSTALLER_COMMIT
installer_dirty=$INSTALLER_DIRTY
EOF
chmod 0644 "$DESTINATION/installer-build-info"

(
    cd "$DESTINATION"
    find firstboot installers -type f -print | sort | while IFS= read -r file; do
        sha256sum "$file"
    done
    sha256sum installer-build-info
) >"$DESTINATION/installer-files.sha256"
chmod 0644 "$DESTINATION/installer-files.sha256"

(
    cd "$DESTINATION"
    sha256sum installer-files.sha256
) >"$DESTINATION/installer-snapshot.sha256"
chmod 0644 "$DESTINATION/installer-snapshot.sha256"

printf 'installer_commit=%s\n' "$INSTALLER_COMMIT"
printf 'installer_dirty=%s\n' "$INSTALLER_DIRTY"
printf 'installer_snapshot_sha256=%s\n' "$(sha256sum "$DESTINATION/installer-files.sha256" | awk '{print $1}')"
