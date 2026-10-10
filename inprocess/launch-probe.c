#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

// Set the loader variable after sandbox-exec has applied the restrictive profile.
int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) { fprintf(stderr, "usage: launch-probe TARGET PROBE LOG [startup]\n"); return 2; }
    setenv("DYLD_INSERT_LIBRARIES", argv[2], 1);
    setenv("FF_PROBE_LOG", argv[3], 1);
    int startup = argc == 5 && strcmp(argv[4], "startup") == 0;
    setenv("FF_PROBE_EXIT", startup ? "0" : "1", 1);
    setenv("FF_PROBE_HOOK", startup ? "1" : "0", 1);
    setenv("FF_PROBE_FREEFORM_HOOK", startup ? "1" : "0", 1);
    execl(argv[1], argv[1], (char *)0);
    perror("exec target");
    return 127;
}
