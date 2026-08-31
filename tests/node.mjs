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

console.log(`Node  통과 ${ok} · 실패 ${bad}`);
process.exit(bad === 0 ? 0 : 1);
