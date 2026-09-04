#include "http_internal.h"

/*
 * Complete a response without facil.io's public http_finish wrapper adding a
 * Content-Length header. Accessing the named member through the vendored C
 * definition makes a zap upgrade fail at build time instead of silently
 * calling the wrong vtable slot from a hand-copied Zig prefix.
 */
void zigbase_http_finish_without_content_length(http_s *response) {
  if (!response || !response->private_data.vtbl)
    return;
  ((http_vtable_s *)response->private_data.vtbl)->http_finish(response);
}
