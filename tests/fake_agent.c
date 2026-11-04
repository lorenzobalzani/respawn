/* A stand-in for an agent process. It runs its last argument as a child, the way an agent runs its hooks;
 * the other arguments only make its command line look like the agent's (node /usr/lib/gemini-cli/gemini ...).
 * When its terminal closes it gets SIGHUP and does what a real agent does then: it runs its end hook, the
 * command in $FAKE_AGENT_ON_HUP if there is one, and exits. Its children keep the default dispositions, so
 * the HUP of a closing terminal reaches them as it would reach an agent's. */
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t hung_up;

static void on_hup(int sig) {
  (void)sig;
  hung_up = 1;
}

static pid_t start(const char *command) {
  pid_t pid = fork();
  if (pid == 0) {
    signal(SIGHUP, SIG_DFL);
    execl("/bin/sh", "sh", "-c", command, (char *)NULL);
    _exit(127);
  }
  return pid;
}

/* Its exit status, or -1 when a HUP came first. */
static int finish(pid_t pid) {
  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) return 1;
    if (hung_up) return -1;
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(int argc, char **argv) {
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = on_hup; /* no SA_RESTART: the HUP interrupts the wait */
  sigaction(SIGHUP, &action, NULL);
  int status = argc > 1 ? finish(start(argv[argc - 1])) : 0;
  if (!hung_up) return status;
  signal(SIGHUP, SIG_IGN); /* a second HUP must not cut the end hook short */
  const char *end_hook = getenv("FAKE_AGENT_ON_HUP");
  if (end_hook) finish(start(end_hook));
  return 129;
}
