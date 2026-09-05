// 우리가 만든 PDF 가 스스로 앞뒤가 맞는지 본다.
//
// 왜 필요한가. A/B 는 우리가 *읽어 낸 값*을 맞대고, 왕복 시험은 pdf.js 가
// 그리는지만 본다. 둘 다 우리가 *쓴 바이트*는 안 본다. 그래서 겉모습 폼의
// /Subtype 이 "/core.Form" 으로 나가도 아무도 몰랐다 — 뷰어들이 그 자리를
// 안 보고 넘어가기 때문이다(pdf.js·poppler·macOS PDFKit 넷 다 그랬다).
//
// 바이트를 예전 판과 맞대는 방법도 있지만 그건 시험이 아니라 변경 감지기다.
// 의도해서 고쳐도 매번 빨간불이 뜬다. 여기서는 기준 판 없이, 파일 하나만
// 보고 규격에 어긋난 데가 있는지 본다.
const NAME = String.raw`\/[^\s/<>\[\]()]+`;

/** /Type /XObject 는 /Subtype 이 이 셋 중 하나여야 한다 (ISO 32000 8.8) */
const XOBJ_SUBTYPE = new Set(["Image", "Form", "PS"]);

export function checkPdf(buf) {
  const s = Buffer.isBuffer(buf) ? buf.toString("latin1") : Buffer.from(buf).toString("latin1");
  const bad = [];

  if (!s.startsWith("%PDF-")) bad.push("%PDF- 로 시작하지 않는다");
  if (!/%%EOF\s*$/.test(s.slice(-64))) bad.push("%%EOF 로 끝나지 않는다");

  // ① 정의된 객체를 모은다
  const defined = new Set();
  for (const m of s.matchAll(/(?:^|[\s>])(\d+)\s+(\d+)\s+obj\b/g)) defined.add(m[1]);
  if (defined.size === 0) bad.push("객체가 하나도 없다");

  // ② 가리키는 객체가 다 있는가.
  //    객체 스트림(ObjStm) 안에 든 것은 평문에 안 보이므로, 그런 문서는
  //    이 검사를 건너뛴다 — 없는 것을 없다고 잘못 말하지 않기 위해서다.
  const packed = s.includes("/ObjStm");
  if (!packed) {
    const missing = new Set();
    for (const m of s.matchAll(/(?:^|[\s\[<])(\d+)\s+(\d+)\s+R\b/g)) {
      if (!defined.has(m[1])) missing.add(m[1]);
    }
    if (missing.size) bad.push(`없는 객체를 가리킨다: ${[...missing].slice(0, 6).join(",")}`);
  }

  // ③ XObject 의 /Subtype 이 아는 이름인가 — 오늘 새어 나간 그 자리다
  for (const m of s.matchAll(/\/Type\s*\/XObject([\s\S]{0,220}?)(?:stream|endobj|>>)/g)) {
    const sub = new RegExp(String.raw`\/Subtype\s*(${NAME})`).exec(m[1]);
    if (!sub) { bad.push("XObject 에 /Subtype 이 없다"); continue; }
    const v = sub[1].slice(1);
    if (!XOBJ_SUBTYPE.has(v)) bad.push(`XObject 의 /Subtype 이 이상하다: /${v}`);
  }

  // ④ 마지막 xref 가 가리키는 자리에 그 번호의 객체가 실제로 있는가
  const sx = /startxref\s+(\d+)\s+%%EOF\s*$/.exec(s.slice(-256));
  if (!sx) bad.push("startxref 를 못 읽는다");
  else {
    const at = Number(sx[1]);
    if (at >= s.length) bad.push(`startxref 가 파일 밖을 가리킨다 (${at})`);
    else if (s.startsWith("xref", at)) {
      const tail = s.slice(at, at + 200000);
      const secs = [...tail.matchAll(/(\d+)\s+(\d+)\s*\n((?:\d{10} \d{5} [nf]\s\s?\n?)+)/g)];
      for (const sec of secs) {
        let num = Number(sec[1]);
        for (const e of sec[3].matchAll(/(\d{10}) (\d{5}) ([nf])/g)) {
          const off = Number(e[1]);
          if (e[3] === "n" && off > 0) {
            const head = s.slice(off, off + 32);
            const om = /^(\d+)\s+\d+\s+obj/.exec(head);
            if (!om) bad.push(`xref ${num} 이 객체가 아닌 자리를 가리킨다 (${off})`);
            else if (om[1] !== String(num)) bad.push(`xref ${num} 이 ${om[1]} 번을 가리킨다`);
          }
          num++;
        }
      }
    }
  }

  // ⑤ trailer 의 /Root 가 실제 Catalog 인가
  const root = /\/Root\s+(\d+)\s+\d+\s+R/.exec(s);
  if (!root) bad.push("/Root 가 없다");
  else if (!packed && !defined.has(root[1])) bad.push(`/Root ${root[1]} 이 없다`);

  return bad;
}
