#include "bridge.h"

#include <stdlib.h>
#include <string.h>

#include "pg_query.h"

static char *copy_string(const char *source) {
  if (source == NULL) {
    return NULL;
  }

  size_t length = strlen(source) + 1;
  char *copy = malloc(length);
  if (copy != NULL) {
    memcpy(copy, source, length);
  }
  return copy;
}

static Pg18ParseResponse *make_response(const char *json, const PgQueryError *error) {
  Pg18ParseResponse *response = calloc(1, sizeof(*response));
  if (response == NULL) {
    return NULL;
  }

  if (error != NULL) {
    response->error_message = copy_string(error->message);
    response->cursor_position = error->cursorpos;
    if (response->error_message == NULL) {
      free(response);
      return NULL;
    }
  } else {
    response->tree_json = copy_string(json);
    if (response->tree_json == NULL) {
      free(response);
      return NULL;
    }
  }
  return response;
}

Pg18ParseResponse *pgp18_parse(const char *sql) {
  if (sql == NULL) {
    return NULL;
  }
  PgQueryParseResult upstream = pg_query_parse(sql);
  Pg18ParseResponse *response = make_response(upstream.parse_tree, upstream.error);
  pg_query_free_parse_result(upstream);
  return response;
}

Pg18ParseResponse *pgp18_parse_plpgsql(const char *sql) {
  if (sql == NULL) {
    return NULL;
  }
  PgQueryPlpgsqlParseResult upstream = pg_query_parse_plpgsql(sql);
  Pg18ParseResponse *response = make_response(upstream.plpgsql_funcs, upstream.error);
  pg_query_free_plpgsql_parse_result(upstream);
  return response;
}

void pgp18_free_response(Pg18ParseResponse *response) {
  if (response == NULL) {
    return;
  }
  free(response->tree_json);
  free(response->error_message);
  free(response);
}
