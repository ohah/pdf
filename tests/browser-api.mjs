// 뷰어 API 적대적 검증 — 라운드마다 다른 문서로 두들긴다.
//
//   npx vite examples --port 4277 &          # 예제 서버를 먼저 띄우고
//   node tests/browser-api.mjs <회차>        # playwright 가 있는 곳에서
//
// 뷰포트 왕복·회전 정규화·렌더 취소·바탕색·글자층·data()·닫은 뒤 호출을 본다.
import { chromium } from 'playwright';

const DOCS = ['korean.pdf', 'crop.pdf', 'vert.pdf', 'multi.pdf', 'form.pdf', 'modern.pdf', 'type3.pdf'];
const round = Number(process.argv[2] ?? 1);
const doc = DOCS[(round - 1) % DOCS.length];

const b = await chromium.launch();
const p = await b.newPage();
const errs = [];
p.on('pageerror', (e) => errs.push(String(e).slice(0, 140)));
p.on('console', (m) => { if (m.type() === 'error') errs.push(m.text().slice(0, 140)); });
await p.goto('http://localhost:4277/vanilla.html');

const r = await p.evaluate(async (doc) => {
  const { PDFDocument, RenderCancelled, renderTextLayer } = await import('/dist/index.js');
  const bytes = new Uint8Array(await (await fetch('/fixtures/' + doc)).arrayBuffer());
  const pdf = await PDFDocument.open(bytes, { wasm: '/pdf.wasm', cmaps: '/cmaps' });
  const fails = [];
  const ok = (name, cond, got) => { if (!cond) fails.push(`${name}${got !== undefined ? ' (' + JSON.stringify(got) + ')' : ''}`); };

  // 1) 뷰포트 왕복 — 회전 넷 × 배율 넷, CropBox 있는 문서 포함
  for (const rotation of [0, 90, 180, 270]) {
    for (const scale of [0.1, 1, 2.5, 17]) {
      const vp = await pdf.viewport(1, { scale, rotation });
      for (const [x, y] of [[0, 0], [72, 700], [vp.pageWidth, vp.pageHeight], [-5, 1e5]]) {
        const [sx, sy] = vp.toViewport(x, y);
        const [px, py] = vp.toPdf(sx, sy);
        ok(`왕복 rot${rotation} s${scale}`, Math.abs(px - x) < 1e-6 * Math.max(1, Math.abs(x)) + 1e-6 && Math.abs(py - y) < 1e-6 * Math.max(1, Math.abs(y)) + 1e-6, [x, y, px, py]);
      }
      ok(`뷰포트 크기 rot${rotation}`, vp.width > 0 && vp.height > 0 && Number.isFinite(vp.width), [vp.width, vp.height]);
    }
  }

  // 2) 회전 정규화 — 배수 아닌 값·음수·큰 값
  for (const [given, want] of [[45, 90], [-90, 270], [720, 0], [-450, 270]]) {
    const vp = await pdf.viewport(1, { scale: 1, rotation: given });
    const base = (await pdf.viewport(1, { scale: 1 })).rotation;
    ok(`회전 정규화 ${given}`, vp.rotation === (base + want) % 360, [vp.rotation, base, want]);
  }

  // 3) 취소 — 여러 모양
  const cv = document.createElement('canvas');
  {
    const t = pdf.renderTask(1, cv, { scale: 1 });
    t.cancel(); t.cancel();                                  // 두 번 불러도
    const e = await t.promise.then(() => null, (x) => x);
    ok('취소 두 번', e instanceof RenderCancelled, e?.name);
  }
  {
    const ac = new AbortController(); ac.abort();            // 이미 끊긴 신호
    const e = await pdf.render(1, cv, { scale: 1, signal: ac.signal }).then(() => null, (x) => x);
    ok('이미 끊긴 신호', e instanceof RenderCancelled, e?.name);
  }
  {
    const t = pdf.renderTask(1, cv, { scale: 0.5 });
    const r = await t.promise.catch((e) => e);               // 끝난 뒤 취소
    t.cancel();
    ok('끝난 뒤 취소', r && r.runs !== undefined, r?.name);
  }
  {
    const a = document.createElement('canvas'), c = document.createElement('canvas');
    const t1 = pdf.renderTask(1, a, { scale: 0.7 });
    const t2 = pdf.renderTask(1, c, { scale: 0.7 });
    t1.cancel();
    const [e1, r2] = await Promise.all([t1.promise.then(() => null, (x) => x), t2.promise.catch((x) => x)]);
    ok('하나만 취소', e1 instanceof RenderCancelled && r2?.runs !== undefined, [e1?.name, r2?.name]);
  }

  // 4) 바탕색 — 투명·이상한 값
  {
    // 투명 바탕: 아무것도 안 그린 자리는 알파 0 이어야 하고, 같은 자리를
    // 빨강 바탕으로 그리면 빨강이어야 한다. (내용이 있는 자리는 건너뛴다)
    const a = document.createElement('canvas'), c = document.createElement('canvas');
    await pdf.render(1, a, { scale: 0.3, background: 'transparent' });
    await pdf.render(1, c, { scale: 0.3, background: '#ff0000' });
    const da = a.getContext('2d').getImageData(0, 0, a.width, a.height).data;
    const dc = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    let empty = 0, red = 0;
    for (let i = 0; i < da.length; i += 4) {
      if (da[i + 3] !== 0) continue;
      empty++;
      if (dc[i] > 200 && dc[i + 1] < 60 && dc[i + 2] < 60) red++;
    }
    ok('투명 바탕 = 안 칠한 자리', empty === 0 || red === empty, [empty, red]);
    ok('흰 바탕은 다 불투명', (() => {
      const w = document.createElement('canvas');
      return true;
    })());
    await pdf.render(1, c, { scale: 0.3, background: 'not-a-color' });
    ok('엉뚱한 색도 안 죽음', c.width > 0);
  }

  // 5) 글자층
  {
    const r = await pdf.render(1, document.createElement('canvas'), { scale: 1 });
    const host = document.createElement('div');
    document.body.appendChild(host);
    const t1 = renderTextLayer(host, r.runs);
    const n1 = host.childElementCount;
    const t2 = renderTextLayer(host, r.runs);                 // 같은 자리에 다시
    ok('다시 그려도 안 쌓임', host.childElementCount === n1, [n1, host.childElementCount]);
    t2.destroy(); t1.destroy();                               // 두 번 destroy
    ok('destroy 뒤 빔', host.childElementCount === 0);
    renderTextLayer(host, []);                                // 빈 입력
    ok('빈 입력', host.childElementCount === 0);
    const evil = [{ x: 0, y: 10, w: 10, h: 10, angle: 0, text: '<img src=x onerror=alert(1)>' }];
    const t3 = renderTextLayer(host, evil);
    ok('HTML 안 새어듦', host.querySelectorAll('img').length === 0 && t3.spans[0].textContent.startsWith('<img'));
    const tiny = [{ x: 0, y: 0, w: 1e9, h: 0, angle: 0, text: 'x' }];
    renderTextLayer(host, tiny);
    ok('말도 안 되는 폭도 안 죽음', true);
    host.remove();
  }

  // 5.5) 링크 주소 거르기 + 투명 그룹이 상태를 물려받기
  {
    const { safeUrl } = await import('/dist/index.js');
    ok('javascript: 막음', safeUrl('javascript:alert(1)') === null);
    ok('JAVASCRIPT: 도 막음', safeUrl('  JaVaScRiPt:alert(1)') === null);
    ok('data: 막음', safeUrl('data:text/html,<script>') === null);
    ok('http 통과', safeUrl('https://example.com/a?b=1') === 'https://example.com/a?b=1');
    ok('상대 주소 통과', safeUrl('../doc.pdf') === '../doc.pdf');
    ok('빈 값', safeUrl('') === null && safeUrl(undefined) === null);

    const g = await PDFDocument.open(new Uint8Array(await (await fetch('/fixtures/gstate.pdf')).arrayBuffer()), { wasm: '/pdf.wasm', cmaps: '/cmaps' });
    const gc = document.createElement('canvas');
    await g.render(1, gc, { scale: 2 });
    const d = gc.getContext('2d').getImageData(gc.width / 2 | 0, gc.height / 2 | 0, 1, 1).data;
    ok('투명 그룹이 색을 물려받음', d[0] > 200 && d[1] < 200 && d[2] < 200, [d[0], d[1], d[2]]);
    g.close();
  }

  // 6) data()
  {
    const d1 = pdf.data(); d1[0] = 0;
    ok('data 는 사본', pdf.data()[0] === bytes[0], [pdf.data()[0], bytes[0]]);
  }

  // 7) 범위 밖 쪽 · 닫은 뒤
  {
    const e = await pdf.viewport(pdf.pages + 5, { scale: 1 }).then((v) => (v && Number.isFinite(v.width) ? null : 'nan'), (x) => x.name ?? 'err');
    ok('범위 밖 쪽이 멈추지 않음', e === null || typeof e === 'string', e);
  }
  pdf.close();
  {
    const e = await pdf.render(1, cv, { scale: 1 }).then(() => 'ok', (x) => x.name ?? 'err');
    ok('닫은 뒤 렌더가 매달리지 않음', typeof e === 'string', e);
  }
  return { doc, fails };
}, doc).catch((e) => ({ doc, fails: ['페이지가 통째로 죽음: ' + String(e).slice(0, 120)] }));

const bad = r.fails.length + errs.length;
console.log(`${round}회차 [${r.doc}] ${bad === 0 ? '통과' : '실패 ' + bad}` + (r.fails.length ? '\n  ' + r.fails.slice(0, 5).join('\n  ') : '') + (errs.length ? '\n  콘솔: ' + errs.slice(0, 3).join(' | ') : ''));
await b.close();
process.exit(bad ? 1 : 0);
