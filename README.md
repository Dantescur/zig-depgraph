# zig-depgraph

`zig-depgraph` reads Zig package manifests (`build.zig.zon`) and writes their dependency graph as Graphviz DOT.

## Build

Requires Zig 0.17.1 or newer.

```sh
zig build
```

The executable is written to `zig-out/bin/zig_depgraph`.

## Zig package

The `zig_depgraph` module is exposed for use from other Zig projects. The package version is `0.1.0`; package files are listed in `build.zig.zon`.

## Usage

Pass either a package directory or a `build.zig.zon` file:

```sh
zig-out/bin/zig_depgraph graph .
zig-out/bin/zig_depgraph graph path/to/build.zig.zon
zig-out/bin/zig_depgraph graph path/to/package --output dependencies.dot
```

DOT is written to standard output unless `-o` or `--output` specifies a file. You can render it with Graphviz, for example:

```sh
dot -Tsvg dependencies.dot -o dependencies.svg
```

## Resolution behavior

- Local `.path` dependencies are resolved relative to the directory containing the manifest that declares them. The referenced package's `build.zig.zon` is read, parsed, and validated recursively.
- A local package's manifest name is used as its graph label, even when the dependency alias differs. Packages with the same fingerprint share one graph node. This also terminates cycles, including a dependency that points back to the root package.
- Remote dependencies remain leaf nodes. Their dependency alias is the graph label; their archives are not fetched.
- If a local manifest cannot be read, parsed, or validated, graph generation stops and reports the dependency and path. Conflicting graph identities also produce an error.
- Lazy dependencies are shown as dashed edges.

The synthetic root node represents the package passed to the command. Graph edges point from a package to each of its dependencies.

## Development

Run unit and CLI integration tests with:

```sh
zig build test
```
