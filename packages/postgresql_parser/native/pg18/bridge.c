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

Pg18ParseResponse *pgp18_parse(const char *sql) {
  if (sql == NULL) {
    return NULL;
  }

  Pg18ParseResponse *response = calloc(1, sizeof(*response));
  if (response == NULL) {
    return NULL;
  }

  PgQueryParseResult upstream = pg_query_parse(sql);
  if (upstream.error != NULL) {
    response->error_message = copy_string(upstream.error->message);
    response->cursor_position = upstream.error->cursorpos;
    if (response->error_message == NULL) {
      pg_query_free_parse_result(upstream);
      free(response);
      return NULL;
    }
  } else {
    response->tree_json = copy_string(upstream.parse_tree);
    if (response->tree_json == NULL) {
      pg_query_free_parse_result(upstream);
      free(response);
      return NULL;
    }
  }

  pg_query_free_parse_result(upstream);
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
