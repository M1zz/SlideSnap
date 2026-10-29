// 장표스냅 웹 체험: 비스듬히 찍은 사진을 네 모서리로 반듯하게 편다.
// 앱은 Vision 으로 모서리를 찾고 CIPerspectiveCorrection 으로 편다. 여기서는 같은 데모 사진
// (docs/screenshots/raw/<언어>/before.jpg)에서 찾아 둔 모서리로 같은 원근 변환을 한다.
(() => {
  const root = document.getElementById("demo");
  if (!root) return;
  const T = JSON.parse(root.dataset.text);
  const q = s => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  const up = (document.querySelector('link[rel="icon"]').getAttribute("href") || "").replace("icon.png", "");
  const SRC = `${up}screenshots/raw/${document.documentElement.lang}/before.jpg`;
  const W = 2400, H = 1800;                                           // 데모 사진 크기
  const FOUND = [[322, 305], [2100, 411], [2124, 1245], [290, 1290]];   // 왼위, 오위, 오아래, 왼아래
  let quad = FOUND.map(p => p.slice()), shown = false;

  root.innerHTML = `
    <figure class="ds-photo">
      <div class="ds-frame">
        <img src="${SRC}" alt="${q(T.photo)}" width="${W}" height="${H}" draggable="false">
        <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true"><polygon class="ds-quad"/></svg>
        ${T.corners.map((c, i) => `<button type="button" class="ds-dot" data-i="${i}" aria-label="${q(c)}"></button>`).join("")}
      </div>
      <figcaption class="muted small">${q(T.photo)}</figcaption>
    </figure>
    <div class="ds-side">
      <figure class="ds-result">
        <div class="ds-out"><canvas role="img" aria-label="${q(T.result)}"></canvas><p class="muted small">${q(T.waiting)}</p></div>
        <figcaption class="muted small">${q(T.result)}</figcaption>
      </figure>
      <div class="ds-actions">
        <button type="button" class="ds-go">${q(T.straighten)}</button>
        <button type="button" class="ds-reset">${q(T.reset)}</button>
      </div>
      <p class="muted small">${q(T.hint)}</p>
      <p class="muted small">${q(T.note)}</p>
    </div>`;

  const $ = s => root.querySelector(s);
  const img = $("img"), poly = $(".ds-quad"), canvas = $("canvas"), out = $(".ds-out");
  const dots = [...root.querySelectorAll(".ds-dot")];

  function drawQuad() {
    poly.setAttribute("points", quad.map(p => p.join(",")).join(" "));
    dots.forEach((d, i) => { d.style.left = `${quad[i][0] / W * 100}%`; d.style.top = `${quad[i][1] / H * 100}%`; });
  }

  // 사진 픽셀: 절반 크기로 한 번만 읽어 둔다.
  const S = 0.5;
  let px;
  function pixels() {
    if (px) return px;
    const c = document.createElement("canvas");
    c.width = W * S; c.height = H * S;
    const g = c.getContext("2d");
    g.drawImage(img, 0, 0, c.width, c.height);
    return (px = g.getImageData(0, 0, c.width, c.height));
  }

  // 단위 사각형 → 네 모서리 (Heckbert 의 사각형-사변형 원근 사상)
  function mapper([[x0, y0], [x1, y1], [x2, y2], [x3, y3]]) {
    const dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2;
    const sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3, den = dx1 * dy2 - dx2 * dy1;
    const g = (sx * dy2 - dx2 * sy) / den, h = (dx1 * sy - sx * dy1) / den;
    const a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, d = y1 - y0 + g * y1, e = y3 - y0 + h * y3;
    return (u, v) => { const w = g * u + h * v + 1; return [(a * u + b * v + x0) / w, (d * u + e * v + y0) / w]; };
  }

  // 편 장표의 크기는 마주 보는 두 변 중 긴 쪽으로 정한다 (앱의 원근 보정과 같은 방식).
  const len = (p, q) => Math.hypot(p[0] - q[0], p[1] - q[1]);
  function straighten() {
    const src = pixels(), sw = src.width, sh = src.height, s = src.data;
    const w0 = Math.max(len(quad[0], quad[1]), len(quad[3], quad[2]));
    const h0 = Math.max(len(quad[0], quad[3]), len(quad[1], quad[2]));
    const k = Math.min(1, 960 / w0 / S);
    const ow = Math.max(1, Math.round(w0 * S * k)), oh = Math.max(1, Math.round(h0 * S * k));
    canvas.width = ow; canvas.height = oh;
    const ctx = canvas.getContext("2d"), res = ctx.createImageData(ow, oh), o = res.data, map = mapper(quad);
    for (let y = 0; y < oh; y++) {
      for (let x = 0; x < ow; x++) {
        let [u, v] = map((x + 0.5) / ow, (y + 0.5) / oh);
        u = Math.min(sw - 1.001, Math.max(0, u * S)); v = Math.min(sh - 1.001, Math.max(0, v * S));
        const ix = u | 0, iy = v | 0, fx = u - ix, fy = v - iy, i = (iy * sw + ix) * 4, j = (y * ow + x) * 4;
        for (let c = 0; c < 3; c++) {   // 이웃 네 점을 섞는다
          const top = s[i + c] * (1 - fx) + s[i + 4 + c] * fx;
          const bot = s[i + sw * 4 + c] * (1 - fx) + s[i + sw * 4 + 4 + c] * fx;
          o[j + c] = top * (1 - fy) + bot * fy;
        }
        o[j + 3] = 255;
      }
    }
    ctx.putImageData(res, 0, 0);
    if (!shown) { shown = true; out.classList.add("done"); }
  }

  let queued = false;
  function update() {
    drawQuad();
    if (!shown || queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; straighten(); });
  }

  const ready = () => img.complete && img.naturalWidth > 0;
  $(".ds-go").addEventListener("click", () => {
    root.dataset.used = "1";
    if (ready()) straighten(); else img.addEventListener("load", straighten, { once: true });
  });
  $(".ds-reset").addEventListener("click", () => {
    quad = FOUND.map(p => p.slice()); shown = false;
    out.classList.remove("done"); drawQuad();
  });

  // 모서리 끌기: 앱의 '모서리 조정' 처럼. 키보드는 방향키(Shift 를 누르면 크게).
  const frame = $(".ds-frame");
  dots.forEach((dot, i) => {
    dot.addEventListener("pointerdown", e => { dot.setPointerCapture(e.pointerId); dot.classList.add("drag"); });
    dot.addEventListener("pointermove", e => {
      if (!dot.hasPointerCapture(e.pointerId)) return;
      const r = frame.getBoundingClientRect();
      quad[i] = [Math.min(W, Math.max(0, (e.clientX - r.left) / r.width * W)),
                 Math.min(H, Math.max(0, (e.clientY - r.top) / r.height * H))];
      update();
    });
    dot.addEventListener("pointerup", () => dot.classList.remove("drag"));
    dot.addEventListener("keydown", e => {
      const step = e.shiftKey ? 80 : 16;
      const m = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key];
      if (!m) return;
      e.preventDefault();
      quad[i] = [Math.min(W, Math.max(0, quad[i][0] + m[0])), Math.min(H, Math.max(0, quad[i][1] + m[1]))];
      update();
    });
  });

  drawQuad();
})();
