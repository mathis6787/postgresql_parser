#ifndef POSTGRESQL_PARSER_PG16_BRIDGE_H
#define POSTGRESQL_PARSER_PG16_BRIDGE_H

#if defined(__GNUC__)
#define PGP16_EXPORT __attribute__((visibility("default")))
#else
#define PGP16_EXPORT
#endif

typedef struct Pg16ParseResponse {
  char *tree_json;
  char *error_message;
  int cursor_position;
} Pg16ParseResponse;

PGP16_EXPORT Pg16ParseResponse *pgp16_parse(const char *sql);
PGP16_EXPORT Pg16ParseResponse *pgp16_parse_plpgsql(const char *sql);
PGP16_EXPORT void pgp16_free_response(Pg16ParseResponse *response);

#endif
