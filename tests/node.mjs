// Node 에서도 도는지 본다.
//
//   node tests/node.mjs [fixtures]
//
// 브라우저 밖에는 Worker 도 createImageBitmap 도 document 도 없다. 그래도
// 뽑기(글자·주석·구조·양식)와 편집(build)은 되어야 한다 — 서버에서 본문을
// 색인하거나 쪽을 골라 다시 내는 쓰임이 이 갈래다. 그리기는 캔버스가 있어야
// 하므로, 없을 때 무슨 일인지 알아들을 오류가 나는지까지 함께 본다.
//
// dist/ 를 읽으므로 build:js 를 먼저 돌려야 한다.
import { readFile } from "node:fs/promises";
import { PDFDocument, PasswordNeeded } from "../dist/index.js";

const FX = (process.argv[2] ?? "tests/fixtures").replace(/\/$/, "");
let ok = 0;
let bad = 0;
const t = (name, cond, got) => {
  if (cond) ok++;
  else { bad++; console.log(`  실패 ${name}${got === undefined ? "" : ` — ${got}`}`); }
};

// 파일 경로로 연다. 브라우저에서는 주소를 fetch 하지만 여기서는 못 한다.
{
  const pdf = await PDFDocument.open(`${FX}/annots.pdf`);
  t("경로로 열기", pdf.pages === 1, pdf.pages);
  const text = await pdf.text(1);
  t("글자 뽑기", text.includes("annots"), JSON.stringify(text.slice(0, 40)));
  const items = await pdf.textItems(1);
  t("덩이 뽑기", items.length > 0 && typeof items[0].dir === "string", items.length);
  const an = await pdf.annotations(1);
  t("주석 뽑기", an.length === 5, an.length);
  t("권한", Object.keys(pdf.permissions).length === 8);
  // 캔버스가 없으면 무슨 일인지 말해 줘야 한다
  let msg = "";
  await pdf.render(1, null).catch((e) => { msg = e.message; });
  t("캔버스 없을 때 안내", /canvas/i.test(msg), JSON.stringify(msg));
  pdf.close();
}

// 바이트로도 연다
{
  const bytes = new Uint8Array(await readFile(`${FX}/annots.pdf`));
  const pdf = await PDFDocument.open(bytes);
  t("바이트로 열기", pdf.pages === 1, pdf.pages);
  // 빈 spec 으로도 다시 낼 수 있어야 한다 — 안 적은 것은 그대로 둔다
  const out = await pdf.build({});
  t("다시 내기", out !== null && out.length > 0, out?.length);
  const again = await PDFDocument.open(out);
  t("낸 것 다시 열기", again.pages === 1, again.pages);
  t("낸 것의 글자", (await again.text(1)).includes("annots"));
  again.close();
  pdf.close();
}

// 태그 구조
{
  const pdf = await PDFDocument.open(`${FX}/struct.pdf`);
  const root = await pdf.structure();
  t("구조 뿌리", root !== null && root.children.length > 0, root?.children.length);
  pdf.close();
}

// 암호가 걸린 문서
{
  const pdf = await PDFDocument.open(`${FX}/enc-perm.pdf`, { password: "" });
  t("잠긴 문서 열기", pdf.pages === 1, pdf.pages);
  t("잠긴 문서 권한", pdf.permissions.print === false);
  pdf.close();
}

// 없는 파일은 조용히 넘어가면 안 된다
{
  let msg = "";
  await PDFDocument.open(`${FX}/없는파일.pdf`).catch((e) => { msg = e.message; });
  t("없는 파일", msg.length > 0, JSON.stringify(msg));
}

// 닫은 뒤에 부르면 매달리지 않고 바로 오류
{
  const pdf = await PDFDocument.open(`${FX}/annots.pdf`);
  pdf.close();
  let msg = "";
  await pdf.text(1).catch((e) => { msg = e.message; });
  t("닫은 뒤 부르기", /closed/.test(msg), JSON.stringify(msg));
}

// 암호를 걸어 낸 뒤 암호 없이 열면 PasswordNeeded
{
  const pdf = await PDFDocument.open(`${FX}/annots.pdf`);
  const sealed = await pdf.build({ encryptPw: "열쇠" });
  pdf.close();
  t("암호 걸어 내기", sealed !== null && sealed.length > 0, sealed?.length);
  let kind = "";
  await PDFDocument.open(sealed.slice()).catch((e) => { kind = e.constructor.name; });
  t("암호 필요", kind === "PasswordNeeded", kind);
  const back = await PDFDocument.open(sealed.slice(), { password: "열쇠" });
  t("암호 주고 열기", back.pages === 1, back.pages);
  back.close();
  void PasswordNeeded;
}

// 문서 두 개를 한꺼번에 — 워커가 없으면 모듈 하나를 나눠 쓰므로, 문서마다
// 제 엔진 사례를 들지 않으면 뒤엣것이 앞엣것을 덮어쓴다. 실제로 그랬다:
// 5쪽짜리를 열어 둔 채 1쪽짜리를 열면 5쪽짜리의 글자가 1쪽짜리 것으로 나왔다.
{
  const A = await PDFDocument.open(`${FX}/multi.pdf`);
  const B = await PDFDocument.open(`${FX}/annots.pdf`);
  t("둘 다 열림", A.pages === 5 && B.pages === 1, `${A.pages}/${B.pages}`);
  t("앞 문서가 안 덮인다", (await A.text(1)).includes("PAGE 1"), JSON.stringify((await A.text(1)).slice(0, 20)));
  t("뒤 문서도 제 것", (await B.text(1)).includes("annots"));
  // 번갈아 불러도 섞이지 않아야 한다
  const [a2, b1, a3] = await Promise.all([A.text(2), B.text(1), A.text(3)]);
  t("섞어 불러도 제 것", a2.includes("PAGE 2") && b1.includes("annots") && a3.includes("PAGE 3"),
    `${a2.slice(0, 12)} | ${b1.slice(0, 8)} | ${a3.slice(0, 12)}`);
  // 만들어 낸 것도 제 문서여야 한다
  const out = await A.build({});
  const back = await PDFDocument.open(out.slice());
  t("만든 것이 앞 문서", back.pages === 5, back.pages);
  back.close();
  A.close();
  B.close();
}

// 쪽이 너무 많으면 잘랐다고 알린다 (같은 쪽을 백 번 가리키는 문서로 만든다)
{
  const one = [
    "%PDF-1.7", "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
    `2 0 obj\n<< /Type /Pages /Count 100 /Kids [${Array(100).fill("4 0 R").join(" ")}] >>\nendobj`,
    "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj",
    "4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>\nendobj",
    "5 0 obj\n<< /Length 44 >>\nstream\nBT /F1 12 Tf 20 100 Td (many) Tj ET\nendstream\nendobj",
    "trailer\n<< /Size 6 /Root 1 0 R >>", "%%EOF", "",
  ].join("\n");
  const many = await PDFDocument.open(new TextEncoder().encode(one));
  t("쪽이 넘치면 알린다", many.truncated === true && many.pages > 0, `${many.pages}쪽 truncated=${many.truncated}`);
  many.close();
}

// 캔버스를 주면 Node 에서도 그린다 (@napi-rs/canvas 가 있을 때만 본다)
{
  let createCanvas = null;
  try { ({ createCanvas } = await import("@napi-rs/canvas")); } catch { /* 없으면 건너뛴다 */ }
  if (createCanvas) {
    const pdf = await PDFDocument.open(`${FX}/tile.pdf`);
    const cv = createCanvas(10, 10);
    const r = await pdf.render(1, cv, { scale: 1, dpr: 1 });
    const d = cv.getContext("2d").getImageData(0, 0, cv.width, cv.height).data;
    let inked = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 0 && d[i] < 200) inked++;
    // 브라우저에서 같은 문서를 같은 배율로 그리면 25235 칸이 찍힌다.
    // 무늬·도형은 글꼴과 무관하므로 Node 에서도 같아야 한다.
    t("Node 에서 그리기", Math.abs(inked - 25235) < 500, `${cv.width}x${cv.height} 잉크 ${inked}`);
    t("그리며 글자 자리도 준다", Array.isArray(r.runs), typeof r.runs);
    pdf.close();
  }
}

console.log(`Node  통과 ${ok} · 실패 ${bad}`);
process.exit(bad === 0 ? 0 : 1);
