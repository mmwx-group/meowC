package miu

import (
	"context"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/transport/anytls/padding"
)

// testdata/miu-padding-profile-v1.json is shared with the miu repo and the
// Swift client: every implementation has to produce the same scheme text.
type derivedVectors struct {
	Vectors []struct {
		ID     string `json:"id"`
		PSK    string `json:"psk"`
		Token  string `json:"auth_token_sha256_hex"`
		Scheme struct {
			Text string `json:"text"`
			MD5  string `json:"md5"`
		} `json:"scheme"`
	} `json:"vectors"`
}

func loadDerivedVectors(t *testing.T) derivedVectors {
	t.Helper()
	raw, err := os.ReadFile("testdata/miu-padding-profile-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var v derivedVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Vectors) == 0 {
		t.Fatal("no vectors")
	}
	return v
}

func TestDerivedSchemeVectors(t *testing.T) {
	for _, v := range loadDerivedVectors(t).Vectors {
		token := authToken(strings.TrimSpace(v.PSK))
		if hex.EncodeToString(token[:]) != v.Token {
			t.Fatalf("%s: token %x", v.ID, token)
		}
		text, err := derivedScheme(token)
		if err != nil {
			t.Fatalf("%s: %v", v.ID, err)
		}
		if text != v.Scheme.Text {
			t.Fatalf("%s: scheme\n%s\nwant\n%s", v.ID, text, v.Scheme.Text)
		}
		if got := fmt.Sprintf("%x", md5.Sum([]byte(text))); got != v.Scheme.MD5 {
			t.Fatalf("%s: md5 %s", v.ID, got)
		}
		if p := padding.NewPaddingFactory([]byte(text)); p == nil || p.Md5 != v.Scheme.MD5 {
			t.Fatalf("%s: not a usable scheme", v.ID)
		}
	}
}

// The derived scheme stays within the bounds every implementation relies on.
func TestDerivedSchemeBounds(t *testing.T) {
	for i := 0; i < 2000; i++ {
		text, err := derivedScheme(authToken(fmt.Sprintf("bounds-psk-%04d-xxxxxxxx", i)))
		if err != nil {
			t.Fatal(err)
		}
		p := padding.NewPaddingFactory([]byte(text))
		if p == nil || p.Stop < 5 || p.Stop > 10 {
			t.Fatalf("stop: %q", text)
		}
		total := 0
		for pkt := uint32(0); pkt < p.Stop; pkt++ {
			sizes := p.GenerateRecordPayloadSizes(pkt)
			if len(sizes) == 0 {
				t.Fatalf("packet %d has no sizes: %q", pkt, text)
			}
			for _, s := range sizes {
				if s == padding.CheckMark {
					continue
				}
				if pkt > 0 && (s < 128 || s >= 8192) {
					t.Fatalf("record size %d: %q", s, text)
				}
				total += s
			}
		}
		if total > derivedBudget {
			t.Fatalf("over budget %d: %q", total, text)
		}
	}
}

// A new client starts out with the scheme derived from its PSK, different users
// get different schemes, a configured scheme wins, a broken one is refused.
func TestClientInitialScheme(t *testing.T) {
	v := loadDerivedVectors(t).Vectors[0]
	c, err := NewClient(context.Background(), ClientConfig{PSK: "  " + v.PSK + "\n"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if got := c.padding.Load(); string(got.RawScheme) != v.Scheme.Text || got.Md5 != v.Scheme.MD5 {
		t.Fatalf("initial scheme: %q", got.RawScheme)
	}

	other, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if other.padding.Load().Md5 == v.Scheme.MD5 {
		t.Fatal("two PSKs share a scheme")
	}

	explicit := "stop=2\n0=10-20\n1=200-300"
	c2, err := NewClient(context.Background(), ClientConfig{PSK: testPSK, PaddingScheme: explicit})
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	if string(c2.padding.Load().RawScheme) != explicit {
		t.Fatalf("explicit scheme: %q", c2.padding.Load().RawScheme)
	}

	if _, err := NewClient(context.Background(), ClientConfig{PSK: testPSK, PaddingScheme: "0=1-2"}); err == nil {
		t.Fatal("a scheme without stop is accepted")
	}
}

// entry0 is the "0=lo-hi" range of a scheme text: the auth padding, lo <= n < hi.
func entry0(t *testing.T, text string) (int, int) {
	t.Helper()
	for _, line := range strings.Split(text, "\n") {
		if r, ok := strings.CutPrefix(line, "0="); ok {
			los, his, _ := strings.Cut(r, "-")
			lo, err1 := strconv.Atoi(los)
			hi, err2 := strconv.Atoi(his)
			if err1 != nil || err2 != nil {
				t.Fatalf("entry 0: %q", line)
			}
			return lo, hi
		}
	}
	t.Fatalf("no entry 0: %q", text)
	return 0, 0
}

// What a new client actually sends on a lane: the auth padding drawn from entry
// 0 of the derived scheme, and that scheme's md5 in Settings, so a server that
// derives the same scheme has nothing to send back.
func TestHelloAnnouncesDerivedScheme(t *testing.T) {
	for _, v := range loadDerivedVectors(t).Vectors {
		c, err := NewClient(context.Background(), ClientConfig{PSK: v.PSK})
		if err != nil {
			t.Fatal(err)
		}
		a, b := net.Pipe()
		lo, hi := entry0(t, v.Scheme.Text)
		token := authToken(strings.TrimSpace(v.PSK))
		for i := 0; i < 20; i++ {
			got := c.hello(newLane(c, a))
			if hex.EncodeToString(got[:authTokenLen]) != hex.EncodeToString(token[:]) {
				t.Fatalf("%s: token %x", v.ID, got[:authTokenLen])
			}
			n := int(binary.BigEndian.Uint16(got[authTokenLen:]))
			if n < lo || n >= hi && !(lo == hi && n == lo) {
				t.Fatalf("%s: auth padding %d outside %d-%d", v.ID, n, lo, hi)
			}
			frame := got[authTokenLen+2+n:]
			if frame[0] != frSettings || int(frame[1])<<8|int(frame[2]) != len(frame)-frameHead {
				t.Fatalf("%s: settings frame %x", v.ID, frame)
			}
			if want := "padding-md5=" + v.Scheme.MD5; !strings.HasSuffix(string(frame[frameHead:]), want) {
				t.Fatalf("%s: settings %q, want %s", v.ID, frame[frameHead:], want)
			}
		}
		a.Close()
		b.Close()
		c.Close()
	}
}

// Over the test server: the first lane announces the derived scheme. A server
// update that is not a usable scheme is ignored, the derived one stays in use
// and is announced on the next lane again.
func TestDerivedSchemeOverLanes(t *testing.T) {
	derived, err := derivedScheme(authToken(testPSK))
	if err != nil {
		t.Fatal(err)
	}
	want := padding.NewPaddingFactory([]byte(derived)).Md5

	s := newTestServer(t)
	s.scheme = "not a scheme"
	c, _ := newTestClient(t, s, nil)
	c.minIdle = 0
	testEcho(t, testOpen(t, c, echoDst), []byte("x"))
	if got := c.padding.Load(); string(got.RawScheme) != derived {
		t.Fatalf("a broken update replaced the scheme: %q", got.RawScheme)
	}
	c.closeIdle() // the next stream dials a new lane
	testEcho(t, testOpen(t, c, echoDst), []byte("y"))
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.settings) != 2 {
		t.Fatalf("settings: %q", s.settings)
	}
	for i, settings := range s.settings {
		if settings != "v=2\nraw=0\npadding-md5="+want {
			t.Fatalf("lane %d settings: %q, want md5 %s", i, settings, want)
		}
	}
}
