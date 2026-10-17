package route

import (
	"github.com/metacubex/mihomo/component/speedtest"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

// MeowX：网络测速（OpenWrt 版的 LuCI 用；测法见 component/speedtest）。
// POST /speedtest {"source","proxy","connections"} 开始（proxy 只认节点），GET 拉进度，DELETE 取消。
func speedtestRouter() http.Handler {
	r := chi.NewRouter()
	r.Post("/", func(w http.ResponseWriter, r *http.Request) {
		var params speedtest.Params
		if err := render.DecodeJSON(r.Body, &params); err != nil {
			render.Status(r, http.StatusBadRequest)
			render.JSON(w, r, ErrBadRequest)
			return
		}
		if reason := speedtest.Start(params); reason != "" {
			render.Status(r, http.StatusBadRequest)
			render.JSON(w, r, newError(reason))
			return
		}
		render.NoContent(w, r)
	})
	r.Get("/", func(w http.ResponseWriter, r *http.Request) {
		render.JSON(w, r, speedtest.Status())
	})
	r.Delete("/", func(w http.ResponseWriter, r *http.Request) {
		speedtest.Stop()
		render.NoContent(w, r)
	})
	return r
}
