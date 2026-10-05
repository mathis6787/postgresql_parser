# Third-party notices

The package's MIT license covers its original Dart code, bridge code and tools.
Vendored sources retain their own licenses and copyright notices:

| Source | Notices shipped with the package |
| --- | --- |
| libpg_query / PostgreSQL 16 | [libpg_query LICENSE](native/pg16/libpg_query/LICENSE), [PostgreSQL COPYRIGHT](native/pg16/libpg_query/src/postgres/COPYRIGHT) |
| libpg_query / PostgreSQL 17 | [libpg_query LICENSE](native/pg17/libpg_query/LICENSE), [PostgreSQL COPYRIGHT](native/pg17/libpg_query/src/postgres/COPYRIGHT) |
| libpg_query / PostgreSQL 18 | [libpg_query LICENSE](native/pg18/libpg_query/LICENSE), [PostgreSQL COPYRIGHT](native/pg18/libpg_query/src/postgres/COPYRIGHT) |
| upb | [LICENSE](native/pg18/libpg_query/vendor/upb/LICENSE) |
| utf8_range | [LICENSE](native/pg18/libpg_query/vendor/upb/third_party/utf8_range/LICENSE) |
| protobuf-c (16/17) and xxHash (16/17/18) | License notices retained in each vendored source file under `native/pg<major>/libpg_query/vendor/` |

Source pins and local patches are documented in the PostgreSQL
[16](native/pg16/UPSTREAM.md), [17](native/pg17/UPSTREAM.md) and
[18](native/pg18/UPSTREAM.md) source details. Retain these notices when
redistributing the native source or compiled libraries.

