package outbound_test

import (
	"testing"

	"github.com/metacubex/mihomo/adapter"
)

// padding-scheme in the proxy YAML: a usable scheme is taken as the initial one
// (instead of the one derived from the PSK), one without a stop fails the proxy.
// Like the anytls parser on both ends, a size range it cannot read is skipped
// when sizes are drawn, it does not make the scheme unusable.
func TestMiuPaddingSchemeYAML(t *testing.T) {
	proxy := func(scheme any) map[string]any {
		m := map[string]any{
			"type":   "miu",
			"name":   "miu-padding",
			"server": "127.0.0.1",
			"port":   443,
			"psk":    "miu-test-psk-alpha-2026",
		}
		if scheme != nil {
			m["padding-scheme"] = scheme
		}
		return m
	}
	for name, scheme := range map[string]any{
		"derived":        nil,
		"lines":          []any{"stop=2", "0=30-30", "1=128-160"},
		"unreadable size": []any{"stop=2", "0=30-30", "1=a-b"},
	} {
		if _, err := adapter.ParseProxy(proxy(scheme)); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	for name, scheme := range map[string]any{
		"garbage": []any{"not-a-scheme"},
		"no stop": []any{"0=30-30", "1=128-160"},
	} {
		if _, err := adapter.ParseProxy(proxy(scheme)); err == nil {
			t.Fatalf("%s: a broken padding-scheme was accepted", name)
		}
	}
}
