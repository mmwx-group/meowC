package main

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func directFetchJSON(t *testing.T, p meowDirectFetchParams) map[string]any {
	t.Helper()
	data, err := json.Marshal(meowDirectFetch(p))
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestMeowDirectFetchFollowsRedirectAndPassesHeaders(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/old":
			http.Redirect(w, r, "/x/TOKEN", http.StatusFound)
		case "/x/TOKEN":
			if r.Header.Get("X-MeowX-Mesh") != "on" || r.Header.Get("User-Agent") != "MeowX/0.6.2 (Linux)" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.Header().Set("Subscription-Userinfo", "upload=1; download=2")
			_, _ = w.Write([]byte("proxies: []\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	out := directFetchJSON(t, meowDirectFetchParams{
		URL:     srv.URL + "/old",
		Headers: map[string]string{"User-Agent": "MeowX/0.6.2 (Linux)", "X-MeowX-Mesh": "on", "Host": "evil"},
	})
	if out["status"] != float64(200) {
		t.Fatalf("status = %v, out = %v", out["status"], out)
	}
	if out["url"] != srv.URL+"/x/TOKEN" {
		t.Fatalf("url = %v", out["url"])
	}
	headers, _ := out["headers"].(map[string]any)
	info, _ := headers["subscription-userinfo"].([]any)
	if len(info) != 1 || info[0] != "upload=1; download=2" {
		t.Fatalf("headers = %v", headers)
	}
	body, _ := base64.StdEncoding.DecodeString(out["body"].(string))
	if string(body) != "proxies: []\n" {
		t.Fatalf("body = %q", body)
	}
}

func TestMeowDirectFetchReturnsHTTPErrorStatus(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	defer srv.Close()
	out := directFetchJSON(t, meowDirectFetchParams{URL: srv.URL + "/missing"})
	if out["status"] != float64(404) {
		t.Fatalf("out = %v", out)
	}
}

func TestMeowDirectFetchConnectFailureIsError(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	out := directFetchJSON(t, meowDirectFetchParams{URL: "http://" + addr + "/x/T", TimeoutMs: 3000})
	if _, ok := out["error"].(string); !ok {
		t.Fatalf("out = %v", out)
	}
}
