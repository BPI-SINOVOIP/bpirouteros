#define _GNU_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/types.h>

/* Execute the patched handler and upstream completion/config-change callbacks.
 * Only process launch, JSON, timers and unrelated interface I/O are stubs. The
 * script never starts in these cases, so it cannot send proto_block_restart. */
#define container_of(p, type, member) ((type *)((char *)(p) - offsetof(type, member)))
#define fallthrough __attribute__((fallthrough))
#define D(...) do {} while (0)
enum { S_IDLE, S_SETUP, S_SETUP_ABORT, S_TEARDOWN };
enum interface_state { IFS_DOWN, IFS_SETUP, IFS_UP, IFS_TEARDOWN };
enum { IFEV_DOWN, L_NOTICE };
enum interface_proto_cmd { PROTO_CMD_SETUP, PROTO_CMD_TEARDOWN, PROTO_CMD_RENEW };
enum { IFPEV_LINK_LOST, IFPEV_DOWN };
enum interface_config_state { IFC_NORMAL, IFC_RELOAD, IFC_REMOVE };
enum { PROTO_FLAG_NO_TASK = 1, PROTO_FLAG_RENEW_AVAILABLE = 2, BLOBMSG_TYPE_STRING = 3 };
struct device { const char *ifname; };
struct interface {
	bool autostart;
	enum interface_state state;
	bool dynamic;
	struct interface_proto_state *proto;
	enum interface_config_state config_state;
	const char *name;
	struct { struct device *dev; } main_dev;
};
struct interface_proto_state {
	struct interface *iface;
	void (*proto_event)(struct interface_proto_state *, int);
};
struct netifd_process {
	struct { bool pending; pid_t pid; } uloop;
	bool script_group;
	const char *script_device;
};
struct blob_attr { const char *device; };
struct blobmsg_policy { const char *name; int type; };
struct proto_shell_handler {
	struct { unsigned int flags; const char *name; } proto;
	const char *script_name;
};
struct proto_shell_state {
	int sm, checkup_interval, last_error;
	bool renew_pending, proto_task_killed;
	struct netifd_process script_task, proto_task;
	struct interface_proto_state proto;
	struct proto_shell_handler *handler;
	struct blob_attr *config;
	int teardown_timeout, checkup_timeout;
};
static unsigned int autonomous_setup, launches;
static bool fail_launch, fail_json;
static void interface_do_reload(struct interface *iface) { (void)iface; }
static void interface_do_remove(struct interface *iface) { (void)iface; }
static void interface_set_up(struct interface *iface) { (void)iface; autonomous_setup++; }
static void uloop_timeout_cancel(int *timeout) { (void)timeout; }
static void uloop_timeout_set(int *timeout, int ms) { (void)timeout; (void)ms; }
static void proto_shell_clear_host_dep(struct proto_shell_state *state) { (void)state; }
static int fixture_kill(pid_t pid, int sig) { (void)pid; (void)sig; abort(); }
#define kill fixture_kill
static char *blobmsg_format_json(struct blob_attr *config, bool list)
{
	(void)config; (void)list;
	return fail_json ? NULL : strdup("{}");
}
static void blobmsg_parse_attr(const struct blobmsg_policy *policy, int n,
	struct blob_attr **device, struct blob_attr *config)
{
	assert(n == 1 && !strcmp(policy->name, "device"));
	*device = config;
}
static const char *blobmsg_get_string(struct blob_attr *device) { return device->device; }
static int netifd_start_process(const char **argv, char **env, struct netifd_process *proc)
{
	(void)env;
	assert(!strcmp(argv[2], launches ? "teardown" : "setup"));
	launches++;
	if (fail_launch)
		return -1; /* pipe/first fork failure: no uloop child to complete. */
	proc->uloop.pending = true;
	return 0; /* Owner starts but exits before it can exec the script. */
}

#include "restart-busy.inc"
#include "restart-handler.inc"
#include "restart-config-change.inc"
static void proto_event(struct interface_proto_state *proto, int event)
{
	assert(event == IFPEV_DOWN);
	/* This is the production DOWN callback's final call after runtime cleanup. */
	interface_handle_config_change(proto->iface);
}
#include "restart-task-finish.inc"
#include "restart-script-cb.inc"

/* The real interface paths change interface state, not the protocol's sm.
 * Keep hardware/address cleanup stubbed while exercising that distinction. */
#define netifd_log_message(...) do {} while (0)
static void mark_interface_down(struct interface *iface) { iface->state = IFS_DOWN; }
static void interface_event(struct interface *iface, int ev) { (void)iface; (void)ev; }
static void device_release(void *user) { (void)user; }
static void interface_flush_state(struct interface *iface) { (void)iface; }
static void __set_config_state(struct interface *iface, enum interface_config_state s) { iface->config_state = s; }
static int interface_proto_event(struct interface_proto_state *proto, enum interface_proto_cmd cmd, bool force)
{
	/* QMI/NCM have no IMMEDIATE flag, so the core returns this handler result. */
	return proto_shell_handler(proto, cmd, force);
}
#include "restart-ifup.inc"
#include "restart-ifdown.inc"

static bool prefork_failure_is_retryable(const char *name, bool json_error)
{
	struct interface iface = { .autostart = true, .name = "wwan", .state = IFS_DOWN };
	struct proto_shell_handler handler = { .proto = { .name = name }, .script_name = "unused" };
	struct blob_attr config = { .device = "/dev/missing" };
	struct proto_shell_state value = {
		.sm = S_IDLE, .checkup_interval = -1, .handler = &handler, .config = &config,
		.proto = { .iface = &iface, .proto_event = proto_event }
	}, *state = &value;
	struct { const char *name; } scope = { name }, *h = &scope;
#include "script-scope.inc"
	iface.proto = &state->proto;
	autonomous_setup = launches = 0;
	fail_launch = !json_error;
	fail_json = json_error;
	assert(__interface_set_up(&iface) == -1);
	assert(iface.state == IFS_DOWN && !state->script_task.uloop.pending);
	bool idle = state->sm == S_IDLE && !proto_shell_busy(&state->proto);
	printf("prefork %s: json_error=%d idle=%d busy=%d child=%d\n", name, json_error,
		idle, proto_shell_busy(&state->proto), state->script_task.uloop.pending);
	if (!idle)
		return false;
	bool blocked = !iface.autostart;
	unsigned int failed_launches = launches;
	__interface_set_down(&iface, false);
	assert(launches == failed_launches && !proto_shell_busy(&state->proto));
	interface_handle_config_change(&iface);
	bool no_restart = autonomous_setup == 0;
	fail_launch = fail_json = false;
	launches = 0; /* Reset only the fixture's per-attempt call counter. */
	iface.autostart = true; /* The next explicit ifup sets this again. */
	assert(__interface_set_up(&iface) == 0 && launches == 1);
	assert(state->sm == S_SETUP && state->script_task.uloop.pending && proto_shell_busy(&state->proto));
	blocked = blocked && !iface.autostart;
	/* A running owner still needs its callback; the failure cleanup must not
	 * clear its execution evidence or synthesize success before that point. */
	state->script_task.uloop.pending = false;
	proto_shell_script_cb(&state->script_task, 127 << 8);
	assert(launches == 2 && state->script_task.uloop.pending && state->sm == S_TEARDOWN);
	state->script_task.uloop.pending = false;
	proto_shell_script_cb(&state->script_task, 127 << 8);
	assert(state->sm == S_IDLE && !proto_shell_busy(&state->proto));
	printf("explicit %s retry accepted: blocked_restart=%d callbacks_drained=1\n", name, blocked && no_restart);
	return blocked && no_restart && autonomous_setup == 0;
}

static bool rejected_setup(const char *name, bool launch_error, bool json_error)
{
	struct interface iface = { .autostart = true, .name = "wwan", .config_state = IFC_NORMAL };
	struct proto_shell_handler handler = { .proto = { .name = name }, .script_name = "unused" };
	struct blob_attr config = { .device = "/dev/missing" };
	struct proto_shell_state value = {
		.sm = S_IDLE, .checkup_interval = -1, .handler = &handler, .config = &config,
		.proto = { .iface = &iface, .proto_event = proto_event }
	}, *state = &value;
	struct { const char *name; } scope = { name }, *h = &scope;
#include "script-scope.inc"
	fail_launch = launch_error;
	fail_json = json_error;
	autonomous_setup = launches = 0;
	/* Explicit ifup has set autostart=true, even when UCI says auto=0. */
	int ret = proto_shell_handler(&state->proto, PROTO_CMD_SETUP, false);
	bool blocked_before_child = !iface.autostart;
	if (launch_error || json_error) {
		assert(ret == -1 && !state->script_task.uloop.pending);
		interface_handle_config_change(&iface);
	} else {
		assert(ret == 0 && state->script_task.uloop.pending);
		state->script_task.uloop.pending = false; /* uloop reaps rejected owner */
		proto_shell_script_cb(&state->script_task, 127 << 8);
		assert(launches == 2 && state->sm == S_TEARDOWN && state->script_task.uloop.pending);
		state->script_task.uloop.pending = false;
		proto_shell_script_cb(&state->script_task, 127 << 8);
		assert(state->sm == S_IDLE);
	}
	bool managed = !strcmp(name, "qmi") || !strcmp(name, "ncm");
	bool ok = blocked_before_child == managed && autonomous_setup == (managed ? 0U : 1U);
	printf("rejected %s: launch_error=%d json_error=%d blocked_before_child=%d autonomous_setup=%u\n",
		name, launch_error, json_error, blocked_before_child, autonomous_setup);
	return ok;
}

int main(void)
{
	bool ok = true;
	const char *names[] = { "qmi", "ncm", "dhcp", "dhcpv6" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		ok = rejected_setup(names[i], false, false) && ok;
		ok = rejected_setup(names[i], true, false) && ok;
		ok = rejected_setup(names[i], false, true) && ok;
	}
	for (size_t i = 0; i < 2; i++) {
		ok = prefork_failure_is_retryable(names[i], false) && ok;
		ok = prefork_failure_is_retryable(names[i], true) && ok;
	}
	return ok ? 0 : 1;
}
