# Vendored PostgreSQL 18 parser source

- Upstream: [pganalyze/libpg_query](https://github.com/pganalyze/libpg_query)
- Release tag: [`18.1.0`](https://github.com/pganalyze/libpg_query/releases/tag/18.1.0)
- Commit: `c1546e7e97edc93fe8474d7a59881e91fbf48cfc`
- Source: `Git tag checkout: https://github.com/pganalyze/libpg_query.git`
- Protobuf runtime: `upb`

## Local compatibility patch

`src/pg_query_json_plpgsql.c` serializes `PLPGSQL_DTYPE_PROMISE` using
`dump_var`, because promise datums use the same `PLpgSQL_var` struct as ordinary
variables. The pinned serializer omitted these cases and emitted malformed JSON
for trigger functions. The version tool reapplies this fix when staging a release
that lacks it. The upstream release tag and commit remain unchanged.


`libpg_query/` contains the checked-in source used by the native build. Its
`LICENSE`, PostgreSQL `src/postgres/COPYRIGHT`, and vendored source license
notices are retained. Builds do not fetch source from the network.
