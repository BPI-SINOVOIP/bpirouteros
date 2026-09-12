#!/bin/sh
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-$BUILD_DIR/openwrt}
PREPARE=$BUILD_DIR/scripts/prepare.sh
OPENWRT_SOURCE_HELPER=$BUILD_DIR/scripts/lib/openwrt-source.sh
LIFECYCLE_PATCH=$BUILD_DIR/patches/common/base-files/004-cellular-netifd-lifecycle-owner.patch
MANUFACTURER_PATCH=$BUILD_DIR/patches/common/base-files/005-comgt-ncm-normalize-manufacturer.patch
DATA_FORMAT_PATCH=$BUILD_DIR/patches/common/base-files/006-uqmi-data-format-evidence.patch
QMI=package/network/utils/uqmi/files/lib/netifd/proto/qmi.sh
NCM=package/network/utils/comgt/files/ncm.sh
QMI_MAKEFILE=package/network/utils/uqmi/Makefile
UQMI_CTL_PATCH=package/network/utils/uqmi/patches/100-fix-ctl-data-format-request.patch

[ -f "$LIFECYCLE_PATCH" ] || { echo "missing cellular lifecycle patch" >&2; exit 1; }
[ -f "$MANUFACTURER_PATCH" ] || { echo "missing NCM manufacturer normalization patch" >&2; exit 1; }
[ -f "$DATA_FORMAT_PATCH" ] || { echo "missing QMI data-format evidence patch" >&2; exit 1; }
[ -f "$PREPARE" ] || { echo "missing OpenWrt prepare script" >&2; exit 1; }
[ -f "$OPENWRT_SOURCE_HELPER" ] || { echo "missing OpenWrt source helper" >&2; exit 1; }
[ -f "$OPENWRT_DIR/$QMI" ] || { echo "missing qmi.sh source" >&2; exit 1; }
[ -f "$OPENWRT_DIR/$NCM" ] || { echo "missing ncm.sh source" >&2; exit 1; }
[ -f "$OPENWRT_DIR/$QMI_MAKEFILE" ] || { echo "missing uqmi package Makefile" >&2; exit 1; }
grep -Fq 'bpir_reset_openwrt_source "$WORK_DIR"' "$PREPARE" || {
	echo "prepare does not use the shared OpenWrt source reset" >&2
	exit 1
}
awk -v path="$UQMI_CTL_PATCH" '
	/^bpir_reset_openwrt_source\(\)/ { in_reset=1; next }
	in_reset && index($0, path) { found=1 }
	in_reset && /^}/ { exit !found }
	END { if (in_reset) exit !found; exit 1 }
' "$OPENWRT_SOURCE_HELPER" || {
	echo "prepare does not remove the product-owned uqmi patch before replay" >&2
	exit 1
}

scratch_dir=
cleanup() {
	[ -z "$scratch_dir" ] || rm -r -- "$scratch_dir"
}
trap cleanup EXIT HUP INT TERM

stage_source() {
	scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/bpirouter-cellular-netifd.XXXXXX")
	mkdir -p "$scratch_dir/$(dirname "$QMI")" "$scratch_dir/$(dirname "$NCM")" \
		"$scratch_dir/$(dirname "$UQMI_CTL_PATCH")"
	cp "$OPENWRT_DIR/$QMI" "$scratch_dir/$QMI"
	cp "$OPENWRT_DIR/$NCM" "$scratch_dir/$NCM"
	cp "$OPENWRT_DIR/$QMI_MAKEFILE" "$scratch_dir/$QMI_MAKEFILE"
	[ ! -f "$OPENWRT_DIR/$UQMI_CTL_PATCH" ] || \
		cp "$OPENWRT_DIR/$UQMI_CTL_PATCH" "$scratch_dir/$UQMI_CTL_PATCH"
	check_dir=$scratch_dir
}

stage_source
for patch in "$LIFECYCLE_PATCH" "$MANUFACTURER_PATCH" "$DATA_FORMAT_PATCH"; do
	if git -C "$check_dir" apply --check "$patch" 2>/dev/null; then
		git -C "$check_dir" apply "$patch"
	elif git -C "$check_dir" apply --reverse --check "$patch" 2>/dev/null; then
		:
	else
		echo "cellular netifd patch neither applies nor matches the source tree: $patch" >&2
		exit 1
	fi
done

bash -n "$check_dir/$QMI" "$check_dir/$NCM"
grep -Fqx 'PKG_RELEASE:=3' "$check_dir/$QMI_MAKEFILE" || {
	echo "uqmi package release was not advanced for the changed binary" >&2
	exit 1
}
[ -f "$check_dir/$UQMI_CTL_PATCH" ] || {
	echo "QMI data-format patch does not install the uqmi CTL fix" >&2
	exit 1
}
grep -Fq 'QMI_INIT(format, QMI_CTL_DATA_FORMAT_QOS_FLOW_HEADER_ABSENT)' "$check_dir/$UQMI_CTL_PATCH" || {
	echo "uqmi CTL data-format request does not disable the QoS header explicitly" >&2
	exit 1
}
grep -Fq 'QMI_INIT(protocol, mode)' "$check_dir/$UQMI_CTL_PATCH" || {
	echo "uqmi CTL data-format request does not encode the selected protocol" >&2
	exit 1
}
grep -Fq 'return QMI_CMD_REQUEST;' "$check_dir/$UQMI_CTL_PATCH" || {
	echo "uqmi CTL data-format command does not send its request" >&2
	exit 1
}

# R4-Pro logs proved that the old parser passed "quectel\r" to json_select,
# which rejected the supported modem as UNSUPPORTED_MODEM. An extra CR before
# LF reproduces that parsed value and pins the normalization at the real edge.
(
	INCLUDE_ONLY=1
	. "$check_dir/$NCM"
	gcom() {
		printf 'AT+CGMI\r\r\nQuectel\r\r\nOK\r\n'
	}
	manufacturer=$(ncm_get_manufacturer /dev/ignored)
	[ "$manufacturer" = quectel ] || {
		echo "NCM manufacturer normalization returned an unsafe JSON key" >&2
		exit 1
	}
	gcom() {
		printf 'AT+CGMI\r\n+CFUN: 1\r\nQuectel\r\nOK\r\n'
	}
	manufacturer=$(ncm_get_manufacturer /dev/ignored)
	[ "$manufacturer" = quectel ] || {
		echo "NCM manufacturer detection consumed an unsolicited modem report" >&2
		exit 1
	}
	gcom() {
		printf 'AT+CGMI\r\n+CGMI: Quectel\r\nOK\r\n'
	}
	manufacturer=$(ncm_get_manufacturer /dev/ignored)
	[ "$manufacturer" = quectel ] || {
		echo "NCM manufacturer detection rejected a tagged CGMI response" >&2
		exit 1
	}
)
if [ "$(grep -Fc 'manufacturer=$(ncm_get_manufacturer "$device")' "$check_dir/$NCM")" -ne 2 ]; then
	echo "NCM setup and teardown do not share the normalized manufacturer reader" >&2
	exit 1
fi

# The modem's acknowledged link-layer protocol, not a successful command exit,
# decides the driver mode. Exercise WDA precedence, CTL compatibility fallback,
# bounded transient reads, fail-closed unknown data, and exact sysfs readback.
(
	INCLUDE_ONLY=1
	. "$check_dir/$QMI"

	qmi_read_json_value() {
		local expression="$1" payload
		payload=$(cat)
		case "$expression:$payload" in
			'@:'*'"802.3"'*) printf '%s\n' 802.3 ;;
			'@:'*'"raw-ip"'*) printf '%s\n' raw-ip ;;
			'@["link-layer-protocol"]:'*'"link-layer-protocol":"802.3"'*) printf '%s\n' 802.3 ;;
			'@["link-layer-protocol"]:'*'"link-layer-protocol":"raw-ip"'*) printf '%s\n' raw-ip ;;
		esac
	}
	uqmi() {
		case " $* " in
			*' --set-data-format '*)
				printf 'ctl\n' >> "$ctl_set_log"
				printf '%s\n' "$ctl_result"
				;;
			*' --wda-set-data-format '*) return 0 ;;
			*' --wda-get-data-format '*)
				printf 'read\n' >> "$qmi_get_log"
				printf '%s\n' "$wda_result"
				;;
			*) return 1 ;;
		esac
	}
	sleep() { :; }

	qmi_get_log=$scratch_dir/qmi-get.log
	ctl_set_log=$scratch_dir/ctl-set.log
	: > "$ctl_set_log"
	ctl_result='"802.3"'
	wda_result='{"link-layer-protocol":"raw-ip"}'
	dataformat=$(qmi_negotiate_data_format /dev/ignored)
	[ "$dataformat" = raw-ip ] || {
		echo "readable WDA data format was not accepted" >&2
		exit 1
	}
	[ "$(wc -l < "$qmi_get_log")" -eq 1 ] || {
		echo "valid WDA data format was retried unnecessarily" >&2
		exit 1
	}
	[ ! -s "$ctl_set_log" ] || {
		echo "CTL compatibility path ran despite readable WDA evidence" >&2
		exit 1
	}

	: > "$qmi_get_log"
	: > "$ctl_set_log"
	ctl_result='"802.3"'
	wda_result='{"link-layer-protocol":"unknown"}'
	dataformat=$(qmi_negotiate_data_format /dev/ignored)
	[ "$dataformat" = 802.3 ] || {
		echo "valid CTL data format was not used when WDA was unavailable" >&2
		exit 1
	}
	[ "$(wc -l < "$qmi_get_log")" -eq 3 ] || {
		echo "unreadable WDA data format did not use the bounded three-read policy" >&2
		exit 1
	}
	[ "$(wc -l < "$ctl_set_log")" -eq 1 ] || {
		echo "unreadable WDA did not use exactly one CTL compatibility request" >&2
		exit 1
	}

	: > "$qmi_get_log"
	: > "$ctl_set_log"
	ctl_result='"unknown"'
	wda_result='{"link-layer-protocol":"unknown"}'
	if qmi_negotiate_data_format /dev/ignored >/dev/null; then
		echo "unknown QMI data formats were accepted" >&2
		exit 1
	fi
	[ "$(wc -l < "$qmi_get_log")" -eq 3 ] || {
		echo "unknown QMI data format escaped the bounded read policy" >&2
		exit 1
	}
	[ "$(wc -l < "$ctl_set_log")" -eq 1 ] || {
		echo "unknown QMI data format did not bound the CTL compatibility request" >&2
		exit 1
	}

	raw_ip_path=$scratch_dir/raw_ip
	printf 'N\n' > "$raw_ip_path"
	qmi_apply_data_format raw-ip "$raw_ip_path"
	[ "$(cat "$raw_ip_path")" = Y ] || {
		echo "raw-IP modem evidence was not applied to the driver" >&2
		exit 1
	}
	qmi_apply_data_format 802.3 "$raw_ip_path"
	[ "$(cat "$raw_ip_path")" = N ] || {
		echo "802.3 modem evidence did not clear stale raw-IP driver state" >&2
		exit 1
	}
	if qmi_apply_data_format unknown "$raw_ip_path"; then
		echo "unknown QMI data format was applied to the driver" >&2
		exit 1
	fi
	if qmi_apply_data_format raw-ip "$scratch_dir/missing_raw_ip"; then
		echo "raw-IP was accepted without the required driver attribute" >&2
		exit 1
	fi
	qmi_apply_data_format 802.3 "$scratch_dir/missing_raw_ip"
)

for script in "$check_dir/$QMI" "$check_dir/$NCM"; do
	if grep -q 'pincode' "$script"; then
		echo "netifd cellular proto still accepts or consumes pincode: $script" >&2
		exit 1
	fi
done
if grep -Eq 'uim-power-(off|on)' "$check_dir/$QMI"; then
	echo "qmi.sh still power-cycles SIM from the dial script" >&2
	exit 1
fi
if grep -Eq -- '--get-pin-status|--uim-get-sim-state|--uim-verify-pin1|--verify-pin1' "$check_dir/$QMI"; then
	echo "qmi.sh still performs SIM/PIN diagnosis during the dial phase" >&2
	exit 1
fi

awk '
	/^proto_qmi_setup\(\)/ { setup=1; next }
	/^qmi_wds_stop\(\)/ { setup=0 }
	setup && /dataformat="\$\(qmi_negotiate_data_format/ { negotiated=1 }
	setup && negotiated && /qmi_apply_data_format/ { applied=1 }
	setup && /proto_notify_error "\$interface" DATA_FORMAT_FAILED/ { failed_closed++ }
	setup && /--network-register/ && (!negotiated || !applied) { exit 1 }
	END { if (!negotiated || !applied || failed_closed != 2) exit 1 }
' "$check_dir/$QMI" || {
	echo "qmi.sh can register without explicit modem/driver data-format agreement" >&2
	exit 1
}

# proto_block_restart calls json_init in netifd-proto.sh. The setup scripts
# must first consume the complete input document, then block restart, and only
# then enter their physical command lifetime.
awk '
	/^proto_qmi_setup\(\)/ { setup=1; setup_seen=1; next }
	/^qmi_wds_stop\(\)/ { setup=0 }
	setup && !blocked && /json_get_vars .*device/ { input_device=1 }
	setup && /proto_block_restart "\$interface"/ {
		if (!input_device) exit 1
		blocked=1
		next
	}
	setup && blocked && !runtime_json && /json_get_(var|vars|values)|json_select/ { exit 1 }
	setup && /json_load / { runtime_json=1 }
	setup && $0 !~ /^[[:space:]]*#/ && /uqmi / && !blocked { exit 1 }
	END { if (!setup_seen || !input_device || !blocked) exit 1 }
' "$check_dir/$QMI" || {
	echo "qmi.sh does not consume netifd input before closing restart admission and running uqmi" >&2
	exit 1
}
awk '
	/^proto_ncm_setup\(\)/ { setup=1; setup_seen=1; next }
	/^proto_ncm_teardown\(\)/ { setup=0 }
	setup && !blocked && /json_get_vars .*device/ { input_device=1 }
	setup && /proto_block_restart "\$interface"/ {
		if (!input_device) exit 1
		blocked=1
		next
	}
	setup && blocked && !runtime_json && /json_get_(var|vars|values)|json_select/ { exit 1 }
	setup && /json_load / { runtime_json=1 }
	setup && $0 !~ /^[[:space:]]*#/ && /gcom |ncm_get_manufacturer/ && !blocked { exit 1 }
	END { if (!setup_seen || !input_device || !blocked) exit 1 }
' "$check_dir/$NCM" || {
	echo "ncm.sh does not consume netifd input before closing restart admission and running gcom" >&2
	exit 1
}

# The first successful proto update is the terminal signal consumed by apid.
# No physical command may remain below it in the setup lifetime.
awk '
	/^proto_qmi_setup\(\)/ { setup=1; next }
	/^qmi_wds_stop\(\)/ { setup=0 }
	setup && /proto_send_update "\$interface"/ { published=1; next }
	setup && published && $0 !~ /^[[:space:]]*#/ && /uqmi / { exit 1 }
	END { if (!published) exit 1 }
' "$check_dir/$QMI" || {
	echo "qmi.sh runs uqmi after publishing setup completion" >&2
	exit 1
}
awk '
	/^proto_ncm_setup\(\)/ { setup=1; next }
	/^proto_ncm_teardown\(\)/ { setup=0 }
	setup && /proto_send_update "\$interface"/ { published=1; next }
	setup && published && $0 !~ /^[[:space:]]*#/ && /gcom / { exit 1 }
	END { if (!published) exit 1 }
' "$check_dir/$NCM" || {
	echo "ncm.sh runs gcom after publishing setup completion" >&2
	exit 1
}

# Teardown has the same terminal contract: netifd may report down only after
# every physical disconnect/release command has returned.
awk '
	/^proto_qmi_teardown\(\)/ { teardown=1; next }
	teardown && /^}/ { teardown=0 }
	teardown && /proto_send_update "\$interface"/ { published=1; next }
	teardown && published && $0 !~ /^[[:space:]]*#/ && /uqmi / { exit 1 }
	END { if (!published) exit 1 }
' "$check_dir/$QMI" || {
	echo "qmi.sh runs uqmi after publishing teardown completion" >&2
	exit 1
}
awk '
	/^proto_ncm_teardown\(\)/ { teardown=1; next }
	teardown && /^}/ { teardown=0 }
	teardown && /proto_send_update "\$interface"/ { published=1; next }
	teardown && published && $0 !~ /^[[:space:]]*#/ && /gcom / { exit 1 }
	END { if (!published) exit 1 }
' "$check_dir/$NCM" || {
	echo "ncm.sh runs gcom after publishing teardown completion" >&2
	exit 1
}

echo "cellular netifd lifecycle and QMI data-format gate: PASS"
