#!/bin/sh
set -eu

bin=$1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

expected='digraph "dependencies" {
    n0 [label="zig_depgraph"];
}'

fail() {
    echo "cli test failed: $*" >&2
    exit 1
}

expect_failure() {
    name=$1
    shift
    if "$@" >"$tmp/stdout" 2>"$tmp/stderr"; then
        fail "$name should have failed"
    fi
}

actual=$("$bin" graph .)
[ "$actual" = "$expected" ] || fail "graph . produced unexpected stdout"

actual=$("$bin" graph build.zig.zon)
[ "$actual" = "$expected" ] || fail "graph build.zig.zon produced unexpected stdout"

actual=$("$bin" graph src/fixtures/transitive)
printf '%s\n' "$actual" | grep -F 'label="package_a"' >/dev/null || fail "transitive local package was missing"
printf '%s\n' "$actual" | grep -F 'label="shared"' >/dev/null || fail "shared local package was missing"
printf '%s\n' "$actual" | grep -F 'label="remote_alias"' >/dev/null || fail "remote leaf was missing"
if printf '%s\n' "$actual" | grep -F 'label="shared_alias"' >/dev/null; then
    fail "local dependency alias was used instead of package name"
fi

"$bin" graph . -o "$tmp/output.dot"
actual=$(cat "$tmp/output.dot")
[ "$actual" = "$expected" ] || fail "graph . -o produced unexpected file contents"

expect_failure "missing manifest" "$bin" graph "$tmp/missing.zon"
grep -q "cannot access" "$tmp/stderr" || fail "missing manifest error was not useful"

printf '.{ .name = ' >"$tmp/invalid.zon"
expect_failure "invalid ZON" "$bin" graph "$tmp/invalid.zon"
grep -q "cannot parse" "$tmp/stderr" || fail "invalid ZON error was not useful"

expect_failure "invalid dependency source" "$bin" graph src/fixtures/invalid_sources.zon
grep -q "dependency 'url_only'" "$tmp/stderr" || fail "invalid source diagnostic was not useful"

expect_failure "missing manifest metadata" "$bin" graph src/fixtures/no_dependencies.zon
grep -q "missing the required 'version'" "$tmp/stderr" || fail "missing field diagnostic was not useful"

mkdir -p "$tmp/transitive/broken"
cat >"$tmp/transitive/build.zig.zon" <<'ZON'
.{
    .name = .transitive_cli,
    .version = "1.0.0",
    .fingerprint = 0x900,
    .paths = .{"."},
    .dependencies = .{ .broken = .{ .path = "broken" } },
}
ZON
expect_failure "unreadable local dependency" "$bin" graph "$tmp/transitive"
grep -q "dependency 'broken'.*cannot read manifest" "$tmp/stderr" || fail "local dependency error did not name the dependency and failure"
grep -q "$tmp/transitive/broken/build.zig.zon" "$tmp/stderr" || fail "local dependency error did not name the manifest path"

expect_failure "unknown option" "$bin" graph --unknown
grep -q "usage:" "$tmp/stderr" || fail "unknown option did not print usage"

expect_failure "missing output argument" "$bin" graph . -o
grep -q "usage:" "$tmp/stderr" || fail "missing output argument did not print usage"

expect_failure "duplicate output argument" "$bin" graph . -o "$tmp/a.dot" --output "$tmp/b.dot"
grep -q "usage:" "$tmp/stderr" || fail "duplicate output argument did not print usage"

"$bin" graph src/fixtures/escaped_name.zon -o "$tmp/escaped.dot"
grep -F 'line\nbreak' "$tmp/escaped.dot" >/dev/null || fail "newline was not escaped as \\n"
if command -v dot >/dev/null 2>&1; then
    dot -Tsvg "$tmp/escaped.dot" >/dev/null || fail "Graphviz rejected generated DOT"
fi
