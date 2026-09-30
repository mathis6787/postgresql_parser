# Vendored PostgreSQL 17 parser source

- Upstream: [pganalyze/libpg_query](https://github.com/pganalyze/libpg_query)
- Release tag: [`17-6.2.2`](https://github.com/pganalyze/libpg_query/releases/tag/17-6.2.2)
- Commit: `7be1aed`
- Source archive: GitHub tag tarball from
  `https://api.github.com/repos/pganalyze/libpg_query/tarball/17-6.2.2`
- Downloaded tarball SHA-256:
  `332897dc7e07497e498ac0fadffc752580817361d8a8d699c7eb99d108db6d98`

`libpg_query/` contains the upstream headers and C sources needed by the
native build. Upstream examples, tests, generated C++ bindings, and source
generation scripts were not copied. The upstream `LICENSE` and PostgreSQL
`src/postgres/COPYRIGHT` are retained. The vendored protobuf-c and xxHash
source files retain their own license notices.

To update this major version, use a tagged upstream release, record its
commit and archive checksum here, replace the vendored sources, and rerun
the parser tests on macOS and Linux. Never use a moving branch in the build
hook.
