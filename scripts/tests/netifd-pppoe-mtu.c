/* Copyright (C) 2026 Ning <mimallaus@gmail.com> */
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libubox/blobmsg.h>

struct proto_handler { const char *name; };
struct interface {
	bool device_config;
	struct proto_handler *proto_handler;
	struct blob_attr *config;
};
struct device {
	bool default_config, iface_config;
	struct interface *config_iface;
	void *type;
};
static struct blob_attr *applied;
static void device_apply_config(struct device *dev, void *type, struct blob_attr *data)
{
	assert(type == dev->type);
	assert(!applied);
	applied = blob_memdup(data);
	assert(applied);
}

#include "function.inc"

static void check(const char *proto, int mtu, bool omit_mtu, bool explicit_device)
{
	struct proto_handler handler = { .name = proto };
	struct blob_buf input = {};
	struct interface iface = { .device_config = true, .proto_handler = &handler };
	struct device dev = { .default_config = !explicit_device };
	struct blob_attr *attr, *got;
	size_t rem;
	int count = 0, actual = 0;
	void *nested;

	blob_buf_init(&input, 0);
	blobmsg_add_string(&input, "proto", proto);
	if (mtu)
		blobmsg_add_u32(&input, "mtu", mtu);
	blobmsg_add_string(&input, "macaddr", "02:00:00:00:00:01");
	blobmsg_add_u32(&input, "mtu6", 1280);
	blobmsg_add_u8(&input, "multicast", 0);
	nested = blobmsg_open_table(&input, "data");
	blobmsg_add_u32(&input, "mtu", 9000);
	blobmsg_close_table(&input, nested);
	iface.config = input.head;
	struct blob_attr *original = blob_memdup(input.head);
	interface_set_device_config(&iface, &dev);
	assert(blob_pad_len(original) == blob_pad_len(input.head));
	assert(!memcmp(original, input.head, blob_pad_len(original)));
	if (explicit_device) {
		assert(!applied);
	} else {
		assert(applied && dev.config_iface == &iface && dev.iface_config);
		blobmsg_for_each_attr(attr, original, rem) {
			bool found = false;
			size_t left;
			blobmsg_for_each_attr(got, applied, left) {
				if (strcmp(blobmsg_name(attr), blobmsg_name(got)))
					continue;
				found = true;
				assert(blob_pad_len(attr) == blob_pad_len(got));
				assert(!memcmp(attr, got, blob_pad_len(attr)));
			}
			if (omit_mtu && !strcmp(blobmsg_name(attr), "mtu"))
				assert(!found);
			else {
				assert(found);
				count++;
			}
		}
		blobmsg_for_each_attr(got, applied, rem)
			actual++;
		assert(count == actual);
	}
	free(applied);
	applied = NULL;
	free(original);
	blob_buf_free(&input);
}

int main(void)
{
	check("pppoe", 1492, true, false);
	check("pppoe", 1400, true, false);
	check("pppoe", 1500, true, false);
	check("pppoe", 0, true, false);
	check("pppoe", 1492, true, true);
	check("dhcp", 1400, false, false);
	check("static", 1500, false, false);
	check("ppp", 1400, false, false);
	check("dhcp", 1400, false, true);
	puts("PASS: PPPoE parent MTU isolation, other attributes/protocols and explicit devices");
	return 0;
}
