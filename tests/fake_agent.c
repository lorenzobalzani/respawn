/* A stand-in for an agent process. It runs its last argument as a child, the way an agent runs its hooks,
 * and outlives a closing terminal long enough to run its end hook, as real agents do. The other arguments
 * only make its command line look like the agent's (node /usr/lib/gemini-cli/gemini ...). */
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
  signal(SIGHUP, SIG_IGN);
  int status = argc > 1 ? system(argv[argc - 1]) : 0;
  return WEXITSTATUS(status);
}
