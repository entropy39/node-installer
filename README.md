# Entropy39 Node Installer

This repository contains the installation tooling for an Entropy39 Bitcoin node
based on standard Debian 13. It is not a Debian fork or a separate operating
system.

The repository provides the component installers, interactive first-boot setup,
Debian preseed and reproducible ISO construction tooling.

## Repository layout

- `installers/` contains the authoritative Dashboard and Bitcoin Core installers,
  plus self-contained optional application installers under `installers/apps/`.
- `firstboot/` contains the minimal ISO bootstrap, tty1 setup service and master
  setup program.
- `debian/` contains the Debian Installer preseed configuration.
- `scripts/` contains the ISO builder.

The Bitcoin Core configuration templates are maintained beside their installer
under `installers/templates/bitcoin/`. Other application configuration templates
remain authoritative in the Dashboard repository.

## First-boot flow

The ISO contains a fixed snapshot of the runtime installer files present in the
local working tree when it was built, including uncommitted changes. Debian
Installer deploys that snapshot under `/usr/local/lib/node-installer`, owned by
root and protected by SHA-256 manifests. On first boot, a temporary local tty1
`agetty` verifies and runs the embedded snapshot as root; it does not download
the node installer from GitHub. The build commit, dirty state and snapshot digest
are recorded under `/var/lib/entropy39-node/`. SSH root login is not enabled or
changed.

The master setup installs and verifies the Dashboard, then installs Bitcoin Core without
starting it. A `whiptail` checklist offers compatible optional applications,
with none selected by default. Selected applications are configured before
Bitcoin Core starts, after which their services are started and verified.

The base installation, optional application configuration and optional
application activation are recorded separately under
`/var/lib/entropy39-node/`. If an optional installer fails, the recovery menu
allows retrying it or continuing without it once the Bitcoin configuration is
confirmed safe.

The self-contained Explorer installer can also be run directly as root with
`installers/apps/explorer/install-explorer.sh --install`. Bitcoin Core and
`/etc/bitcoin.conf` must already exist, but Core may be running or stopped. A
fresh install adds the Explorer RPC credential, validates the installed files
and Apache configuration, and enables `explorer.service` without starting it.
If Core is already running, restart it later so the new credential takes effect,
then start Explorer. The `--update` path does not require Bitcoin Core to be
running and does not modify its configuration. It preserves whether Explorer
was running or stopped; running instances retain runtime verification and
rollback, while stopped instances remain stopped after the update.

Run `installers/apps/explorer/install-explorer.sh --uninstall` to remove an
installer-managed Explorer deployment. Uninstall removes only verified Explorer
files and its RPC entry, retains the dedicated service account, preserves a
non-empty cache and unknown state, and records progress so an interrupted
cleanup can be resumed by running the same command again.

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
