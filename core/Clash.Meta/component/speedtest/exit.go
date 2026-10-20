package speedtest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// ExitInfo 测速出站的出口：测速开始时经同一个出站（不过规则）向 Cloudflare 要 /meta 得到。界面显示「AS2516 KDDI · 203.0.113.8」。
type ExitInfo struct {
	IP      string `json:"ip"`
	ASN     int    `json:"asn,omitempty"`
	Org     string `json:"org,omitempty"`
	Country string `json:"country,omitempty"`
}

const speedExitTimeout = 5 * time.Second

// speedExitURL 单测里换成本地服务器
var speedExitURL = "https://speed.cloudflare.com/meta"

// speedParseExit 解析 speed.cloudflare.com/meta 的 JSON，只取 clientIp / asn / asOrganization / country
// （其余字段如 colo 是对象，不解析）。clientIp 缺了算失败；asn 是数字，也认字符串（可带 AS 前缀）。
func speedParseExit(data []byte) (*ExitInfo, error) {
	var raw struct {
		ClientIP       string          `json:"clientIp"`
		ASN            json.RawMessage `json:"asn"`
		ASOrganization string          `json:"asOrganization"`
		Country        string          `json:"country"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	if raw.ClientIP == "" {
		return nil, errors.New("没有出口 IP")
	}
	info := &ExitInfo{IP: raw.ClientIP, Org: strings.TrimSpace(raw.ASOrganization), Country: raw.Country}
	if len(raw.ASN) > 0 {
		var n json.Number
		var s string
		if json.Unmarshal(raw.ASN, &n) == nil {
			if v, err := n.Int64(); err == nil {
				info.ASN = int(v)
			}
		} else if json.Unmarshal(raw.ASN, &s) == nil {
			s = strings.TrimPrefix(strings.ToUpper(strings.TrimSpace(s)), "AS")
			if v, err := strconv.Atoi(s); err == nil {
				info.ASN = v
			}
		}
	}
	return info, nil
}

// speedFetchExit 用给定的客户端请求 url（不带 Referer 时 Cloudflare 回 403 + {}），最多等 speedExitTimeout。
func speedFetchExit(ctx context.Context, client *http.Client, url string) (*ExitInfo, error) {
	ctx, cancel := context.WithTimeout(ctx, speedExitTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "MeowX")
	req.Header.Set("Referer", "https://speed.cloudflare.com/")
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("返回 %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return nil, err
	}
	return speedParseExit(data)
}

// speedQueryExit 测速准备阶段与测速并行跑：查到就写进进度，查不到（Cloudflare 不通、超时）只记一行日志，不影响测速。
func speedQueryExit(ctx context.Context, runID int, proxy constant.Proxy) {
	client := speedClient(proxy, false)
	defer client.CloseIdleConnections()
	info, err := speedFetchExit(ctx, client, speedExitURL)
	if err != nil && ctx.Err() == nil {
		log.Warnln("[MeowX] 测速：经 %s 查出口失败（%s）", proxy.Name(), speedDescribe(err))
	}
	speedUpdate(runID, func(p *Progress) {
		p.Exit = info
		p.ExitPending = false
	})
}
