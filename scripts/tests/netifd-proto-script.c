#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <sys/file.h>

static bool stop_script_fork, fail_script_fork;
static unsigned int script_forks, fail_fork_number;

static pid_t script_fork(void)
{
	script_forks++;
	if (fail_script_fork || (fail_fork_number && script_forks == fail_fork_number)) {
		fail_script_fork = false;
		errno = EAGAIN;
		return -1;
	}
	bool stop = stop_script_fork;
	stop_script_fork = false;
	pid_t pid = fork();
	if (!pid && stop) {
#ifdef BPIR_TEST_LATE_SIGNAL_BLOCK
		/* Reproduce the old window before signal-handler initialization. */
		sigset_t signals;
		sigemptyset(&signals);
		sigaddset(&signals, SIGUSR1);
		assert(sigprocmask(SIG_UNBLOCK, &signals, NULL) == 0);
#endif
		raise(SIGSTOP);
#ifdef BPIR_TEST_LATE_SIGNAL_BLOCK
		assert(sigprocmask(SIG_BLOCK, &signals, NULL) == 0);
#endif
	}
	return pid;
}

#ifdef BPIR_TEST_NO_SLOT_LOCK
static int skipped_flock(int fd, int operation) { (void)fd; (void)operation; return 0; }
#define flock skipped_flock
#endif
#define fork script_fork
#include "proto-script.h"
#undef fork
#ifdef BPIR_TEST_NO_SLOT_LOCK
#undef flock
#endif

#define main test_status
#include "netifd-proto-busy.c"
#undef main

struct tracked_process { pid_t pid; bool pending; };
struct netifd_process { struct tracked_process uloop; bool script_group; const char *script_device; };
static void uloop_process_delete(struct tracked_process *p) { p->pending = false; }
static void netifd_delete_process(struct netifd_process *p) { (void)p; }
#include "signal-process.inc"
#include "kill-process.inc"

static pid_t start_script(bool script_group)
{
	struct netifd_process record = { .script_group = script_group, .script_device = TEST_DEVICE }, *proc = &record;
	int pid;
#include "fork-script.inc"
		return -1;
	return pid;
}

static void assert_same_mask(const sigset_t *before)
{
	sigset_t after;
	assert(sigprocmask(SIG_SETMASK, NULL, &after) == 0);
	for (int sig = 1; sig < NSIG; sig++)
		assert(sigismember(before, sig) == sigismember(&after, sig));
}

static void assert_script_mask(void)
{
	sigset_t mask;
	assert(sigprocmask(SIG_SETMASK, NULL, &mask) == 0);
	assert(sigismember(&mask, SIGUSR2) == 1);
	assert(sigismember(&mask, SIGCHLD) == 0);
	assert(sigismember(&mask, SIGTERM) == 0);
	assert(sigismember(&mask, SIGUSR1) == 0);
}

static void inherited_signal_handler(int sig) { (void)sig; }

static bool startup_termination(void)
{
	struct sigaction action = { .sa_handler = inherited_signal_handler }, previous;
	assert(sigaction(SIGUSR1, &action, &previous) == 0);
	sigset_t mask;
	assert(sigprocmask(SIG_SETMASK, NULL, &mask) == 0);
	fail_script_fork = true;
	assert(start_script(true) == -1 && errno == EAGAIN);
	assert_same_mask(&mask);
	stop_script_fork = true;
	pid_t owner = start_script(true);
	assert(owner >= 0);
	if (!owner) {
		assert_script_mask();
		for (;;) pause();
	}
	assert_same_mask(&mask);
	int status;
	assert(waitpid(owner, &status, WUNTRACED) == owner && WIFSTOPPED(status));
	struct netifd_process proc = { .uloop = { .pid = owner, .pending = true },
		.script_group = true };
	netifd_signal_process(&proc, SIGKILL);
	assert(kill(owner, SIGCONT) == 0);
	pid_t done = 0;
	for (int i = 0; i < 100 && !done; i++) {
		struct timespec tick = { .tv_nsec = 10000000 };
		nanosleep(&tick, NULL);
		done = waitpid(owner, &status, WNOHANG);
		assert(done >= 0);
	}
	bool ok = done == owner && WIFEXITED(status) && WEXITSTATUS(status) == 128 + SIGKILL;
	printf("startup: first_request_reaped_owner=%d\n", ok);
	if (!done) {
		/* The negative control needs a second request after initialization. */
		netifd_signal_process(&proc, SIGKILL);
		assert(waitpid(owner, &status, 0) == owner);
	}
	assert(sigaction(SIGUSR1, &previous, NULL) == 0);
	return ok;
}

static bool owns_script(const char *name)
{
	struct { const char *name; } handler = { name }, *h = &handler;
	struct { struct netifd_process script_task; } value = {0}, *state = &value;
#include "script-scope.inc"
	return state->script_task.script_group;
}

static int payload(const char *mode, int ready, int release)
{
	assert_script_mask();
	if (!strcmp(mode, "force") || !strcmp(mode, "destroy"))
		signal(SIGTERM, SIG_IGN);
	pid_t command = fork();
	assert(command >= 0);
	if (!command) {
		signal(SIGTERM, SIG_IGN);
		pid_t self = getpid();
		assert(write(ready, &self, sizeof(self)) == sizeof(self));
		if (!strcmp(mode, "normal")) {
			char byte;
			assert(read(release, &byte, 1) == 1);
			return 0;
		}
		for (;;) pause();
	}
	if (!strcmp(mode, "orphan")) {
		char byte;
		assert(read(release, &byte, 1) == 1);
		return 7;
	}
	assert(waitpid(command, NULL, 0) == command);
	return 7;
}

static bool slot_is_locked(void)
{
	/* Independent expected name, not the resolver's own returned path. */
	int fd = open(MODEM_LOCK_ROOT "/usb_2_1_1.lock", O_RDWR);
	assert(fd >= 0);
	bool held = flock(fd, LOCK_EX | LOCK_NB) < 0 && errno == EWOULDBLOCK;
	close(fd);
	return held;
}

static void admission_failures(void)
{
	int status;
	// The second fork fails after the owner opened the lock, before any script.
	script_forks = 0;
	fail_fork_number = 2;
	pid_t owner = start_script(true);
	assert(owner > 0);
	assert(waitpid(owner, &status, 0) == owner && WIFEXITED(status) && WEXITSTATUS(status) == 127);
	assert(!slot_is_locked());
	fail_fork_number = 0;
	// A failed lock open must not fall through to exec. Preserve the existing
	// fixture inode so subsequent cases continue using the same physical slot.
	assert(rename(MODEM_LOCK_ROOT "/usb_2_1_1.lock", MODEM_LOCK_ROOT "/saved.lock") == 0);
	assert(mkdir(MODEM_LOCK_ROOT "/usb_2_1_1.lock", 0700) == 0);
	owner = start_script(true);
	assert(owner > 0);
	assert(waitpid(owner, &status, 0) == owner && WIFEXITED(status) && WEXITSTATUS(status) == 127);
	assert(rmdir(MODEM_LOCK_ROOT "/usb_2_1_1.lock") == 0);
	assert(rename(MODEM_LOCK_ROOT "/saved.lock", MODEM_LOCK_ROOT "/usb_2_1_1.lock") == 0);
	puts("fork/lock failure: zero script execution, no stale lock");
}

static bool lock_wait_case(bool cancel, bool replace)
{
	int held[2], release[2], entered[2], status;
	assert(pipe(held) == 0 && pipe(release) == 0 && pipe(entered) == 0);
	/* Model apid as a different process. netifd must not inherit the other
	 * owner's fd from the test parent, which would mask early release. */
	pid_t holder = fork();
	assert(holder >= 0);
	if (!holder) {
		int fd = open(MODEM_LOCK_ROOT "/usb_2_1_1.lock", O_RDWR);
		assert(fd >= 0 && flock(fd, LOCK_EX) == 0);
		assert(write(held[1], "x", 1) == 1);
		char b;
		assert(read(release[0], &b, 1) == 1);
		close(fd);
		_exit(0);
	}
	close(held[1]);
	close(release[0]);
	char b;
	assert(read(held[0], &b, 1) == 1);
	pid_t owner = start_script(true);
	assert(owner >= 0); /* The event-loop side returns while the slot is busy. */
	if (!owner) {
		assert(write(entered[1], "x", 1) == 1);
		_exit(0);
	}
	close(entered[1]);
	struct pollfd watch = { .fd = entered[0], .events = POLLIN };
	bool blocked = poll(&watch, 1, 100) == 0;
	// A second physical slot, unlike a second tty of this slot, is free.
	struct modem_slot other;
	assert(modem_slot_open(TEST_OTHER_DEVICE, &other) == 0);
	assert(!strcmp(other.name, "usb_2_1_2") && flock(other.fd, LOCK_EX | LOCK_NB) == 0);
	close(other.fd);
	if (cancel) {
		struct netifd_process proc = { .uloop = { .pid = owner, .pending = true }, .script_group = true };
		netifd_signal_process(&proc, SIGKILL);
		assert(waitpid(owner, &status, 0) == owner);
		assert(slot_is_locked()); /* Cancellation cannot unlock apid's fd. */
	}
	if (replace) {
		FILE *f = fopen(MODEM_SYSFS "/devices/2-1.1/devnum", "w");
		assert(f && fputs("8\n", f) >= 0 && fclose(f) == 0);
	}
	assert(write(release[1], "x", 1) == 1);
	assert(waitpid(holder, NULL, 0) == holder);
	if (!cancel)
		assert(waitpid(owner, &status, 0) == owner);
	bool correct = WIFEXITED(status) && WEXITSTATUS(status) == (cancel ? 128 + SIGKILL : replace ? 127 : 0);
	ssize_t entered_count = read(entered[0], &b, 1);
	correct = correct && entered_count == (cancel || replace ? 0 : 1) && !slot_is_locked();
	if (replace) {
		FILE *f = fopen(MODEM_SYSFS "/devices/2-1.1/devnum", "w");
		assert(f && fputs("7\n", f) >= 0 && fclose(f) == 0);
	}
	close(held[0]); close(release[1]); close(entered[0]);
	printf("slot wait: cancel=%d replace=%d blocked=%d correct=%d\n", cancel, replace, blocked, correct);
	return blocked && correct;
}

static bool run_case(const char *self, const char *mode)
{
	int ready[2], release[2], status = 0;
	assert(pipe(ready) == 0 && pipe(release) == 0);
	sigset_t mask;
	assert(sigprocmask(SIG_SETMASK, NULL, &mask) == 0);
#ifndef BPIR_TEST_UNSUPERVISED
	pid_t owner = start_script(true);
#else
	pid_t owner = fork();
#endif
	assert(owner >= 0);
	if (!owner) {
		char r[16], w[16];
		snprintf(r, sizeof(r), "%d", ready[1]);
		snprintf(w, sizeof(w), "%d", release[0]);
		execl(self, self, "--payload", mode, r, w, (char *)NULL);
		_exit(127);
	}
	assert_same_mask(&mask);
	close(ready[1]);
	close(release[0]);
	pid_t command;
	assert(read(ready[0], &command, sizeof(command)) == sizeof(command));
	assert(waitpid(owner, &status, WNOHANG) == 0);
#ifndef BPIR_TEST_UNSUPERVISED
	bool held = slot_is_locked();
	if (!held)
		puts("slot lock missing while a protocol command is alive");
#endif
	struct netifd_process proc = { .uloop = { .pid = owner, .pending = true },
#ifndef BPIR_TEST_UNSUPERVISED
		.script_group = true,
#endif
	};
	if (!strcmp(mode, "force")) {
		netifd_signal_process(&proc, SIGTERM);
		/* Both script and command ignore TERM. A queued forced request must
		 * still be consumed without losing the original owner's children. */
		netifd_signal_process(&proc, SIGKILL);
		assert(proc.uloop.pending); /* The completion callback still owns it. */
	} else if (!strcmp(mode, "destroy")) {
		netifd_kill_process(&proc);
		assert(!proc.uloop.pending);
#ifndef BPIR_TEST_UNSUPERVISED
		assert(kill(command, 0) < 0 && errno == ESRCH);
		assert(waitpid(owner, &status, WNOHANG) < 0 && errno == ECHILD);
		close(ready[0]);
		close(release[1]);
		puts("destroy: record released only after command and owner were reaped");
		return held && !slot_is_locked();
#endif
	} else if (!strcmp(mode, "term")) {
		netifd_signal_process(&proc, SIGTERM);
	} else {
		assert(write(release[1], "x", 1) == 1);
	}
	pid_t done = 0;
	for (int i = 0; i < 300 && !done; i++) {
		done = waitpid(owner, &status, WNOHANG);
		assert(done >= 0);
		if (!done) {
			struct timespec tick = { .tv_nsec = 10000000 };
			nanosleep(&tick, NULL);
		}
	}
	bool gone = kill(command, 0) < 0 && errno == ESRCH;
	bool correct_status = WIFEXITED(status) && WEXITSTATUS(status) ==
		(!strcmp(mode, "force") ? 128 + SIGKILL :
		 !strcmp(mode, "term") ? 128 + SIGTERM : 7);
	if (!gone) {
		kill(command, SIGKILL);
		while (waitpid(command, NULL, 0) < 0 && errno == EINTR);
	}
	if (!done) {
		kill(owner, SIGUSR1);
		while (waitpid(owner, NULL, 0) < 0 && errno == EINTR);
	}
	close(ready[0]);
	close(release[1]);
	printf("%s: owner_reaped=%d command_gone=%d exit_status=%d\n",
		mode, done == owner, gone, correct_status);
#ifndef BPIR_TEST_UNSUPERVISED
	correct_status = correct_status && held && !slot_is_locked();
#endif
	return done == owner && gone && correct_status;
}

int main(int argc, char **argv)
{
	if (argc == 5 && !strcmp(argv[1], "--payload"))
		return payload(argv[2], atoi(argv[3]), atoi(argv[4]));
	sigset_t mask, previous;
	sigemptyset(&mask);
	sigaddset(&mask, SIGUSR2);
	assert(sigprocmask(SIG_SETMASK, &mask, &previous) == 0);
	test_status();
	struct modem_slot qmi;
	assert(modem_slot_open(TEST_QMI_DEVICE, &qmi) == 0);
	assert(!strcmp(qmi.name, "usb_2_1_1") && qmi.generation == 7);
	close(qmi.fd);
	assert(modem_slot_identity("/definitely/missing/modem", &qmi) < 0);
	assert(owns_script("qmi") && owns_script("ncm"));
	assert(!owns_script("dhcp") && !owns_script("dhcpv6") && !owns_script("static"));
	/* This test owner also reaps the deliberately orphaned negative case. */
	assert(prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0);
	pid_t unrelated = fork();
	assert(unrelated >= 0);
	if (!unrelated)
		for (;;) pause();
	bool ok = run_case(argv[0], "normal");
#ifndef BPIR_TEST_UNSUPERVISED
	admission_failures();
	ok = startup_termination() && ok;
#ifndef BPIR_TEST_NO_SLOT_LOCK
	ok = lock_wait_case(false, false) && ok;
	ok = lock_wait_case(true, false) && ok;
	ok = lock_wait_case(false, true) && ok;
#endif
#endif
	ok = run_case(argv[0], "orphan") && ok;
	ok = run_case(argv[0], "term") && ok;
	ok = run_case(argv[0], "force") && ok;
	ok = run_case(argv[0], "destroy") && ok;
	ok = kill(unrelated, 0) == 0 && ok;
	assert(kill(unrelated, SIGKILL) == 0);
	assert(waitpid(unrelated, NULL, 0) == unrelated);
	assert(sigprocmask(SIG_SETMASK, &previous, NULL) == 0);
	return ok ? 0 : 1;
}
