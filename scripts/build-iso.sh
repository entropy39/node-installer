#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

PROGRAM=${0##*/}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEBIAN_CD_KEY_URL=https://www.debian.org/CD/key-DA87E80D6294BE9B.txt
DEBIAN_CD_KEY_FINGERPRINT=DF9B9C49EAA9298432589D76DA87E80D6294BE9B
ARCHITECTURE=arm64
OUTPUT_DIR=$ROOT_DIR/build
CACHE_DIR=$ROOT_DIR/cache
MIRROR=https://cdimage.debian.org/debian-cd/current

usage() {
    cat <<EOF
Usage: $PROGRAM [--architecture arm64|amd64] [--output-dir DIR] [--cache-dir DIR]

Build an Entropy39 installer from the current official Debian 13 netinst ISO.
The Debian checksum signature and ISO SHA-512 checksum are verified before the
image is modified. ARM64 is the default architecture.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

while (($#)); do
    case $1 in
        --architecture)
            (($# >= 2)) || die "--architecture requires a value"
            ARCHITECTURE=$2
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || die "--output-dir requires a value"
            OUTPUT_DIR=$2
            shift 2
            ;;
        --cache-dir)
            (($# >= 2)) || die "--cache-dir requires a value"
            CACHE_DIR=$2
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

case $ARCHITECTURE in
    arm64) INSTALLER_PATH=install.a64 ;;
    amd64) INSTALLER_PATH=install.amd ;;
    *) die "Supported architectures are arm64 and amd64" ;;
esac

for command_name in awk curl find gpg grep md5sum sed sha512sum sort xorriso; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/entropy39-iso.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT

BASE_URL=$MIRROR/$ARCHITECTURE/iso-cd
SUMS=$CACHE_DIR/debian-$ARCHITECTURE-SHA512SUMS
SIGNATURE=$CACHE_DIR/debian-$ARCHITECTURE-SHA512SUMS.sign
KEY_FILE=$CACHE_DIR/debian-cd-signing-key.asc
GPG_HOME=$WORK_DIR/gnupg

log "Downloading Debian's signed checksum manifest"
curl --fail --show-error --silent --location "$BASE_URL/SHA512SUMS" --output "$SUMS"
curl --fail --show-error --silent --location "$BASE_URL/SHA512SUMS.sign" --output "$SIGNATURE"
curl --fail --show-error --silent --location "$DEBIAN_CD_KEY_URL" --output "$KEY_FILE"

mkdir -m 0700 "$GPG_HOME"
gpg --batch --homedir "$GPG_HOME" --import "$KEY_FILE" >/dev/null 2>&1 || die "Could not import the Debian CD signing key"
key_fingerprints=()
while IFS= read -r fingerprint; do
    key_fingerprints+=("$fingerprint")
done < <(gpg --batch --homedir "$GPG_HOME" --with-colons --fingerprint --list-keys |
    awk -F: '$1=="pub" {want=1; next} want && $1=="fpr" {print $10; want=0}')
[[ ${#key_fingerprints[@]} -eq 1 && ${key_fingerprints[0]} == "$DEBIAN_CD_KEY_FINGERPRINT" ]] || \
    die "The downloaded Debian CD signing key has an unexpected fingerprint"
gpg --batch --homedir "$GPG_HOME" --verify "$SIGNATURE" "$SUMS" >/dev/null 2>&1 || \
    die "Debian's SHA512SUMS signature did not verify with the expected CD signing key"

ISO_NAME=$(awk -v arch="$ARCHITECTURE" '
    $2 ~ "^debian-13([.][0-9]+)+-" arch "-netinst[.]iso$" {print $2}
' "$SUMS" | tail -n 1)
[[ -n $ISO_NAME ]] || die "No Debian 13 $ARCHITECTURE netinst ISO was found in the signed manifest"
BASE_ISO=$CACHE_DIR/$ISO_NAME

if [[ -f $BASE_ISO ]]; then
    EXPECTED_SHA512=$(awk -v image="$ISO_NAME" '$2==image {print $1}' "$SUMS")
    ACTUAL_SHA512=$(sha512sum "$BASE_ISO" | awk '{print $1}')
    if [[ $ACTUAL_SHA512 != "$EXPECTED_SHA512" ]]; then
        log "Discarding an incomplete or invalid cached copy of $ISO_NAME"
        rm -f -- "$BASE_ISO"
    fi
fi
if [[ ! -f $BASE_ISO ]]; then
    log "Downloading $ISO_NAME"
    curl --fail --show-error --location "$BASE_URL/$ISO_NAME" --output "$BASE_ISO"
fi
EXPECTED_SHA512=$(awk -v image="$ISO_NAME" '$2==image {print $1}' "$SUMS")
ACTUAL_SHA512=$(sha512sum "$BASE_ISO" | awk '{print $1}')
[[ $ACTUAL_SHA512 == "$EXPECTED_SHA512" ]] || die "SHA-512 verification failed for $ISO_NAME"
log "Verified official Debian image $ISO_NAME"

ORIGINAL_GRUB=$WORK_DIR/debian-grub.cfg
ORIGINAL_MD5=$WORK_DIR/md5sum.txt
xorriso -osirrox on -indev "$BASE_ISO" \
    -extract /boot/grub/grub.cfg "$ORIGINAL_GRUB" \
    -extract /md5sum.txt "$ORIGINAL_MD5" >/dev/null 2>&1 || \
    die "Could not extract the Debian boot configuration"

CUSTOM_GRUB=$WORK_DIR/grub.cfg
cat >"$CUSTOM_GRUB" <<EOF
set default=0
set timeout=10

menuentry 'Install Entropy39 Node' {
    linux /$INSTALLER_PATH/vmlinuz preseed/file=/cdrom/preseed.cfg priority=high --- quiet
    initrd /$INSTALLER_PATH/initrd.gz
}

menuentry 'Advanced Debian installation options' {
    configfile /boot/grub/debian-grub.cfg
}
EOF

PAYLOAD=$WORK_DIR/firstboot
mkdir "$PAYLOAD"
for file in \
    firstboot \
    firstboot-cleanup \
    firstboot.service \
    getty-restore.service \
    firstboot.conf \
    install-firstboot.sh \
    99-no-root-login.conf; do
    cp "$ROOT_DIR/firstboot/$file" "$PAYLOAD/$file"
done

NEW_MD5=$WORK_DIR/md5sum.new
grep -vE '  [.]?/boot/grub/(grub|debian-grub)[.]cfg$|  [.]?/isolinux/(isolinux|debian-isolinux)[.]cfg$|  [.]?/preseed[.]cfg$|  [.]?/entropy39/' "$ORIGINAL_MD5" >"$NEW_MD5"
printf '%s  ./boot/grub/grub.cfg\n' "$(md5sum "$CUSTOM_GRUB" | awk '{print $1}')" >>"$NEW_MD5"
printf '%s  ./boot/grub/debian-grub.cfg\n' "$(md5sum "$ORIGINAL_GRUB" | awk '{print $1}')" >>"$NEW_MD5"
printf '%s  ./preseed.cfg\n' "$(md5sum "$ROOT_DIR/debian/preseed.cfg" | awk '{print $1}')" >>"$NEW_MD5"
printf '%s  ./entropy39/finish-install.templates\n' "$(md5sum "$ROOT_DIR/debian/finish-install.templates" | awk '{print $1}')" >>"$NEW_MD5"
while IFS= read -r file; do
    relative=${file#"$WORK_DIR/"}
    printf '%s  ./entropy39/%s\n' "$(md5sum "$file" | awk '{print $1}')" "$relative" >>"$NEW_MD5"
done < <(find "$PAYLOAD" -type f -print | sort)

XORRISO_MAP=(
    -map "$ROOT_DIR/debian/preseed.cfg" /preseed.cfg
    -map "$ROOT_DIR/debian/finish-install.templates" /entropy39/finish-install.templates
    -map "$PAYLOAD" /entropy39/firstboot
    -map "$CUSTOM_GRUB" /boot/grub/grub.cfg
    -map "$ORIGINAL_GRUB" /boot/grub/debian-grub.cfg
    -map "$NEW_MD5" /md5sum.txt
)

if [[ $ARCHITECTURE == amd64 ]]; then
    ORIGINAL_ISOLINUX=$WORK_DIR/debian-isolinux.cfg
    CUSTOM_ISOLINUX=$WORK_DIR/isolinux.cfg
    xorriso -osirrox on -indev "$BASE_ISO" \
        -extract /isolinux/isolinux.cfg "$ORIGINAL_ISOLINUX" >/dev/null 2>&1 || \
        die "Could not extract the Debian BIOS boot configuration"
    cat >"$CUSTOM_ISOLINUX" <<EOF
default entropy39
prompt 0
timeout 100

label entropy39
    menu label Install Entropy39 Node
    kernel /$INSTALLER_PATH/vmlinuz
    append initrd=/$INSTALLER_PATH/initrd.gz preseed/file=/cdrom/preseed.cfg priority=high --- quiet

label advanced
    menu label Advanced Debian installation options
    config /isolinux/debian-isolinux.cfg
    append /isolinux/
EOF
    printf '%s  ./isolinux/isolinux.cfg\n' "$(md5sum "$CUSTOM_ISOLINUX" | awk '{print $1}')" >>"$NEW_MD5"
    printf '%s  ./isolinux/debian-isolinux.cfg\n' "$(md5sum "$ORIGINAL_ISOLINUX" | awk '{print $1}')" >>"$NEW_MD5"
    XORRISO_MAP+=(
        -map "$CUSTOM_ISOLINUX" /isolinux/isolinux.cfg
        -map "$ORIGINAL_ISOLINUX" /isolinux/debian-isolinux.cfg
    )
fi

OUTPUT_ISO=$OUTPUT_DIR/entropy39-node-debian13-$ARCHITECTURE.iso
rm -f -- "$OUTPUT_ISO"
log "Building $OUTPUT_ISO"
xorriso -indev "$BASE_ISO" -outdev "$OUTPUT_ISO" \
    -boot_image any replay \
    "${XORRISO_MAP[@]}" >/dev/null

sha512sum "$OUTPUT_ISO" >"$OUTPUT_ISO.sha512"
{
    printf 'debian_image=%s\n' "$ISO_NAME"
    printf 'debian_sha512=%s\n' "$EXPECTED_SHA512"
    printf 'debian_cd_signing_fingerprint=%s\n' "$DEBIAN_CD_KEY_FINGERPRINT"
    printf 'architecture=%s\n' "$ARCHITECTURE"
    printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$OUTPUT_ISO.build-info"

log "Built Entropy39 $ARCHITECTURE installer"
printf '  ISO:      %s\n' "$OUTPUT_ISO"
printf '  SHA-512:  %s\n' "$(awk '{print $1}' "$OUTPUT_ISO.sha512")"
