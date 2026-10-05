# Vendored PostgreSQL 16 parser source

- Upstream: [pganalyze/libpg_query](https://github.com/pganalyze/libpg_query)
- Release tag: [`16-5.2.0`](https://github.com/pganalyze/libpg_query/releases/tag/16-5.2.0)
- Commit: `fce106abf41205e5d0db47bea7de44ad1e36f7a5`
- Source: [verified tag archive](https://codeload.github.com/pganalyze/libpg_query/tar.gz/refs/tags/16-5.2.0)
- Protobuf runtime: `protobuf-c`
- Source archive SHA-256: `92bbc9a628655df3de86db51de97446d8ed18b5d23b17039809364d5bc6a4a38`


## Local compatibility patch

`src/pg_query_json_plpgsql.c` serializes `PLPGSQL_DTYPE_PROMISE` with `dump_var`, matching its `PLpgSQL_var` representation. This fixes malformed JSON for trigger variables. The upstream pin is unchanged.


`libpg_query/` contains the checked-in source used by the native build. Its
`LICENSE`, PostgreSQL `src/postgres/COPYRIGHT`, and vendored source license
notices are retained. Builds do not fetch source from the network.

The archive omits PostgreSQL `COPYRIGHT`; the retained notice comes from
[PostgreSQL REL_16_1](https://github.com/postgres/postgres/blob/REL_16_1/COPYRIGHT).
On macOS, the local `strchrnul` fallback is renamed after system includes to
avoid a collision with the macOS 15.4 SDK while preserving older deployment targets.
