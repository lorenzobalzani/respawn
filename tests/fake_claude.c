/* A stand-in for the claude process: runs its argument as a child, the way Claude Code runs a hook. */
#include <stdlib.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
  int status = argc > 1 ? system(argv[1]) : 0;
  return WEXITSTATUS(status);
}
