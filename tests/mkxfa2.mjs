// 동적 XFA — 흐름 배치·자료만큼 되풀이·셈하는 칸·여러 쪽.
import fs from 'node:fs';
const rows = Array.from({ length: 30 }, (_, i) => `
      <item><nm>품목 ${i + 1}</nm><qty>${i + 1}</qty><amt>${(i + 1) * 1000}</amt></item>`).join('');
const template = `<?xml version="1.0" encoding="UTF-8"?>
<xdp:xdp xmlns:xdp="http://ns.adobe.com/xdp/">
<template xmlns="http://www.xfa.org/schema/xfa-template/3.0/">
  <subform name="form1" layout="position" w="595pt" h="842pt">
    <pageSet>
      <pageArea name="Page1">
        <contentArea x="0pt" y="20pt" w="595pt" h="700pt"/>
        <medium short="595pt" long="842pt"/>
      </pageArea>
    </pageSet>
    <draw x="40pt" y="24pt" w="300pt" h="20pt">
      <value><text>거래 명세서 (동적)</text></value>
      <font size="14pt" weight="bold"/>
    </draw>
    <subform name="table" x="40pt" y="50pt" w="500pt" layout="tb">
      <subform name="item" layout="lr-tb" w="500pt" h="20pt">
        <occur min="1" max="-1"/>
        <field name="nm" w="200pt" h="20pt"><font size="10pt"/></field>
        <field name="qty" w="80pt" h="20pt"><font size="10pt"/></field>
        <field name="amt" w="120pt" h="20pt"><font size="10pt"/></field>
      </subform>
    </subform>
    <field name="total" x="400pt" y="760pt" w="150pt" h="20pt">
      <caption><value><text>합계</text></value></caption>
      <font size="11pt" weight="bold"/>
      <event activity="calculate">
        <script contentType="application/x-formcalc">Sum(amt[*])</script>
      </event>
    </field>
    <draw name="secret" x="40pt" y="800pt" w="200pt" h="14pt" presence="hidden">
      <value><text>이건 안 보여야 한다</text></value>
    </draw>
  </subform>
</template>
<xfa:datasets xmlns:xfa="http://www.xfa.org/schema/xfa-data/1.0/">
  <xfa:data><form1><table>${rows}</table></form1></xfa:data>
</xfa:datasets>
</xdp:xdp>`;

const objs = [];
objs.push('<</Type/Catalog/Pages 2 0 R/AcroForm<</Fields[]/XFA[(template) 5 0 R (datasets) 6 0 R]>>>>');
objs.push('<</Type/Pages/Count 1/Kids[3 0 R]>>');
objs.push('<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Resources<</Font<</F1 7 0 R>>>>/Contents 4 0 R>>');
const c = 'BT /F1 12 Tf 60 700 Td (Please open with Acrobat.) Tj ET\n';
objs.push(`<</Length ${c.length}>>stream\n${c}endstream `);
const cut = template.indexOf('<xfa:datasets');
const p1 = template.slice(0, cut), p2 = template.slice(cut);
objs.push(`<</Length ${Buffer.byteLength(p1, 'utf8')}>>stream\n${p1}\nendstream `);
objs.push(`<</Length ${Buffer.byteLength(p2, 'utf8')}>>stream\n${p2}\nendstream `);
objs.push('<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>');

const parts = [Buffer.from('%PDF-1.7\n', 'latin1')];
const off = []; let at = parts[0].length;
objs.forEach((o, i) => { off.push(at); const b = Buffer.from(`${i + 1} 0 obj${o}endobj\n`, 'utf8'); parts.push(b); at += b.length; });
let tail = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
  + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
tail += `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${at}\n%%EOF\n`;
parts.push(Buffer.from(tail, 'latin1'));
fs.writeFileSync(new URL('./fixtures/xfa-dyn.pdf', import.meta.url), Buffer.concat(parts));
console.log('xfa-dyn.pdf 만듦 (줄 30개)');
