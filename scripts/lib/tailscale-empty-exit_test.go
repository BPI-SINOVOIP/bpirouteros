package ipn

import (
	"encoding/json"
	"net/netip"
	"reflect"
	"testing"
)

func TestBpiRouterEmptyExitConfig(t *testing.T) {
	for _, tc := range []struct {
		name string
		old  Prefs
	}{
		{"id", Prefs{ExitNodeID: "old-exit"}},
		{"ip", Prefs{ExitNodeIP: netip.MustParseAddr("100.64.0.9")}},
		{"automatic", Prefs{AutoExitNode: AnyExitNode}},
		{"automatic_with_selected_id", Prefs{AutoExitNode: AnyExitNode, ExitNodeID: "old-exit"}},
		{"already_empty", Prefs{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var config ConfigVAlpha
			if err := json.Unmarshal([]byte(`{"version":"alpha0","exitNode":""}`), &config); err != nil {
				t.Fatal(err)
			}
			update, err := config.ToPrefs()
			if err != nil {
				t.Fatal(err)
			}
			p := tc.old.Clone()
			p.Hostname, p.CorpDNS, p.RouteAll = "retained-host", true, true
			for range 2 {
				p.ApplyEdits(&update)
				if p.ExitNodeID != "" || p.ExitNodeIP.IsValid() || p.AutoExitNode.IsSet() {
					t.Fatal("empty config left an exit-node selection")
				}
				if p.Hostname != "retained-host" || !p.CorpDNS || !p.RouteAll {
					t.Fatal("unrelated preferences changed")
				}
			}
		})
	}

	t.Run("omitted_exit_keeps_selection", func(t *testing.T) {
		old := &Prefs{ExitNodeID: "old-exit", AutoExitNode: AnyExitNode, WantRunning: true}
		update, err := (&ConfigVAlpha{Version: "alpha0"}).ToPrefs()
		if err != nil {
			t.Fatal(err)
		}
		p := old.Clone()
		p.ApplyEdits(&update)
		if !reflect.DeepEqual(p, old) {
			t.Fatal("omitted exit setting changed existing preferences")
		}
	})
}
