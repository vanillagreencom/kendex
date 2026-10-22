# shellcheck shell=bash

# A native executable keeps both the kernel name and argv[0] under the
# fixture's control. Renamed coreutils executables dispatch by their new name
# on multicall installations, and shell scripts expose their interpreter.
fixture_named_process() { # EXECUTABLE
  cc -x c -o "$1" - <<'C'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char *name = strrchr(argv[0], '/');
    if (name != NULL) {
        size_t size = strlen(argv[0]);
        size_t length = strlen(++name);
        memmove(argv[0], name, length);
        memset(argv[0] + length, 0, size - length);
    }
    unsigned int remaining = argc > 1 ? (unsigned int)strtoul(argv[1], NULL, 10) : 600;
    while (remaining != 0) remaining = sleep(remaining);
    return 0;
}
C
}
