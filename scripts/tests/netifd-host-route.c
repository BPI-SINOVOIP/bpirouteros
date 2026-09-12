/* Exercise production route/dependency functions with real libubox lists.
 * Kernel route installation and unrelated protocol operations are stubbed. */
#include <assert.h>
#include <arpa/inet.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libubox/list.h>
#include <libubox/vlist.h>
#include <libubox/blobmsg.h>
#include <libubox/avl-cmp.h>
#include "route-types.inc"

enum interface_state { IFS_UP, IFS_DOWN, IFS_SETUP, IFS_TEARDOWN };
enum interface_event { IFEV_UP, IFEV_DOWN, IFEV_UPDATE, IFEV_UP_FAILED, IFEV_FREE };
enum interface_proto_cmd { PROTO_CMD_SETUP, PROTO_CMD_TEARDOWN, PROTO_CMD_RENEW };
enum { IFPEV_DOWN, IFPEV_LINK_LOST, IFC_REMOVE, IUF_ROUTE = 2 };
enum { S_IDLE, S_SETUP, S_SETUP_ABORT, S_TEARDOWN };
enum { PROTO_FLAG_NO_TASK = 1, PROTO_FLAG_RENEW_AVAILABLE = 2 };
#define D(...) do {} while (0)
struct interface;
struct interface_user {
	struct list_head list;
	struct interface *iface;
	void (*cb)(struct interface_user *, struct interface *, enum interface_event);
};
struct device { const char *ifname; };
struct device_user { struct device *dev; };
struct interface_ip_settings {
	struct interface *iface;
	struct vlist_tree route;
	bool enabled, no_defaultroute;
};
struct interface {
	struct vlist_node node;
	struct list_head users;
	struct vlist_tree host_routes;
	struct interface_ip_settings proto_ip, config_ip;
	struct device_user main_dev, l3_dev;
	struct interface_proto_state *proto;
	const char *name;
	bool autostart, dynamic, available;
	unsigned int updated;
	enum interface_state state;
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
struct proto_shell_handler {
	struct { unsigned int flags; const char *name; } proto;
	const char *script_name;
};
struct proto_shell_state {
	struct interface_proto_state proto;
	struct list_head deps;
	int sm, checkup_interval, teardown_timeout, checkup_timeout;
	bool renew_pending, proto_task_killed;
	struct netifd_process script_task, proto_task;
	struct proto_shell_handler *handler;
	struct blob_attr *config;
	int last_error;
};
#include "dependency-type.inc"
static struct vlist_tree interfaces;
static LIST_HEAD(iface_all_users);
static unsigned int deletes, script_starts;
static void interface_list_update(struct vlist_tree *tree, struct vlist_node *new,
	struct vlist_node *old) {}
/* One execution-plane entry per kernel key, even when two netifd lists own
 * identical routes. Keep real lookup/vlist/install/delete functions above it. */
static struct { struct device *dev; struct device_route route; } kernel_routes[32];
static size_t kernel_count;
static struct proto_shell_handler shell_handler = {
	.proto = { .flags = PROTO_FLAG_NO_TASK, .name = "wireguard" },
	.script_name = "wireguard.sh"
};

static bool same_kernel_route(struct device *dev, const struct device_route *r, size_t n)
{
	const struct device_route *k = &kernel_routes[n].route;
	return kernel_routes[n].dev == dev &&
		(r->flags & DEVADDR_FAMILY) == (k->flags & DEVADDR_FAMILY) &&
		r->mask == k->mask && r->metric == k->metric && r->table == k->table &&
		!memcmp(&r->addr, &k->addr, sizeof(r->addr));
}
static int system_add_route(struct device *dev, struct device_route *route)
{
	size_t n;
	for (n = 0; n < kernel_count && !same_kernel_route(dev, route, n); n++) {}
	assert(n < sizeof(kernel_routes) / sizeof(kernel_routes[0]));
	if (n == kernel_count) kernel_count++;
	kernel_routes[n].dev = dev; kernel_routes[n].route = *route;
	return 0;
}
static int system_del_route(struct device *dev, struct device_route *route)
{
	deletes++;
	for (size_t n = 0; n < kernel_count; n++) {
		if (!same_kernel_route(dev, route, n)) continue;
		kernel_routes[n] = kernel_routes[--kernel_count];
		return 0;
	}
	return -1;
}

static bool interface_ip_find_addr_target(struct interface *iface, union if_addr *addr, bool v6)
{ (void)iface; (void)addr; (void)v6; return false; }
static void interface_remove_user(struct interface_user *);
static void interface_add_user(struct interface_user *, struct interface *);
static void proto_shell_if_down_cb(struct interface_user *, struct interface *, enum interface_event);
static void proto_shell_if_up_cb(struct interface_user *, struct interface *, enum interface_event);
static int proto_shell_handler(struct interface_proto_state *, enum interface_proto_cmd, bool);
static void interface_set_available(struct interface *iface, bool available)
{ iface->available = available; }
static void uloop_timeout_cancel(int *t) { (void)t; }
static void uloop_timeout_set(int *t, int n) { (void)t; (void)n; }
static char *blobmsg_format_json(struct blob_attr *b, bool list) { return strdup("{}"); }
static int netifd_start_process(const char **argv, char **envp, struct netifd_process *p)
{ script_starts++; return 0; }
static void netifd_ucode_check_network_enabled(void) {}
static void device_release(struct device_user *dev) {}
static void __set_config_state(struct interface *iface, int state) { abort(); }
static void interface_flush_state(struct interface *iface) { abort(); }
static void interface_event(struct interface *iface, enum interface_event ev)
{
	struct interface_user *u, *tmp;
	list_for_each_entry_safe(u, tmp, &iface->users, list) u->cb(u, iface, ev);
	list_for_each_entry_safe(u, tmp, &iface_all_users, list) u->cb(u, iface, ev);
}
static void interface_proto_event(struct interface_proto_state *p, enum interface_proto_cmd cmd, bool force)
{ assert(proto_shell_handler(p, cmd, force) == 0); }
static void down_event(struct interface_proto_state *p, int ev)
{ assert(ev == IFPEV_DOWN); p->iface->state = IFS_DOWN; }
#include "route-functions.inc"
#include "dependency-functions.inc"
#include "interface-functions.inc"
#include "task-finish.inc"

static void init_iface(struct interface *iface)
{
	memset(iface, 0, sizeof(*iface));
	INIT_LIST_HEAD(&iface->users);
	iface->proto_ip.iface = iface;
	iface->config_ip.iface = iface;
	iface->proto_ip.enabled = iface->config_ip.enabled = true;
	iface->state = IFS_UP;
	vlist_init(&iface->proto_ip.route, route_cmp, interface_update_proto_route);
	vlist_init(&iface->config_ip.route, route_cmp, interface_update_proto_route);
	vlist_init(&iface->host_routes, route_cmp, interface_update_host_route);
}
static void add_route(struct interface_ip_settings *ip, bool v6, bool host)
{
	struct device_route *r = calloc(1, sizeof(*r));
	r->flags = (v6 ? DEVADDR_INET6 : DEVADDR_INET4) | DEVROUTE_METRIC;
	r->metric = 40;
	if (host) {
		r->mask = v6 ? 128 : 32;
		assert(inet_pton(v6 ? AF_INET6 : AF_INET,
			v6 ? "2001:db8::1" : "198.51.100.1", &r->addr) == 1);
	}
	vlist_add(&ip->route, &r->node, r);
}
static void init_state(struct proto_shell_state *s, struct interface *iface)
{
	memset(s, 0, sizeof(*s));
	INIT_LIST_HEAD(&s->deps);
	s->proto.iface = iface;
	s->proto.proto_event = down_event;
	s->sm = S_TEARDOWN;
	s->handler = &shell_handler;
	iface->proto = &s->proto;
}
static union if_addr address(bool v6)
{
	union if_addr addr = {};
	assert(inet_pton(v6 ? AF_INET6 : AF_INET, v6 ? "2001:db8::1" : "198.51.100.1", &addr) == 1);
	return addr;
}
static void attach(struct proto_shell_state *s, struct interface *wan, bool v6)
{
	struct proto_shell_dependency *d = calloc(1, sizeof(*d) + 1);
	d->host = address(v6);
	d->v6 = v6;
	d->proto = s;
	d->dep.iface = wan;
	d->dep.cb = proto_shell_if_down_cb;
	list_add(&d->list, &s->deps);
	list_add(&d->dep.list, &wan->users);
	assert(interface_ip_add_target_route(&d->host, v6, wan, false, false) == wan);
}
int main(void)
{
	struct interface wan, other_wan, a, b;
	struct proto_shell_state first, second;
	struct device wan_dev = { .ifname = "wan" }, other_dev = { .ifname = "other" };
	for (int v6 = 0; v6 < 2; v6++) {
		init_iface(&wan); init_iface(&other_wan); init_iface(&a); init_iface(&b);
		vlist_init(&interfaces, avl_strcmp, interface_list_update);
		vlist_add(&interfaces, &wan.node, "wan");
		init_state(&first, &a); init_state(&second, &b);
		wan.l3_dev.dev = &wan_dev; other_wan.l3_dev.dev = &other_dev;
		add_route(&wan.proto_ip, v6, false); add_route(&other_wan.proto_ip, v6, false);
		attach(&first, &wan, v6); attach(&second, &wan, v6);
		assert(wan.host_routes.avl.count == 1);
		first.script_task.uloop.pending = true;
		proto_shell_task_finish(&first, NULL);
		assert(wan.host_routes.avl.count == 1 && !list_empty(&first.deps));
		first.script_task.uloop.pending = false;
		proto_shell_task_finish(&first, NULL);
		assert(list_empty(&first.deps) && wan.host_routes.avl.count == 1);
		proto_shell_task_finish(&second, NULL);
		assert(wan.host_routes.avl.count == 0);

		/* Identical addresses on different uplinks have different owners. */
		init_state(&first, &a); init_state(&second, &b);
		attach(&first, &wan, v6); attach(&second, &other_wan, v6);
		proto_shell_clear_host_dep(&first);
		assert(wan.host_routes.avl.count == 0 && other_wan.host_routes.avl.count == 1);
		proto_shell_clear_host_dep(&second);
		assert(other_wan.host_routes.avl.count == 0);

		/* Explicit ubus ownership survives either insertion order. */
		union if_addr addr = address(v6);
		for (int order = 0; order < 2; order++) {
			init_state(&first, &a);
			if (order) interface_ip_add_target_route(&addr, v6, &wan, false, true);
			attach(&first, &wan, v6);
			if (!order) interface_ip_add_target_route(&addr, v6, &wan, false, true);
			proto_shell_clear_host_dep(&first);
			assert(wan.host_routes.avl.count == 1);
			vlist_flush_all(&wan.host_routes);
		}

		/* Automatic link-loss teardown retains dependency-driven recovery. */
		init_state(&first, &a); a.autostart = true;
		attach(&first, &wan, v6);
		proto_shell_task_finish(&first, NULL);
		assert(!list_empty(&first.deps) && wan.host_routes.avl.count == 1);
		struct proto_shell_dependency *automatic = list_first_entry(&first.deps,
			struct proto_shell_dependency, list);
		/* The next automatic teardown is still entitled to resume on UP. */
		first.sm = S_TEARDOWN;
		proto_shell_if_down_cb(&automatic->dep, &wan, IFEV_DOWN);
		proto_shell_task_finish(&first, NULL);
		assert(wan.host_routes.avl.count == 0 && !list_empty(&iface_all_users));
		interface_event(&wan, IFEV_UP);
		assert(automatic->dep.iface == &wan && a.available);
		assert(wan.host_routes.avl.count == 1 && list_empty(&iface_all_users));
		a.autostart = false;
		proto_shell_clear_host_dep(&first);
		assert(wan.host_routes.avl.count == 0);

		/* UCI and protocol host routes have independent lifetime, regardless
		 * of whether they are installed before or after the dependency. */
		for (int config = 0; config < 2; config++) {
			struct interface_ip_settings *ip = config ? &wan.config_ip : &wan.proto_ip;
			for (int before = 0; before < 2; before++) {
				init_state(&first, &a); a.autostart = false;
				if (before) add_route(ip, v6, true);
				attach(&first, &wan, v6);
				if (before) assert(wan.host_routes.avl.count == 0);
				if (!before) add_route(ip, v6, true);
				proto_shell_task_finish(&first, NULL);
				assert(wan.host_routes.avl.count == 0);
				bool found = false;
				struct device_route *r, *tmp;
				vlist_for_each_element_safe(&ip->route, r, node, tmp) {
					if (r->mask != (v6 ? 128U : 32U)) continue;
					assert(r->enabled && !r->failed);
					for (size_t n = 0; n < kernel_count; n++)
						if (same_kernel_route(&wan_dev, r, n)) found = true;
					vlist_delete(&ip->route, &r->node);
				}
				assert(found);
			}
		}

		/* Missing uplink leaves the protocol DOWN with a global dependency.
		 * Exercise real ifdown and UP callbacks, not a direct clear helper. */
		init_state(&first, &a); a.autostart = true;
		attach(&first, &wan, v6);
		struct proto_shell_dependency *d = list_first_entry(&first.deps,
			struct proto_shell_dependency, list);
		proto_shell_if_down_cb(&d->dep, &wan, IFEV_DOWN);
		proto_shell_task_finish(&first, NULL);
		assert(a.state == IFS_DOWN && !list_empty(&first.deps));
		unsigned int starts = script_starts;
		interface_set_down(&a);
		assert(!a.autostart && list_empty(&first.deps));
		assert(script_starts == starts && first.sm == S_IDLE);
		interface_event(&wan, IFEV_UP);
		assert(list_empty(&iface_all_users) && wan.host_routes.avl.count == 0);
		assert(a.state == IFS_DOWN && !a.autostart);
		/* DOWN alone does not prove that protocol children have drained. */
		for (int task = 0; task < 2; task++) {
			init_state(&first, &a); first.sm = S_IDLE;
			attach(&first, &wan, v6);
			struct netifd_process *pending = task ? &first.proto_task : &first.script_task;
			pending->uloop.pending = true;
			starts = script_starts;
			interface_set_down(&a);
			assert(!list_empty(&first.deps) && first.sm == S_TEARDOWN);
			assert(script_starts == starts + 1);
			pending->uloop.pending = false;
			proto_shell_task_finish(&first, NULL);
			assert(list_empty(&first.deps) && wan.host_routes.avl.count == 0);
		}
		vlist_flush_all(&wan.proto_ip.route); vlist_flush_all(&other_wan.proto_ip.route);
		assert(kernel_count == 0);
	}
	assert(deletes > 0);
	puts("netifd endpoint ownership: PASS");
	return 0;
}
