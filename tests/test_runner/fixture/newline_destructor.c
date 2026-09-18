#include <stdio.h>
#include <signal.h>

__attribute__((destructor)) static void newline_at_exit(void) {
#if defined(REPRO_MEANINGFUL)
    fputs("issue261-meaningful-stderr\n", stderr);
#else
    fputc('\n', stderr);
#endif
    fflush(stderr);
#if defined(REPRO_SIGNAL)
    /* Tests have already completed; only process destruction fails. */
    signal(SIGSEGV, SIG_DFL);
    raise(SIGSEGV);
#endif
}
