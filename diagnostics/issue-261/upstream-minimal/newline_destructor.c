#include <stdio.h>

__attribute__((destructor)) static void newline_at_exit(void) {
    fputc('\n', stderr);
}
