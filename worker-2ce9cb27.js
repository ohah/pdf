(() => {
//#region cmaps.ts
let base = "./cmaps";
function setCmapBase(url) {
	base = url.replace(/\/$/, "");
}
let index = null;
const cache = new Map();
function known() {
	index ??= fetch(`${base}/index.json`).then((r) => r.ok ? r.json() : []).then((a) => new Set(a)).catch(() => new Set());
	return index;
}
function grab(name) {
	let p = cache.get(name);
	if (!p) {
		p = fetch(`${base}/${name}.bin`).then((r) => r.ok ? r.arrayBuffer() : null).catch(() => null);
		cache.set(name, p);
	}
	return p;
}
async function loadCmaps(ex) {
	if (!ex.needCount || !ex.cmapAdd || !ex.cmapReset)return [];
	ex.cmapReset();
	const n = ex.needCount();
	if (n === 0)return [];
	const dec = new TextDecoder(),want = [];
	for (let i = 0; i < n; i++) {
		want.push({ i, name: dec.decode(new Uint8Array(ex.memory.buffer, ex.needPtr() + ex.needOff(i), ex.needLen(i))) });
	}
	const have = await known(),use = want.filter((w) => have.has(w.name));
	if (use.length === 0)return [];
	const bodies = await Promise.all(use.map((w) => grab(w.name))),done = [];
	for (let k = 0; k < use.length; k++) {
		const b = bodies[k];
		if (!b || b.byteLength === 0 || b.byteLength > ex.cmapRoom())continue;
		new Uint8Array(ex.memory.buffer, ex.cmapPtr(), b.byteLength).set(new Uint8Array(b));
		if (ex.cmapAdd(use[k].i, b.byteLength))done.push(use[k].name);
	}
	return done;
}
//#endregion
//#region config.ts
const DEFAULTS = { wasm: "./pdf.wasm", cmaps: "./cmaps" };
//#endregion
//#region worker.ts
let ex = null,mod = null;
const dec = new TextDecoder(),wasi = { args_get: () => 0, args_sizes_get: () => 0, proc_exit: () => {
	throw new Error("proc_exit");
} };
let wasmPath = DEFAULTS.wasm;
async function engine() {
	if (ex)return ex;
	const r = await fetch(wasmPath);
	mod = await WebAssembly.compile(await r.arrayBuffer());
	const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi });
	ex = inst.exports;
	return ex;
}
async function decodeImage(kind,iw,ih,raw,alpha) {
	if (kind === 0 || iw === 0 || ih === 0)return undefined;
	try {
		if (kind === 3) {
			const bmp = await createImageBitmap(new Blob([raw], { type: "image/jpeg" }), { resizeWidth: Math.min(iw, 1600), resizeQuality: "medium" });
			if (!alpha)return bmp;
			const cv = new OffscreenCanvas(bmp.width, bmp.height),c = cv.getContext("2d");
			if (!c)return bmp;
			c.drawImage(bmp, 0, 0);
			const id = c.getImageData(0, 0, cv.width, cv.height);
			for (let y = 0; y < cv.height; y++) {
				const sy = Math.min(alpha.h - 1, Math.floor(y * alpha.h / cv.height));
				for (let x = 0; x < cv.width; x++) {
					const sx = Math.min(alpha.w - 1, Math.floor(x * alpha.w / cv.width));
					id.data[(y * cv.width + x) * 4 + 3] = alpha.bytes[sy * alpha.w + sx] ?? 255;
				}
			}
			c.putImageData(id, 0, 0);
			return await createImageBitmap(cv);
		}
		const rgba = new Uint8ClampedArray(iw * ih * 4),comps = kind === 1 ? 3 : 1;
		for (let k = 0,s2 = 0,d2 = 0; k < iw * ih; k++,s2 += comps,d2 += 4) {
			if (comps === 3) {
				rgba[d2] = raw[s2];
				rgba[d2 + 1] = raw[s2 + 1];
				rgba[d2 + 2] = raw[s2 + 2];
			} else {
				rgba[d2] = rgba[d2 + 1] = rgba[d2 + 2] = raw[s2];
			}
			rgba[d2 + 3] = alpha ? alpha.bytes[Math.min(alpha.h - 1, Math.floor(Math.floor(k / iw) * alpha.h / ih)) * alpha.w + Math.min(alpha.w - 1, Math.floor(k % iw * alpha.w / iw))] ?? 255 : 255;
		}
		return await createImageBitmap(new ImageData(rgba, iw, ih), { resizeWidth: Math.min(iw, 1600), resizeQuality: "medium" });
	} catch {
		return undefined;
	}
}
function putMask(e,m) {
	if (!e.fieldMaskPtr || !e.fieldMaskRoom)return false;
	if (m.bits.length > e.fieldMaskRoom())return false;
	new Uint8Array(e.memory.buffer, e.fieldMaskPtr(), m.bits.length).set(m.bits);
	return true;
}
function chars(e,s,put) {
	for (const ch of s)put(ch.codePointAt(0) ?? 0);
}
async function open(bytes,pw) {
	const e = await engine();
	if (bytes.byteLength > e.maxInput())return { err: "큼", max: e.maxInput() };
	if (!e.reserve(bytes.byteLength, bytes.byteLength + 1048576))return { err: "메모리" };
	new Uint8Array(e.memory.buffer, e.inputPtr(), bytes.byteLength).set(bytes);
	e.clearPassword?.();
	chars(e, pw, (c) => e.addPasswordChar?.(c));
	const ok = e.parse(bytes.byteLength);
	if (e.needPassword?.())return { needPw: true };
	if (!ok)return { err: "트리" };
	await loadCmaps(e);
	const marks = [];
	for (let i = 0; i < (e.outlineCount?.() ?? 0); i++) {
		marks.push({ depth: e.outlineDepth(i), title: dec.decode(new Uint8Array(e.memory.buffer, e.outlineTextPtr() + e.outlineOff(i), e.outlineLen(i))), page: e.outlinePage(i) });
	}
	const info = [];
	for (let i = 0; i < (e.infoCount?.() ?? 0); i++) {
		info.push(dec.decode(new Uint8Array(e.memory.buffer, e.infoTextPtr() + e.infoOff(i), e.infoLen(i))));
	}
	const sigs = [];
	for (let i = 0; i < (e.sigCount?.() ?? 0); i++) {
		const T = (o, l) => l > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.sigTextPtr() + o, l)) : "";
		sigs.push({ name: T(e.sigNameOff(i), e.sigNameLen(i)), date: T(e.sigDateOff(i), e.sigDateLen(i)), reason: T(e.sigReasonOff(i), e.sigReasonLen(i)), sub: T(e.sigSubOff(i), e.sigSubLen(i)), der: new Uint8Array(e.memory.buffer, e.sigTextPtr() + e.sigDerOff(i), e.sigDerLen(i)).slice(), range: [0, 1, 2, 3].map((k) => e.sigRange(i, k)), covers: e.sigCovers(i) === 1 });
	}
	const atts = [];
	for (let i = 0; i < (e.attCount?.() ?? 0); i++) {
		atts.push({ name: dec.decode(new Uint8Array(e.memory.buffer, e.attTextPtr() + e.attNameOff(i), e.attNameLen(i))) || `붙임 ${i + 1}` });
	}
	const layers = [];
	for (let i = 0; i < (e.ocCount?.() ?? 0); i++) {
		layers.push({ name: dec.decode(new Uint8Array(e.memory.buffer, e.ocTextPtr() + e.ocNameOff(i), e.ocNameLen(i))) || `레이어 ${i + 1}`, on: e.ocIsOn(i) === 1 });
	}
	return { pages: e.pageCount(), locked: (e.isEncrypted?.() ?? 0) === 1, outline: marks, info, sigs, layers, atts, xfa: (e.isXfa?.() ?? 0) === 1 };
}
async function page(i,formOn,light=false) {
	const e = await engine();
	e.setFormLayer?.(formOn ? 1 : 0);
	const cnt = e.renderPage(i),buf = new Uint8Array(e.memory.buffer, e.textPtr(), 262144),items = [];
	for (let k = 0; k < cnt; k++) {
		const len = e.itemLen(k);
		if (!len)continue;
		const t = dec.decode(buf.subarray(e.itemOff(k), e.itemOff(k) + len)).replace(/\s+$/, "");
		if (!t)continue;
		items.push({ x: e.itemX(k), y: e.itemY(k), size: e.itemSize(k), text: t });
	}
	const rawAt = (si) => new Uint8Array(e.memory.buffer, e.imageAreaPtr() + e.slotOff(si), e.slotLen(si)).slice(),slots = light ? 0 : e.imageSlots?.() ?? 0,bitmaps = [],stencils = [];
	for (let si = 0; si < slots; si++) {
		const k = e.slotKind(si),iw = e.slotWidth(si),ih = e.slotHeight(si);
		if (k === 5) {
			const cv = new OffscreenCanvas(Math.max(8, Math.min(iw, 400)), Math.max(8, Math.min(ih, 400))),c2 = cv.getContext("2d");
			if (c2) {
				c2.fillStyle = "#e5e7eb";
				c2.fillRect(0, 0, cv.width, cv.height);
				c2.strokeStyle = "#9ca3af";
				c2.strokeRect(0.5, 0.5, cv.width - 1, cv.height - 1);
				c2.fillStyle = "#6b7280";
				c2.font = `${Math.max(9, cv.width / 16)}px system-ui, sans-serif`;
				c2.textAlign = "center";
				c2.fillText("지원하지 않는 그림 형식", cv.width / 2, cv.height / 2);
			}
			stencils.push(undefined);
			bitmaps.push(await createImageBitmap(cv).catch(() => undefined));
			continue;
		}
		if (k === 4) {
			stencils.push({ w: iw, h: ih, flip: (e.slotFlip?.(si) ?? 0) === 1, bytes: rawAt(si), key: `s${i}-${si}:` });
			bitmaps.push(undefined);
			continue;
		}
		stencils.push(undefined);
		const ms = e.slotSMask?.(si) ?? 0,alpha = ms > 0 ? { w: e.slotWidth(ms - 1), h: e.slotHeight(ms - 1), bytes: rawAt(ms - 1) } : undefined;
		bitmaps.push(await decodeImage(k, iw, ih, rawAt(si), alpha));
	}
	let bitmap = bitmaps[0];
	if (!light && slots === 0 && e.imageKind() !== 0) {
		const raw = new Uint8Array(e.memory.buffer, e.imagePtr(), e.imageLen()).slice();
		bitmap = await decodeImage(e.imageKind(), e.imageWidth(), e.imageHeight(), raw);
		if (bitmap)bitmaps.push(bitmap);
	}
	const fonts = [],area = e.fontAreaPtr();
	for (let fi = 0; !light && fi < e.fontCount(); fi++) {
		const flen = e.fontFileLen(fi);
		fonts.push({ bytes: flen ? new Uint8Array(e.memory.buffer, area + e.fontFileOff(fi), flen).slice() : null, pua: e.fontIsPua(fi) === 1, name: e.fontNamePtr && e.fontNameLen ? dec.decode(new Uint8Array(e.memory.buffer, e.fontNamePtr(fi), e.fontNameLen(fi))) : String(fi), kind: e.fontKind?.(fi) ?? 0, len: flen });
	}
	const ops = light ? new Float32Array(0) : new Float32Array(e.memory.buffer, e.opsPtr(), e.opsLen()).slice(),txt = new Uint8Array(e.memory.buffer, e.textPtr(), e.textLen()).slice(),drw = new Uint8Array(e.memory.buffer, e.drawPtr(), e.drawLen()).slice(),rtx = e.readPtr && e.readLen ? new Uint8Array(e.memory.buffer, e.readPtr(), e.readLen()).slice() : drw,links = [];
	for (let li = 0; li < (e.linkCount?.() ?? 0); li++) {
		const ulen = e.linkLen(li);
		links.push({ x0: e.linkRect(li, 0), y0: e.linkRect(li, 1), x1: e.linkRect(li, 2), y1: e.linkRect(li, 3), uri: ulen > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.linkTextPtr() + e.linkOff(li), ulen)) : "", page: e.linkPage(li) });
	}
	let inlMax = 0;
	for (let k = 0; k + 1 < ops.length; ) {
		const argc = ops[k + 1];
		if (ops[k] === 22)inlMax = Math.max(inlMax, ops[k + 2 + 4] + ops[k + 2 + 5]);
		k += 2 + argc;
	}
	const inline = inlMax > 0 && e.inlinePtr ? new Uint8Array(e.memory.buffer, e.inlinePtr(), inlMax).slice() : new Uint8Array(0),S = (o, l) => l > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.fieldTextPtr() + o, l)) : "",fields = [];
	for (let k = 0; k < (e.fieldCount?.() ?? 0); k++) {
		fields.push({ obj: e.fieldObj(k), kind: e.fieldKind(k), flags: e.fieldFlags(k), maxLen: e.fieldMaxLen(k), size: e.fieldSize(k), align: e.fieldAlign(k), rect: [0, 1, 2, 3].map((q) => e.fieldRect(k, q)), name: S(e.fieldNameOff(k), e.fieldNameLen(k)), value: S(e.fieldValOff(k), e.fieldValLen(k)), on: S(e.fieldOnOff(k), e.fieldOnLen(k)), opts: S(e.fieldOptsOff(k), e.fieldOptsLen(k)), checked: e.fieldChecked(k) === 1 });
	}
	return { w: e.pageWidth(), h: e.pageHeight(), x0: e.pageOriginX?.() ?? 0, y0: e.pageOriginY?.() ?? 0, rot: e.pageRotate?.() ?? 0, items, ops, txt, drw, rtx, links, inline, fields, fonts, bitmaps, stencils, bitmap, images: e.imageCount(), forms: e.formCount?.() ?? 0, light };
}
async function build(spec) {
	const e = await engine();
	e.clearPick();
	for (const i of spec.pick)e.addPick(i);
	e.setRotate(spec.rotate);
	e.clearPageRotate?.();
	for (const [pg, deg] of spec.pageRot)e.setPageRotate?.(pg, deg);
	e.clearWatermark();
	chars(e, spec.watermark, (c) => e.addWatermarkChar(c));
	if (spec.wmMask && e.setWatermarkMask && putMask(e, spec.wmMask)) {
		const m = spec.wmMask;
		e.setWatermarkMask(m.w, m.h, m.bits.length, m.pw, m.ph);
	}
	e.clearFieldEdits?.();
	e.clearNewFields?.();
	let touched = 0;
	for (const f of spec.fields) {
		if (!e.addFieldEdit?.(f.obj, f.kind))continue;
		chars(e, f.text, (c) => e.addFieldEditChar?.(c));
		if (f.mask && e.setFieldEditMask && putMask(e, f.mask)) {
			e.setFieldEditMask(f.mask.w, f.mask.h, f.mask.bits.length);
		}
		touched++;
	}
	for (const f of spec.newFields) {
		if (!e.addNewField?.(f.page, f.kind, f.rect[0], f.rect[1], f.rect[2], f.rect[3]))continue;
		chars(e, f.name, (c) => e.addNewFieldChar?.(c));
		touched++;
	}
	e.clearNotes?.();
	for (const n of spec.notes) {
		if (!e.addNote?.(n.kind, n.page, n.rect[0], n.rect[1], n.rect[2], n.rect[3], n.rgb[0], n.rgb[1], n.rgb[2]))continue;
		if (n.kind === 6)for (const q of n.pts)e.addNotePoint?.(q[0], q[1]); else chars(e, n.text, (c) => e.addNoteChar?.(c));
	}
	e.clearLabels?.();
	for (const L of spec.labels) {
		if (!e.addLabel?.(L.page, L.x, L.y, L.size, L.rgb[0], L.rgb[1], L.rgb[2]))continue;
		chars(e, L.text, (c) => e.addLabelChar?.(c));
		if (L.mask && e.setLabelMask && putMask(e, L.mask)) {
			e.setLabelMask(L.mask.w, L.mask.h, L.mask.bits.length, L.mask.pw, L.mask.ph);
		}
	}
	const plain = spec.rotate === 0 && !spec.watermark && spec.labels.length === 0 && touched === 0 && spec.pageRot.length === 0 && spec.notes.length === 0,n = spec.shrink && plain ? e.compact() : e.apply();
	if (!n)return null;
	let out = new Uint8Array(e.memory.buffer, e.outputPtr(), n).slice();
	if (spec.encryptPw !== undefined) {
		const sealed = await seal(out, spec.encryptPw);
		if (!sealed)return null;
		out = sealed;
	}
	return out;
}
async function seal(bytes,pw) {
	await engine();
	if (!mod)return null;
	const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi }),e = inst.exports;
	if (!e.setEncrypt || !e.encRandomPtr)return null;
	if (!e.reserve(bytes.length, bytes.length * 4 + 33554432))return null;
	new Uint8Array(e.memory.buffer, e.inputPtr(), bytes.length).set(bytes);
	e.clearPassword?.();
	if (!e.parse(bytes.length))return null;
	e.clearPick();
	for (let i = 0; i < e.pageCount(); i++)e.addPick(i);
	e.setRotate(0);
	e.clearWatermark();
	e.clearLabels?.();
	e.clearFieldEdits?.();
	e.clearNewFields?.();
	e.clearPageRotate?.();
	e.clearNotes?.();
	e.setEncrypt(1);
	chars(e, pw, (c) => e.addEncryptChar?.(c));
	const rnd = new Uint8Array(64);
	crypto.getRandomValues(rnd);
	new Uint8Array(e.memory.buffer, e.encRandomPtr(), 64).set(rnd);
	const n = e.compact();
	return n ? new Uint8Array(e.memory.buffer, e.outputPtr(), n).slice() : null;
}
async function merge(bytes) {
	const e = await engine();
	if (bytes.byteLength > e.maxSecond())return null;
	new Uint8Array(e.memory.buffer, e.secondPtr(), bytes.byteLength).set(bytes);
	if (!e.parseSecond(bytes.byteLength))return null;
	const n = e.merge();
	if (!n)return null;
	return { bytes: new Uint8Array(e.memory.buffer, e.outputPtr(), n).slice(), added: e.secondPageCount() };
}
let queue = Promise.resolve();
self.onmessage = (ev) => {
	queue = queue.then(() => handle(ev)).catch(() => {
	});
};
async function handle(ev) {
	const { id:id, t:t, a:a } = ev.data;
	try {
		let r = null;
		const move = [];
		if (t === "paths") {
			if (a.wasm)wasmPath = a.wasm;
			if (a.cmaps)setCmapBase(a.cmaps);
			r = true;
		} else if (t === "open")r = await open(a.bytes, a.pw); else if (t === "attach") {
			const e = await engine(),n = e.attLoad?.(a.i) ?? 0,q = n ? new Uint8Array(e.memory.buffer, e.attPtr(), n).slice() : null;
			if (q)move.push(q.buffer);
			r = q;
		} else if (t === "layers") {
			const e = await engine();
			a.on.forEach((v, i) => e.setOcOn?.(i, v ? 1 : 0));
			r = true;
		} else if (t === "page") {
			const q = await page(a.i, a.formOn, a.light === true);
			for (const b of [q.ops.buffer, q.txt.buffer, q.drw.buffer, q.rtx.buffer, q.inline.buffer]) {
				move.push(b);
			}
			for (const b of q.bitmaps)if (b)move.push(b);
			for (const s of q.stencils)if (s)move.push(s.bytes.buffer);
			for (const f of q.fonts)if (f.bytes)move.push(f.bytes.buffer);
			r = q;
		} else if (t === "build") {
			const q = await build(a.spec);
			if (q)move.push(q.buffer);
			r = q;
		} else if (t === "merge") {
			const q = await merge(a.bytes);
			if (q)move.push(q.bytes.buffer);
			r = q;
		} else if (t === "seal") {
			const q = await seal(a.bytes, a.pw);
			if (q)move.push(q.buffer);
			r = q;
		}
		self.postMessage({ id, r }, move);
	} catch (e) {
		self.postMessage({ id, err: String(e?.message ?? e) });
	}
}
//#endregion
})();
//# sourceMappingURL=/tmp/zsm3/index.js.map
