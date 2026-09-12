# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# Strict sqm product-state reader.  Input is the uci config body prefixed by a
# `package 'sqm'` line; success means either the product-empty state (no
# sections at all) or the one complete bpir_sqm_wan queue the v1.5 renderer
# writes.  Anything partial or foreign exits non-zero.
#
# This mirrors parseStrictSQM in the backend.  The two must agree: a state this
# reader accepts is one the product can read back, and a state it rejects is one
# the product refuses to serve.  Keep them in step.

function bad() { invalid = 1; exit 1 }
function uq(v) {
	if (v !~ /^'[^']*'$/) bad()
	return substr(v, 2, length(v) - 2)
}
function add_key(s, k) {
	if (has[s SUBSEP k]) bad()
	has[s SUBSEP k] = 1
	key_count[s]++
}
function exact_keys(s, words,    a,n,i) {
	n = split(words, a, " ")
	if (key_count[s] != n) return 0
	for (i = 1; i <= n; i++) if (!has[s SUBSEP a[i]]) return 0
	return 1
}
function positive(v, max) {
	return v ~ /^[1-9][0-9]*$/ && (v + 0) >= 1 && (v + 0) <= max && sprintf("%d", v + 0) == v
}
function valid_combination(queue, script) {
	if (script == "piece_of_cake.qos" || script == "layer_cake.qos") return queue == "cake"
	if (script == "simple.qos" || script == "simplest.qos" || script == "simplest_tbf.qos")
		return queue == "cake" || queue == "fq_codel"
	return 0
}

{
	line = $0
	gsub(/^[ \t]+|[ \t]+$/, "", line)
	if (line == "") next
	n = split(line, f, /[ \t]+/)
	if (!saw_package) {
		if (n != 2 || f[1] != "package") bad()
		pkg = f[2]
		if (pkg ~ /^'/) pkg = uq(pkg)
		if (pkg != "sqm") bad()
		saw_package = 1
		next
	}
	if (f[1] == "config") {
		if (n != 3) bad()
		type = f[2]
		name = uq(f[3])
		if (type != "queue" || name !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || section_type[name] != "") bad()
		section_type[name] = type
		section_order[++section_count] = name
		current = name
		next
	}
	# A queue carries no lists.  Accepting one here would let a foreign shape
	# through that the backend's exactOptionSet counts differently.
	if (f[1] != "option") bad()
	if (current == "" || n != 3 || f[2] !~ /^[A-Za-z_][A-Za-z0-9_]*$/) bad()
	key = f[2]
	add_key(current, key)
	value_of[current SUBSEP key] = uq(f[3])
}

END {
	if (invalid || !saw_package) exit 1
	# The product-empty state is no sections at all -- unlike mwan3, sqm needs
	# no globals section to be a complete initial state.
	if (section_count == 0) exit 0
	if (section_count != 1 || section_order[1] != "bpir_sqm_wan") exit 1

	s = "bpir_sqm_wan"
	if (!exact_keys(s, "interface enabled download upload qdisc script linklayer overhead bpir_managed")) exit 1

	iface = value_of[s SUBSEP "interface"]
	enabled = value_of[s SUBSEP "enabled"]
	queue = value_of[s SUBSEP "qdisc"]
	script = value_of[s SUBSEP "script"]
	if (value_of[s SUBSEP "bpir_managed"] != "1") exit 1
	if (enabled != "0" && enabled != "1") exit 1
	if (iface !~ /^[A-Za-z0-9_.:-]+$/ || length(iface) < 1 || length(iface) > 15) exit 1
	if (!positive(value_of[s SUBSEP "download"], 10000000)) exit 1
	if (!positive(value_of[s SUBSEP "upload"], 10000000)) exit 1
	if (queue != "cake" && queue != "fq_codel") exit 1
	if (script != "piece_of_cake.qos" && script != "layer_cake.qos" &&
	    script != "simple.qos" && script != "simplest.qos" && script != "simplest_tbf.qos") exit 1
	if (!valid_combination(queue, script)) exit 1
	if (value_of[s SUBSEP "linklayer"] != "ethernet") exit 1
	if (value_of[s SUBSEP "overhead"] != "44") exit 1
	exit 0
}
