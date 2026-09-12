#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/* Minimal types for executing the actual added netifd callback/status code. */
enum { IFS_DOWN, IFS_SETUP, IFS_UP, IFS_TEARDOWN };
enum { S_IDLE, S_SETUP, S_SETUP_ABORT, S_TEARDOWN };
struct interface_proto_state;
struct interface { int state; struct interface_proto_state *proto; };
struct interface_proto_state {
	struct interface *iface;
	bool (*busy)(struct interface_proto_state *);
};
struct process { struct { bool pending; } uloop; };
struct proto_shell_state {
	struct interface_proto_state proto;
	int sm;
	struct process script_task, proto_task;
};
#define container_of(p, type, member) ((type *)((char *)(p) - offsetof(type, member)))
#include "proto-busy.inc"

static int b;
static bool emitted;
static void blobmsg_add_u8(int *buf, const char *key, bool value)
{
	assert(buf == &b && strcmp(key, "bpir_proto_busy") == 0);
	emitted = value;
}
static bool status(struct interface *iface)
{
#include "status-busy.inc"
	return emitted;
}

int main(void)
{
	struct interface iface = { .state = IFS_DOWN };
	struct proto_shell_state shell = { .proto = { .iface = &iface, .busy = proto_shell_busy } };
	iface.proto = &shell.proto;
	assert(!status(&iface));
	/* Teardown must remain busy even though ordinary up/pending are false. */
	iface.state = IFS_TEARDOWN;
	assert(status(&iface));
	iface.state = IFS_SETUP;
	assert(status(&iface));
	iface.state = IFS_DOWN;
	shell.sm = S_TEARDOWN;
	assert(status(&iface));
	shell.sm = S_SETUP_ABORT;
	assert(status(&iface));
	shell.sm = S_SETUP;
	assert(status(&iface));
	shell.sm = S_IDLE;
	shell.script_task.uloop.pending = true;
	assert(status(&iface));
	iface.state = IFS_UP;
	assert(status(&iface));
	shell.script_task.uloop.pending = false;
	shell.proto_task.uloop.pending = true;
	/* An established DHCP daemon must not make healthy ECM wait forever. */
	assert(!status(&iface));
	iface.state = IFS_DOWN;
	assert(status(&iface));
	shell.proto_task.uloop.pending = false;
	assert(!status(&iface));
	/* Immediate/static protocols have no asynchronous shell callback. */
	iface.proto = NULL;
	assert(!status(&iface));
	iface.state = IFS_TEARDOWN;
	assert(status(&iface));
	return 0;
}
