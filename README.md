# Entropy39 Node Installer

This repository contains the installation tooling for an Entropy39 Bitcoin node
based on standard Debian 13. It is not a Debian fork or a separate operating
system.

The repository provides the component installers, interactive first-boot setup,
Debian preseed and reproducible ISO construction tooling.

## Repository layout

- `installers/` contains the authoritative Dashboard and Bitcoin Core installers.
- `firstboot/` contains the minimal ISO bootstrap, tty1 setup service and master
  setup program.
- `debian/` contains the Debian Installer preseed configuration.
- `scripts/` contains the ISO builder.

The Dashboard configuration templates remain authoritative in the Dashboard
repository and are installed with the Dashboard application. The Bitcoin Core
installer reads those installed templates from
`/srv/www/dashboard/docs/examples/bitcoin/`.

## First-boot flow

The Debian installer copies only `firstboot`, its cleanup helper and
the systemd unit into the installed system. On the first boot, a temporary local
tty1 `agetty` starts the bootstrap as root. SSH root login is not enabled or
changed.

The bootstrap retrieves the `main` branch of this repository as a single Git
commit, checks out that exact commit, verifies the Git object database and
working tree, and records the commit under `/var/lib/entropy39-node/`. The master
setup then installs and verifies the Dashboard before running and verifying the
interactive Bitcoin Core installer.

Successful setup creates `/var/lib/entropy39-node/setup-complete`, disables the
temporary first-boot service and restores the normal Debian tty1 getty. Failure
does not create the completion marker and presents retry, maintenance shell,
reboot and shutdown choices. Output is retained in
`/var/log/entropy39-node/setup.log`.

## Building an installation image

The builder requires Bash, cURL, GnuPG, `sha512sum`, `md5sum` and xorriso. Build
the ARM64 image with:

```sh
./scripts/build-iso.sh --architecture arm64
```

Use `--architecture amd64` for the AMD64 image. The builder downloads the
current official Debian 13 netinst image, authenticates Debian's signed SHA-512
manifest against the explicitly maintained Debian CD signing fingerprint,
verifies the image checksum, and replays the official ISO boot configuration
when adding the Entropy39 files. The selected Debian image, checksum and signing
fingerprint are recorded beside the output ISO in `build/`.

The Entropy39 boot entry loads `debian/preseed.cfg`. Locale, keyboard, account
passwords and disk partitioning remain interactive. Debian's original installer
menu remains available through the advanced boot entry.
