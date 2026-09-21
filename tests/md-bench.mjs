// PDF → Markdown 을 정답(tests/md-gold.json)과 맞대 점수를 낸다. 다른 도구의
// 출력 디렉터리를 같이 주면 같은 잣대로 나란히 잰다.
//
//   node tests/md-bench.mjs <문서디렉터리> [이름=출력디렉터리 …]
//   예) node tests/md-bench.mjs ~/docs pymupdf4llm=~/ref docling=~/dl
//
// 정답은 사람이 적은 것이다 — 도구 출력을 베끼면 도구의 틀린 것까지 정답이
// 된다(pymupdf4llm 은 attention 논문의 절 제목을 하나도 못 잡고, bitcoin 의
// 수식을 제목으로 찍는다).
import fs from 'node:fs';
import path from 'node:path';
import { PDFDocument } from '../dist/index.js';

const dir = process.argv[2];
if (!dir) { console.error('문서 디렉터리를 달라'); process.exit(2); }
const others = process.argv.slice(3).filter((a) => a.includes('=')).map((a) => { const [n, d] = a.split('='); return { name: n, dir: d }; });
const gold = JSON.parse(fs.readFileSync(new URL('./md-gold.json', import.meta.url), 'utf8'));

const norm = (s) => s.replace(/\s+/g, ' ').trim();
function check(md, g) {
  const res = [];
  const lines = md.split('\n');
  const heads = lines.filter((l) => /^#{1,6} /.test(l)).map((l) => norm(l.replace(/^#+ /, '').replace(/\*\*/g, '')));
  const flat = norm(md.replace(/[*_`#|]/g, ''));
  const tables = lines.filter((l) => l.startsWith('|')).map((l) => l.split('|').map((c) => norm(c.replace(/\*\*/g, ''))));
  const fences = []; let inF = false, cur = [];
  for (const l of lines) { if (l.startsWith('```')) { if (inF) fences.push(cur.join('\n')); cur = []; inF = !inF; continue; } if (inF) cur.push(l); }
  for (const h of g.heading ?? []) res.push(['heading', h, heads.some((x) => x === norm(h) || x.startsWith(norm(h)))]);
  for (const h of g.notheading ?? []) res.push(['notheading', h, !heads.some((x) => x === norm(h) || x.startsWith(norm(h)))]);
  for (const t of g.text ?? []) res.push(['text', t, flat.includes(norm(t))]);
  for (const t of g.notext ?? []) res.push(['notext', t, !flat.includes(norm(t))]);
  for (const cells of g.table ?? []) res.push(['table', cells.join(' | '), tables.some((row) => cells.every((c) => row.some((x) => x.includes(c))))]);
  for (const c of g.code ?? []) res.push(['code', c, fences.some((f) => f.includes(c))]);
  for (const [a, b] of g.order ?? []) { const i = flat.indexOf(norm(a)), j = flat.indexOf(norm(b)); res.push(['order', `${a} < ${b}`, i >= 0 && j > i]); }
  return res;
}

const tools = [{ name: 'ours', md: async (f) => { const d = await PDFDocument.open(fs.readFileSync(f)); const t0 = performance.now(); const md = await d.markdown(); const ms = performance.now() - t0; d.close(); return { md, ms }; } },
  ...others.map((o) => ({ name: o.name, md: async (f) => { const p = path.join(o.dir, path.basename(f, '.pdf') + '.md'); return fs.existsSync(p) ? { md: fs.readFileSync(p, 'utf8'), ms: 0 } : null; } }))];

const total = Object.fromEntries(tools.map((t) => [t.name, [0, 0]]));
const pad = (s, n) => String(s).padEnd(n);
console.log(pad('문서', 16) + tools.map((t) => pad(t.name, 16)).join(''));
for (const [doc, g] of Object.entries(gold)) {
  if (doc === '_') continue;
  const f = path.join(dir, doc);
  if (!fs.existsSync(f)) { console.log(pad(doc, 16) + '(없음)'); continue; }
  const row = [pad(doc, 16)];
  const fails = {};
  for (const t of tools) {
    const got = await t.md(f);
    if (!got) { row.push(pad('-', 16)); continue; }
    const res = check(got.md, g);
    const ok = res.filter((r) => r[2]).length;
    total[t.name][0] += ok; total[t.name][1] += res.length;
    row.push(pad(`${ok}/${res.length}${got.ms ? ` ${Math.round(got.ms)}ms` : ''}`, 16));
    fails[t.name] = res.filter((r) => !r[2]);
  }
  console.log(row.join(''));
  if (process.argv.includes('-v')) for (const [n, fs2] of Object.entries(fails)) for (const [k, what] of fs2) console.log(`    ${n} ✗ ${k}: ${what}`);
}
console.log(pad('합계', 16) + tools.map((t) => pad(`${total[t.name][0]}/${total[t.name][1]}`, 16)).join(''));
