#!/bin/bash
# A refused reload must call preflight under the lock before rendering rules.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export work
sed -e "s|/usr/bin/bpirouter-apid|$work/helper|g" \
    -e "s|/var/run/|$work/|g" "$1" > "$work/fw4"
cat >"$work/helper" <<'SH'
#!/bin/sh
set -eu
[ "$1" = --s2s-firewall=preflight ]
[ /proc/self/fd/9 -ef "$work/fw4.lock" ]
if flock -n "$work/fw4.lock" true; then exit 1; fi
touch "$work/checked"
exit 10
SH
chmod +x "$work/helper"
for cmd in utpl nft ubus; do
    printf '#!/bin/sh\ntouch "$work/unexpected"\nexit 1\n' > "$work/$cmd"
    chmod +x "$work/$cmd"
done
for action in start reload restart; do
    if [ "$action" != start ]; then touch "$work/fw4.state"; fi
    if PATH="$work:$PATH" bash "$work/fw4" "$action"; then exit 1; fi
    test -e "$work/checked"
    test ! -e "$work/unexpected"
    if [ "$action" != start ]; then test -e "$work/fw4.state"; fi
    rm "$work/checked"
done
