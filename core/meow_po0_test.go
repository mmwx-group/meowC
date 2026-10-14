package main

import "testing"

// 日志里的上报地址 / url.Error 只留脱敏 token（与 Dart 端 maskPo0Token 同一写法）。
func TestMeowPo0Redact(t *testing.T) {
	cases := map[string]string{
		`Post "https://1.2.3.4/api/firewall/pgnfw_abcd1234wxyz/add?slot=2": dial tcp 1.2.3.4:443: i/o timeout`: `Post "https://1.2.3.4/api/firewall/pgnfw_••••wxyz/add?slot=2": dial tcp 1.2.3.4:443: i/o timeout`,
		"https://fw.example.com:8443/api/firewall/pgnfw_abcd123/add":                                           "https://fw.example.com:8443/api/firewall/pgnfw_••••/add",
		"https://[::1]/api/firewall/secret/add":                                                                "https://[::1]/api/firewall/••••/add",
		"no token here":                                                                                        "no token here",
	}
	for in, want := range cases {
		if got := meowPo0Redact(in); got != want {
			t.Errorf("meowPo0Redact(%q) = %q, want %q", in, got, want)
		}
	}
}
