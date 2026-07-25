/* A do-nothing daemon: loops until signalled. Real apps put a server
   here. Demonstrates that OIS installs it, registers it as a service,
   and manages its lifecycle across updates. */
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    (void)argc; (void)argv;
    printf("exampled starting\n"); fflush(stdout);
    for (;;) sleep(60);
    return 0;
}
