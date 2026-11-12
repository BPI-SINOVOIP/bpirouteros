package osrouter

import (
	"os"
	"testing"
	"time"

	"github.com/tailscale/netlink"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus/eventbustest"
	"tailscale.com/version/distro"
)

// Embedding preserves real execution while selecting the CLI fallback.
type productIPCommand struct{ osCommandRunner }

func TestBpiRouterProductRules(t *testing.T) {
	parent := os.Getenv("BPIR_PARENT_NETNS")
	current, err := os.Readlink("/proc/self/ns/net")
	if parent == "" {
		t.Skip("requires the isolated-network test runner")
	}
	if err != nil || current == parent {
		t.Fatal("refusing to change the host network namespace")
	}
	old := getDistroFunc
	getDistroFunc = func() distro.Distro { return distro.OpenWrt }
	defer func() { getDistroFunc = old }()
	for _, cli := range []bool{false, true} {
		name := "netlink"
		var cmd commandRunner = osCommandRunner{}
		if cli {
			name = "command"
			cmd = productIPCommand{osCommandRunner{}}
		}
		t.Run(name, func(t *testing.T) {
			bus := eventbustest.NewBus(t)
			iface := &netlink.Dummy{LinkAttrs: netlink.LinkAttrs{Name: "ts-test"}}
			if err := netlink.LinkAdd(iface); err != nil {
				t.Fatal(err)
			}
			defer netlink.LinkDel(iface)
			newRouter := func() *linuxRouter {
				r, err := newUserspaceRouterAdvanced(logger.Discard, "ts-test", nil, cmd, nil, bus)
				if err != nil {
					t.Fatal(err)
				}
				lr := r.(*linuxRouter)
				lr.nfr = NewFakeOS(t).nfr
				if lr.ipPolicyPrefBase != 1300 || !lr.ipRuleAvailable || !lr.v6Available {
					t.Fatalf("unexpected platform setup: base=%d rules=%v ipv6=%v", lr.ipPolicyPrefBase, lr.ipRuleAvailable, lr.v6Available)
				}
				return lr
			}
			check := func(want int) bool {
				for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
					rules, err := netlink.RuleList(family)
					if err != nil {
						t.Fatal(err)
					}
					count := 0
					for _, rule := range rules {
						if rule.Priority >= 1300 && rule.Priority < 1400 {
							count++
							if rule.Priority != 1370 || rule.Table != 52 || !rule.Invert || rule.Mark != 0x80000 || rule.Mask != 0xff0000 {
								t.Fatalf("wrong product rule: %+v", rule)
							}
						}
					}
					if count != want {
						return false
					}
				}
				return true
			}
			r := newRouter()
			if err := r.addIPRules(); err != nil || !check(1) {
				t.Fatalf("add: %v", err)
			}
			// A restarted process must replace stale rules without duplicates.
			r.eventClient.Close()
			r = newRouter()
			if err := r.addIPRules(); err != nil || !check(1) {
				t.Fatalf("restart: %v", err)
			}
			if err := r.delIPRules(); err != nil || !check(0) {
				t.Fatalf("delete: %v", err)
			}
			r.onIPRuleDeleted(52, 1370)
			deadline := time.Now().Add(3 * time.Second)
			for !check(1) && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if !check(1) {
				t.Fatal("deleted product rule was not restored")
			}
			if err := r.Close(); err != nil || !check(0) {
				t.Fatalf("normal close: %v", err)
			}
		})
	}
}
