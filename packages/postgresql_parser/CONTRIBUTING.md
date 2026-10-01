# Contributing to postgresql_parser

This package is developed in a Dart pub workspace. Run repository commands from
the workspace root, and parser commands from `packages/postgresql_parser` as
shown below. `packages/serverpod_sql_check` is a separate placeholder package.

## Set up the workspace

Use Dart 3.13.4 or newer within the Dart 3 SDK range, a C compiler, and libclang.
libclang is required for binding generation, freshness checks, and the generator
tests. LLVM 18 or newer is recommended.

On macOS, install the Xcode command line tools:

```sh
xcode-select --install
```

On Debian/Ubuntu, install the native tools:

```sh
sudo apt-get update
sudo apt-get install clang libclang-dev git
```

From the workspace root:

```sh
dart pub get
dart analyze
cd packages/postgresql_parser
dart run tool/ffigen.dart --check
dart test
```

Run the parser tests from the package directory so Dart discovers its native
build hook. CI runs analysis, binding freshness checks, and tests on macOS and
Linux. Changes to native code must pass on both platforms.

## Make a change

Keep the public API, examples, and tests consistent. Add coverage for new parser
behavior and error handling; shared parsing tests should exercise every entry
in `PostgresParser.supportedVersions`. Keep version-specific syntax tests when
the grammars differ.

Format changed Dart files with `dart format`, then run the checks above. In a
pull request, explain the resulting behavior, any compatibility implications,
and the checks you ran. Include upstream source pins and local patches when
changing vendored code.

## Generate native bindings

Each PostgreSQL version has a small C bridge under `native/pg<major>`. The build
hook compiles each version as a separate native asset. The bridge owns copied
JSON and error strings; Dart converts them and frees the response after every
call, including failures.

Bindings under `lib/src/native` are generated from `bridge.h` by the Dart
configuration in `tool/ffigen.dart`. Edit the header or generator configuration,
then regenerate from the parser package directory:

```sh
dart run tool/ffigen.dart
dart run tool/ffigen.dart --check
```

Commit the generated Dart files. `--check` compares temporary output with the
committed bindings without rewriting them. When adding bridge functions, also
update the generator's included symbols, the macOS exports in `hook/build.dart`,
the Linux `exports.map`, and the relevant Dart backends.

Application builds use the committed bindings and vendored C sources; they do
not run `ffigen` or fetch upstream source.

## Maintain PostgreSQL versions

Run the version tool from the parser package directory. Inspect available
releases before choosing a source pin:

```sh
dart run tool/add_postgres_version.dart --available
dart run tool/add_postgres_version.dart --list-releases 18
dart run tool/add_postgres_version.dart --list-tags 18
```

These listing commands require network access and do not change the repository.
`--list-releases` lists published releases; `--list-tags` also includes tags
without a GitHub release.

### Add a major version

Choose an uninstalled major and a tagged `libpg_query` release. For example,
substitute the intended major and tag in:

```sh
dart run tool/add_postgres_version.dart <major> --tag <release-tag>
```

Use `--latest` instead of `--tag` to select the newest stable release. The tool
refuses a major that is already installed. It vendors the source and licenses,
records the exact upstream commit, and creates the version-prefixed bridge,
generated bindings, backend, public version constant, and registry entry.
Adding a version requires libclang; binding-generation failures restore the
registry and remove the partial installation.

Review the generated diff, add a syntax test for the new grammar, and run
analysis, freshness checks, and tests on macOS and Linux before release.

### Update an installed version

To update an existing major to a newer release:

```sh
dart run tool/add_postgres_version.dart 18 --update --latest
```

Use `--tag <release-tag>` instead of `--latest` to choose a specific release.
The update preserves the bridge, bindings, backend, and public API. It replaces
vendored source and source metadata, then runs analysis and tests. Failed
validation restores the previous source and metadata. Uncommitted changes to
the affected source or metadata must be committed or set aside first. Updating
to the current pin is a no-op.

### Source provenance and compatibility

Source details live in [PostgreSQL 17's UPSTREAM.md](native/pg17/UPSTREAM.md) and
[PostgreSQL 18's UPSTREAM.md](native/pg18/UPSTREAM.md). Keep the upstream licenses
and PostgreSQL copyright notices when vendoring or updating sources.

The PostgreSQL 18 pin includes a serializer fix for promise datums used by
trigger variables. The version tool applies this fix to staged releases only
where the serializer lacks it, and records it in `UPSTREAM.md`. Document any
additional local patches alongside the source pin.

For repeatable updates, use `--expected-commit <full-git-sha>` to check the tag's
commit. An existing source archive can be supplied with `--archive <local-tar.gz>`
and checked with `--expected-sha256 <digest>`; the tool still checks out the tag
to establish its commit. Older `protobuf-c` releases with missing generated
files require `protoc` and `protoc-gen-c` on `PATH`. `upb` releases use their
checked-in generated files.

Run `dart run tool/add_postgres_version.dart --help` for all options. Upstream
API checks do not replace reviewing bridge and build compatibility.

## Prepare a release

Publish from `packages/postgresql_parser`, not the workspace root. Before the
first release:

- Choose the package license and add a package-root `LICENSE`; retain all
  third-party license notices.
- Add a package-root `CHANGELOG.md` and confirm the intended version.
- Set the package's repository and issue-tracker metadata in `pubspec.yaml`.
- Remove `publish_to: none` from the parser package when preparing to publish.
  Keep it on the workspace root and the unpublished placeholder package.
- Verify the README examples and all checks on macOS and Linux.

Then inspect the publication with:

```sh
dart pub publish --dry-run
```

Resolve the reported errors and review the file list. It must include the
package README, generated bindings, build hook, bridges, vendored C sources,
source metadata, and licenses. If using `.pubignore`, ensure those build inputs
remain included. Release notes and the package version should be updated for
each subsequent release as well.

See the [Dart publishing guide](https://dart.dev/tools/pub/publishing) for the
publication workflow.
