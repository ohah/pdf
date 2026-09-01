// XFA 양식 — 쪽 내용이 PDF 가 아니라 XML 로 들어 있는 문서.
import fs from 'node:fs';
const template = `<?xml version="1.0" encoding="UTF-8"?>
<xdp:xdp xmlns:xdp="http://ns.adobe.com/xdp/">
<template xmlns="http://www.xfa.org/schema/xfa-template/3.0/">
  <subform name="form1" layout="position">
    <pageSet>
      <pageArea name="Page1">
        <contentArea x="0mm" y="0mm" w="210mm" h="297mm"/>
        <medium short="210mm" long="297mm"/>
      </pageArea>
    </pageSet>
    <subform x="20mm" y="20mm">
      <draw name="title" x="0mm" y="0mm" w="120mm" h="10mm">
        <value><text>거래 명세서</text></value>
        <font size="16pt" weight="bold"/>
      </draw>
      <field name="company" x="0mm" y="15mm" w="80mm" h="8mm">
        <caption><value><text>상호</text></value></caption>
        <value><text>보기 주식회사</text></value>
        <font size="10pt"/>
        <border><edge/></border>
      </field>
      <field name="amount" x="0mm" y="27mm" w="80mm" h="8mm">
        <caption><value><text>금액</text></value></caption>
        <font size="10pt"/>
        <para hAlign="right"/>
        <border><edge/></border>
      </field>
    </subform>
  </subform>
</template>
<xfa:datasets xmlns:xfa="http://www.xfa.org/schema/xfa-data/1.0/">
  <xfa:data><form1><amount>1,250,000</amount></form1></xfa:data>
</xfa:datasets>
</xdp:xdp>`;

const objs = [];
const push = (o) => objs.push(o);
push('<</Type/Catalog/Pages 2 0 R/AcroForm<</Fields[]/XFA[(template) 5 0 R (datasets) 6 0 R]>>>>');
push('<</Type/Pages/Count 1/Kids[3 0 R]>>');
push('<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Resources<</Font<</F1 7 0 R>>>>/Contents 4 0 R>>');
const c = 'BT /F1 12 Tf 60 700 Td (Please open this document with Acrobat.) Tj ET\n';
push(`<</Length ${c.length}>>stream\n${c}endstream `);
// XFA 조각 둘 — 앞은 template, 뒤는 datasets
const cut = template.indexOf('<xfa:datasets');
const part1 = template.slice(0, cut);
const part2 = template.slice(cut);
push(`<</Length ${Buffer.byteLength(part1, 'utf8')}>>stream\n${part1}\nendstream `);
push(`<</Length ${Buffer.byteLength(part2, 'utf8')}>>stream\n${part2}\nendstream `);
push('<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>');

// XML 은 UTF-8 이라 바이트로 이어 붙인다 — latin1 문자열로 다루면 깨진다
const parts = [Buffer.from('%PDF-1.7\n', 'latin1')];
const off = [];
let at = parts[0].length;
objs.forEach((o, i) => {
  off.push(at);
  const buf = Buffer.from(`${i + 1} 0 obj${o}endobj\n`, 'utf8');
  parts.push(buf);
  at += buf.length;
});
const xs = at;
let tail = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
  + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
tail += `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${xs}\n%%EOF\n`;
parts.push(Buffer.from(tail, 'latin1'));
fs.writeFileSync(new URL('./fixtures/xfa.pdf', import.meta.url), Buffer.concat(parts));
console.log('xfa.pdf 만듦');
