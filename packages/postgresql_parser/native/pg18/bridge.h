#ifndef POSTGRESQL_PARSER_PG18_BRIDGE_H
#define POSTGRESQL_PARSER_PG18_BRIDGE_H

#if defined(__GNUC__)
#define PGP18_EXPORT __attribute__((visibility("default")))
#else
#define PGP18_EXPORT
#endif

typedef struct Pg18ParseResponse {
  char *tree_json;
  char *error_message;
  int cursor_position;
} Pg18ParseResponse;

PGP18_EXPORT Pg18ParseResponse *pgp18_parse(const char *sql);
PGP18_EXPORT Pg18ParseResponse *pgp18_parse_plpgsql(const char *sql);
PGP18_EXPORT void pgp18_free_response(Pg18ParseResponse *response);

#endif
