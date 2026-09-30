#ifndef POSTGRESQL_PARSER_PG17_BRIDGE_H
#define POSTGRESQL_PARSER_PG17_BRIDGE_H

#if defined(__GNUC__)
#define PGP17_EXPORT __attribute__((visibility("default")))
#else
#define PGP17_EXPORT
#endif

typedef struct Pg17ParseResponse {
  char *tree_json;
  char *error_message;
  int cursor_position;
} Pg17ParseResponse;

PGP17_EXPORT Pg17ParseResponse *pgp17_parse(const char *sql);
PGP17_EXPORT void pgp17_free_response(Pg17ParseResponse *response);

#endif
