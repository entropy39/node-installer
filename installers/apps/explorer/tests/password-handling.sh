#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly INSTALLER_DIR=$(dirname "$TEST_DIR")

# shellcheck source=../install-explorer.sh
source "$INSTALLER_DIR/install-explorer.sh"

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT

rpc_password='rpc & slash\\ quote" apostrophe'"'"' dollar$ backtick` =#;'
web_password=' web password & \\ " '"'"' $HOME `literal` trailing space '
environment_file=$temporary_dir/btc-rpc-explorer.env

template_file=$temporary_dir/btc-rpc-explorer.env.template
write_environment_template "$template_file"
write_environment_file "$template_file" \
    "$environment_file" "$rpc_password" "$web_password"

RPC_EXPECTED=$rpc_password WEB_EXPECTED=$web_password ENVIRONMENT_FILE=$environment_file python3 <<'PY'
import os
from pathlib import Path


def parse_double_quoted(value: str) -> str:
    assert len(value) >= 2 and value[0] == value[-1] == '"'
    result = []
    index = 1
    while index < len(value) - 1:
        character = value[index]
        if character == "\\" and index + 1 < len(value) - 1:
            following = value[index + 1]
            if following in '\\"$':
                result.append(following)
                index += 2
                continue
        result.append(character)
        index += 1
    return "".join(result)


values = {}
for line in Path(os.environ["ENVIRONMENT_FILE"]).read_text().splitlines():
    if not line or line.startswith(("#", ";")):
        continue
    name, value = line.split("=", 1)
    values[name] = parse_double_quoted(value) if value.startswith('"') else value

assert values["BTCEXP_BITCOIND_PASS"] == os.environ["RPC_EXPECTED"]
assert values["BTCEXP_BASIC_AUTH_PASSWORD"] == os.environ["WEB_EXPECTED"]
PY

if command -v systemd-run >/dev/null 2>&1 && systemctl --user is-system-running >/dev/null 2>&1; then
    printf '%s' "$rpc_password" >"$temporary_dir/rpc-expected"
    printf '%s' "$web_password" >"$temporary_dir/web-expected"
    systemd-run --user --quiet --wait --pipe \
        --property="EnvironmentFile=$environment_file" \
        /bin/sh -c 'test "$BTCEXP_BITCOIND_PASS" = "$(cat "$1")" && test "$BTCEXP_BASIC_AUTH_PASSWORD" = "$(cat "$2")"' \
        sh "$temporary_dir/rpc-expected" "$temporary_dir/web-expected"
fi

printf 'password handling tests passed\n'
