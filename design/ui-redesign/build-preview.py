#!/usr/bin/env python3
"""把 boards/*.dc.html 打成单文件 preview.html：任何浏览器直接打开，不依赖 claude.ai。

.dc.html 是设计画布（claude.ai Design artifact）的画板格式：{{hole}} / <sc-for> / <sc-if> / <dc-import> +
一个 `class Component extends DCLogic { renderVals() }`。这里内嵌一个最小运行时把它们渲染出来，
交互（setState 重绘、onClick）照旧；品牌图从 /_blob/<id> 换成 data URI。

用法：python3 design/ui-redesign/build-preview.py   → design/ui-redesign/preview.html
"""
import base64
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
BOARDS = ROOT / "boards"
ASSETS = ROOT / "assets"

# 画板里引用的 artifact 资产 id → 本地图
BLOBS = {
    "618ef02428a266b2c495af9b06f888be": "art-light.png",
    "0d9f9a6adebe8f94f9e5a6c2eae537cf": "art-dark.png",
}


def data_uri(name: str) -> str:
    return "data:image/png;base64," + base64.b64encode((ASSETS / name).read_bytes()).decode()


def main() -> None:
    # 图只嵌一份：源码里保留 /_blob/<id>，运行时按 id 换成 data URI（之前逐画板替换，同一张图嵌了 6 遍）
    assets = {f"/_blob/{blob}": data_uri(file) for blob, file in BLOBS.items()}
    sources = {path.name: path.read_text(encoding="utf-8") for path in sorted(BOARDS.glob("*.dc.html"))}
    canvas = json.loads((ROOT / "canvas.json").read_text(encoding="utf-8"))

    # 源码里有 </script>，塞进 <script> 前得把 "</" 写成 "<\/"（JSON 合法）
    def embed(obj) -> str:
        return json.dumps(obj, ensure_ascii=False).replace("</", "<\\/")

    html = (TEMPLATE.replace("__SOURCES__", embed(sources))
            .replace("__CANVAS__", embed(canvas))
            .replace("__ASSETS__", embed(assets)))
    out = ROOT / "preview.html"
    out.write_text(html, encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size / 1024:.0f} KB, {len(sources)} boards)")


TEMPLATE = r"""<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MeowX 界面重设计（Android + Windows）· 预览</title>
<style>
  :root { --bg: #ECE7E1; --ink: #2A2130; --ink2: #665A69; --card: #FFFFFF; --soft: #FCE4EC; --rose: #B02E63; --line: rgba(42,33,48,.12); }
  :root.dark { --bg: #0F0D12; --ink: #F7F0F3; --ink2: #B9ADBB; --card: #1F1A25; --soft: rgba(243,166,191,.16); --rose: #F7B6CB; --line: rgba(255,255,255,.12); }
  html, body { margin: 0; background: var(--bg); color: var(--ink); font-family: -apple-system, "SF Pro Text", "PingFang SC", system-ui, sans-serif; }
  header { position: sticky; top: 0; z-index: 10; display: flex; align-items: center; gap: 14px; flex-wrap: wrap; padding: 14px 24px; background: var(--card); border-bottom: 1px solid var(--line); }
  header h1 { margin: 0; font-size: 18px; font-weight: 700; flex-grow: 1; }
  header label { display: flex; align-items: center; gap: 6px; font-size: 13px; color: var(--ink2); }
  header select, header button { font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 10px; padding: 6px 10px; cursor: pointer; }
  header button[aria-pressed="true"] { background: var(--soft); color: var(--rose); border-color: var(--rose); font-weight: 600; }
  header a { color: var(--rose); font-size: 13px; }
  main { padding: 20px 24px 60px; display: flex; flex-direction: column; gap: 36px; }
  section h2 { margin: 0 0 12px; font-size: 14px; font-weight: 700; color: var(--ink2); letter-spacing: .5px; }
  .row { display: flex; gap: 28px; align-items: flex-start; overflow-x: auto; padding: 4px 4px 16px; }
  .card { flex-shrink: 0; display: flex; flex-direction: column; gap: 8px; }
  .card .name { font-size: 13px; font-weight: 600; color: var(--ink2); white-space: nowrap; }
  .card .name small { font-weight: 400; margin-left: 6px; }
  .frame { position: relative; overflow: hidden; background: var(--card); box-shadow: 0 10px 30px rgba(42,33,48,.18); outline: 1px solid var(--line); }
  .frame iframe { position: absolute; left: 0; top: 0; border: 0; transform-origin: 0 0; background: transparent; }
  .card.flash .frame { outline: 3px solid var(--rose); }
  .hint { font-size: 12px; color: var(--ink2); }
</style>
</head>
<body>
<header>
  <h1>MeowX 界面重设计（Android + Windows）· 本地预览</h1>
  <span class="hint">画板可交互：点电源钮 / 节点 / 分段，画板内链接会跳到对应画板</span>
  <label>缩放
    <select id="zoom">
      <option value="0.5">50%</option>
      <option value="0.67">67%</option>
      <option value="0.75" selected>75%</option>
      <option value="1">100%</option>
    </select>
  </label>
  <button id="dark" aria-pressed="false">深色模式</button>
  <a href="https://claude.ai/artifact/38dW3AVAMm5xVu1VTr5zGa" target="_blank" rel="noopener">在 claude.ai 打开画布 ↗</a>
</header>
<main id="main"></main>
<script>
const SOURCES = __SOURCES__;
const CANVAS = __CANVAS__;
const ASSETS = __ASSETS__;
function asset(v) { return typeof v === 'string' && ASSETS[v] ? ASSETS[v] : v; }

// ---- 最小 .dc.html 运行时 ----
const HOLE_FULL = /^\{\{\s*([^{}]+?)\s*\}\}$/;
const HOLE_ANY = /\{\{\s*([^{}]+?)\s*\}\}/g;

class DCLogic {
  constructor(props, repaint) { this.props = props; this.state = {}; this._repaint = repaint; }
  setState(patch) {
    const next = typeof patch === 'function' ? patch(this.state) : patch;
    this.state = Object.assign({}, this.state, next);
    this._repaint();
  }
  forceUpdate() { this._repaint(); }
}

const parsed = {};
function parseBoard(name) {
  if (parsed[name]) return parsed[name];
  const doc = new DOMParser().parseFromString(SOURCES[name], 'text/html');
  const xdc = doc.querySelector('x-dc');
  const helmet = xdc.querySelector('helmet');
  const styles = helmet ? helmet.innerHTML : '';
  if (helmet) helmet.remove();
  const script = doc.querySelector('script[data-dc-script]');
  const propDefs = JSON.parse(script.getAttribute('data-props') || '{}');
  const defaults = {};
  Object.keys(propDefs).forEach(function (k) {
    if (k.charAt(0) !== '$' && propDefs[k] && Object.prototype.hasOwnProperty.call(propDefs[k], 'default')) defaults[k] = propDefs[k].default;
  });
  const Cls = new Function('DCLogic', script.textContent + '\nreturn Component;')(DCLogic);
  const imports = Array.prototype.map.call(xdc.querySelectorAll('dc-import'), function (e) { return e.getAttribute('name') + '.dc.html'; });
  const titleEl = doc.querySelector('title');
  return (parsed[name] = { styles: styles, defaults: defaults, Cls: Cls, template: xdc, imports: imports, title: titleEl ? titleEl.textContent : name });
}

function allStyles(name, seen) {
  seen = seen || {};
  if (seen[name]) return '';
  seen[name] = true;
  const b = parseBoard(name);
  return b.styles + b.imports.map(function (n) { return allStyles(n, seen); }).join('');
}

function stripHole(s) { const m = (s || '').match(HOLE_FULL); return m ? m[1] : (s || ''); }

function lookup(path, ctx) {
  path = path.trim();
  if (path === 'true') return true;
  if (path === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(path)) return Number(path);
  const parts = path.split('.');
  let cur = Object.prototype.hasOwnProperty.call(ctx.scope, parts[0]) ? ctx.scope[parts[0]] : ctx.vals[parts[0]];
  for (let i = 1; i < parts.length && cur != null; i++) cur = cur[parts[i]];
  return cur;
}

function interp(str, ctx) {
  return str.replace(HOLE_ANY, function (m, p) { const v = lookup(p, ctx); return v == null ? '' : String(v); });
}

function renderChildren(parent, ctx, doc, out, env) {
  Array.prototype.forEach.call(parent.childNodes, function (n) { renderNode(n, ctx, doc, out, env); });
}

function renderNode(node, ctx, doc, out, env) {
  if (node.nodeType === 3) { out.appendChild(doc.createTextNode(interp(node.nodeValue, ctx))); return; }
  if (node.nodeType !== 1) return;
  const tag = node.localName;
  if (tag === 'sc-for') {
    const list = lookup(stripHole(node.getAttribute('list')), ctx) || [];
    const as = node.getAttribute('as') || 'item';
    list.forEach(function (item, i) {
      const scope = Object.assign({}, ctx.scope);
      scope[as] = item; scope.$index = i;
      renderChildren(node, { vals: ctx.vals, scope: scope }, doc, out, env);
    });
    return;
  }
  if (tag === 'sc-if') {
    if (lookup(stripHole(node.getAttribute('value')), ctx)) renderChildren(node, ctx, doc, out, env);
    return;
  }
  if (tag === 'dc-import') {
    const child = node.getAttribute('name') + '.dc.html';
    const props = {};
    Array.prototype.forEach.call(node.attributes, function (a) {
      if (a.name === 'name' || a.name.indexOf('hint-') === 0) return;
      const key = a.name.replace(/-([a-z])/g, function (m, c) { return c.toUpperCase(); });
      const m = a.value.match(HOLE_FULL);
      props[key] = m ? lookup(m[1], ctx) : interp(a.value, ctx);
    });
    const host = doc.createElement('div');
    host.style.display = 'contents';
    out.appendChild(host);
    mount(child, props, host, doc, env);
    return;
  }
  const el = doc.createElementNS(node.namespaceURI, tag);
  Array.prototype.forEach.call(node.attributes, function (a) {
    if (a.name.indexOf('hint-') === 0) return;
    const m = a.value.match(HOLE_FULL);
    if (m) {
      const v = lookup(m[1], ctx);
      if (typeof v === 'function') { if (a.name.indexOf('on') === 0) el.addEventListener(a.name.slice(2), v); return; }
      if (v == null) return;
      el.setAttribute(a.name, String(asset(v)));
    } else {
      el.setAttribute(a.name, asset(interp(a.value, ctx)));
    }
  });
  if (tag === 'a') {
    const href = el.getAttribute('href') || '';
    if (/\.dc\.html$/.test(href)) el.addEventListener('click', function (e) { e.preventDefault(); env.goTo(href.replace(/^.*\//, '')); });
  }
  renderChildren(node, ctx, doc, el, env);
  out.appendChild(el);
}

function mount(name, props, host, doc, env) {
  const b = parseBoard(name);
  const merged = Object.assign({}, b.defaults, props);
  let inst;
  const paint = function () {
    const vals = inst.renderVals() || {};
    const frag = doc.createDocumentFragment();
    renderChildren(b.template, { vals: vals, scope: {} }, doc, frag, env);
    while (host.firstChild) host.removeChild(host.firstChild);
    host.appendChild(frag);
  };
  inst = new b.Cls(merged, paint);
  paint();
  return inst;
}

// ---- 画廊 ----
const main = document.getElementById('main');
const zoomSel = document.getElementById('zoom');
const darkBtn = document.getElementById('dark');
let dark = false;
const cards = {};

function build() {
  main.innerHTML = '';
  document.documentElement.classList.toggle('dark', dark);
  const scale = Number(zoomSel.value);
  const rows = {};
  const order = CANVAS.order.slice();
  order.forEach(function (name) {
    const b = CANVAS.boards[name];
    const key = String(b.y);
    (rows[key] = rows[key] || []).push(name);
  });
  const rowTitles = {};
  Object.keys(CANVAS.notes || {}).forEach(function (id) { const n = CANVAS.notes[id]; if (n.kind === 'title1') rowTitles[String(n.y)] = n.text; });
  const env = { goTo: function (name) {
    const card = cards[name];
    if (!card) return;
    card.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
    card.classList.add('flash');
    setTimeout(function () { card.classList.remove('flash'); }, 900);
  } };
  Object.keys(rows).sort(function (a, b) { return Number(a) - Number(b); }).forEach(function (y) {
    const section = document.createElement('section');
    const h2 = document.createElement('h2');
    const titleKeys = Object.keys(rowTitles).sort(function (a, b) { return Number(a) - Number(b); });
    let title = '';
    titleKeys.forEach(function (k) { if (Number(k) <= Number(y)) title = rowTitles[k]; });
    h2.textContent = title || ('第 ' + y + ' 行');
    section.appendChild(h2);
    const row = document.createElement('div');
    row.className = 'row';
    // iframe 得先挂进文档才有 contentDocument，所以 section / row 先上树再往里塞画板
    section.appendChild(row);
    main.appendChild(section);
    rows[y].forEach(function (name) {
      const b = CANVAS.boards[name];
      const card = document.createElement('div');
      card.className = 'card';
      cards[name] = card;
      const label = document.createElement('div');
      label.className = 'name';
      label.textContent = b.title || name;
      const small = document.createElement('small');
      small.textContent = b.w + '×' + b.h;
      label.appendChild(small);
      card.appendChild(label);
      const frame = document.createElement('div');
      frame.className = 'frame';
      frame.style.width = (b.w * scale) + 'px';
      frame.style.height = (b.h * scale) + 'px';
      frame.style.borderRadius = ((b.radius || 0) * scale) + 'px';
      const iframe = document.createElement('iframe');
      iframe.setAttribute('title', b.title || name);
      iframe.width = b.w; iframe.height = b.h;
      iframe.style.width = b.w + 'px'; iframe.style.height = b.h + 'px';
      iframe.style.transform = 'scale(' + scale + ')';
      frame.appendChild(iframe);
      card.appendChild(frame);
      row.appendChild(card);
      const d0 = iframe.contentDocument;
      d0.open();
      d0.write('<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;overflow:hidden;background:transparent}</style>' + allStyles(name) + '</head><body></body></html>');
      d0.close();
      const d = iframe.contentDocument;
      mount(name, { dark: dark }, d.body, d, env);
    });
  });
}

zoomSel.addEventListener('change', build);
darkBtn.addEventListener('click', function () { dark = !dark; darkBtn.setAttribute('aria-pressed', String(dark)); build(); });
build();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
