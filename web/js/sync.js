// Loom (web): sync across devices. There is no account. One device makes a sync code and the
// others enter it. From the code the browser derives an id (what the server knows the library by)
// and an encryption key (which never leaves the device), so the site stores only text it can't read.
// The scheme is the same as Gridline's (bollineni.co/sync/api), so one store serves both apps.
//
// What syncs: every item (notes, links, summaries, tags), space, Ask conversation and setting, as
// one document; and each item's file (images, videos, PDFs, other files) in encrypted chunks of
// under 3 MB, since one request to the site can carry at most 4.5 MB.
//
// Merging: every entry carries the time it last changed, and the later change wins. A deleted
// entry leaves a marker behind for 90 days, so the deletion wins too instead of the entry coming
// back from another device. The server keeps a version with each save and refuses a save made from
// an older one, handing back what it has, so a device merges and tries again instead of
// overwriting another device's change.
'use strict';

const Sync = (() => {
  const BASE = '/sync/api/';
  const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford base32: no I, L, O or U
  const CODE_LENGTH = 25; // 125 random bits
  const DAY = 86400000;
  const MARKER_DAYS = 90;
  const REFRESH_DAYS = 180; // the site drops a file 400 days after it was last written
  const MAX_PAYLOAD = 4_100_000; // the server allows 4,200,000 characters
  const CHUNK = 2_750_000; // bytes of file per request (about 3.7 MB once encrypted and encoded)
  const MAX_FILE = 100 * 1048576;
  const POLL = 60_000;
  const SECTIONS = ['items', 'spaces', 'chats'];

  // ---- The code and the crypto -------------------------------------------------------------

  const newCode = () => Array.from(crypto.getRandomValues(new Uint8Array(CODE_LENGTH)), (b) => ALPHABET[b & 31]).join('');
  // Accepts the code however it was typed: any case, with or without dashes and spaces, and with
  // the letters people mistake for digits.
  function normalizeCode(text) {
    const c = String(text || '').toUpperCase().replace(/[^0-9A-Z]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');
    return c.length === CODE_LENGTH && [...c].every((ch) => ALPHABET.includes(ch)) ? c : null;
  }
  const formatCode = (code) => String(code || '').replace(/(.{5})(?=.)/g, '$1-');

  const utf8 = (s) => new TextEncoder().encode(s);
  const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
  function toBase64(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }
  const fromBase64 = (text) => Uint8Array.from(atob(text), (ch) => ch.charCodeAt(0));

  // The id and the key come from the code by separate derivations, so knowing the id (as the
  // server does) says nothing about the key. Same parameters as Gridline.
  async function derive(code) {
    const material = await crypto.subtle.importKey('raw', utf8(code), 'HKDF', false, ['deriveBits', 'deriveKey']);
    const params = (info) => ({ name: 'HKDF', hash: 'SHA-256', salt: utf8('bollineni-sync'), info: utf8(info) });
    const id = hex(await crypto.subtle.deriveBits(params('id/v1'), material, 256));
    const key = await crypto.subtle.deriveKey(params('key/v1'), material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    return { id, key };
  }
  async function seal(key, bytes, aad) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const opts = aad ? { name: 'AES-GCM', iv, additionalData: utf8(aad) } : { name: 'AES-GCM', iv };
    const sealed = new Uint8Array(await crypto.subtle.encrypt(opts, key, bytes));
    const out = new Uint8Array(12 + sealed.length);
    out.set(iv); out.set(sealed, 12);
    return toBase64(out);
  }
  async function unseal(key, text, aad) {
    const bytes = fromBase64(text);
    const opts = aad ? { name: 'AES-GCM', iv: bytes.subarray(0, 12), additionalData: utf8(aad) } : { name: 'AES-GCM', iv: bytes.subarray(0, 12) };
    return new Uint8Array(await crypto.subtle.decrypt(opts, key, bytes.subarray(12)));
  }

  // The document is gzipped before it's sealed (a library is mostly text), when the browser can.
  // The first byte says which: 1 gzip, 0 plain.
  async function pipe(bytes, stream) { return new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(stream)).arrayBuffer()); }
  async function pack(doc) {
    const json = utf8(JSON.stringify(doc));
    const zipped = typeof CompressionStream === 'function' ? await pipe(json, new CompressionStream('gzip')).catch(() => null) : null;
    const body = zipped || json;
    const out = new Uint8Array(body.length + 1);
    out[0] = zipped ? 1 : 0; out.set(body, 1);
    return out;
  }
  async function unpack(bytes) {
    const body = bytes.subarray(1);
    const json = bytes[0] === 1 ? await pipe(body, new DecompressionStream('gzip')) : body;
    return JSON.parse(new TextDecoder().decode(json));
  }

  // ---- What arrives from another device ----------------------------------------------------
  // It was written by whoever holds the code, which isn't always the person at this device
  // (someone can be talked into entering a stranger's code), so nothing synced is trusted to be
  // the shape Loom saves. Ids and thumbnails go into the page unescaped, so they're checked
  // strictly; every other string is escaped where it's shown, and only its type and length matter.

  const ID_OK = (v) => typeof v === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(v);
  const T_OK = (v) => Number.isFinite(v) && v >= 0;
  const str = (v, max) => (typeof v === 'string' ? v.slice(0, max) : '');
  const strs = (v, n, max) => (Array.isArray(v) ? v.filter((x) => typeof x === 'string').slice(0, n).map((x) => x.slice(0, max)) : []);
  const web = (v) => { const s = str(v, 4000); return /^https?:\/\//i.test(s) ? s : ''; };
  const AI = new Set(['pending', 'done', 'failed', 'skipped', 'off']);

  function cleanItem(d, id) {
    if (!d || typeof d !== 'object' || d.id !== id || !ID_OK(id) || !Object.hasOwn(KINDS, d.kind)) return null;
    const thumb = str(d.thumb, 400_000);
    const out = {
      id, kind: d.kind,
      title: str(d.title, 1000), body: str(d.body, 200_000), url: web(d.url), text: str(d.text, 60_000),
      summary: str(d.summary, 4000), takeaways: strs(d.takeaways, 12, 600), tags: strs(d.tags, 30, 80), userTags: strs(d.userTags, 30, 80),
      createdAt: T_OK(d.createdAt) ? d.createdAt : Date.now(), updatedAt: T_OK(d.updatedAt) ? d.updatedAt : 0,
      fav: d.fav === true, space: ID_OK(d.space) ? d.space : '',
      ai: d.ai === 'processing' ? 'pending' : AI.has(d.ai) ? d.ai : 'pending', aiError: str(d.aiError, 500),
      thumb: /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$/.test(thumb) ? thumb : '',
    };
    if (d.titleEdited === true) out.titleEdited = true;
    if (d.fileName) out.fileName = str(d.fileName, 300);
    if (d.fileType) out.fileType = /^[\w.+-]+\/[\w.+-]+$/.test(d.fileType) ? d.fileType.slice(0, 100) : '';
    if (Number.isFinite(d.fileSize)) out.fileSize = Math.max(0, d.fileSize);
    for (const k of ['pageTitle', 'description', 'linkError']) if (d[k]) out[k] = str(d[k], 2000);
    if (d.image) out.image = web(d.image);
    return out;
  }
  function cleanSpace(d, id) {
    if (!d || d.id !== id || !ID_OK(id)) return null;
    return { id, emoji: str(d.emoji, 8) || '📁', name: str(d.name, 40) || 'Space', createdAt: T_OK(d.createdAt) ? d.createdAt : 0, updatedAt: T_OK(d.updatedAt) ? d.updatedAt : 0 };
  }
  function cleanChat(d, id) {
    if (!d || d.id !== id || !ID_OK(id) || !Array.isArray(d.messages)) return null;
    const messages = d.messages.slice(-200).filter((m) => m && typeof m.text === 'string').map((m) => {
      const out = { user: m.user === true, text: m.text.slice(0, 40_000), at: T_OK(m.at) ? m.at : 0 };
      if (Array.isArray(m.sources)) out.sources = m.sources.filter(ID_OK).slice(0, 12);
      if (m.cited === true) out.cited = true;
      if (m.error === true) out.error = true;
      return out;
    });
    return { id, title: str(d.title, 200), messages, updatedAt: T_OK(d.updatedAt) ? d.updatedAt : 0 };
  }
  const CLEAN = { items: cleanItem, spaces: cleanSpace, chats: cleanChat };
  function cleanSettings(d) {
    const out = {};
    if (d && typeof d.auto === 'boolean') out.auto = d.auto;
    if (d && ['', 'light', 'dark'].includes(d.theme)) out.theme = d.theme;
    return out;
  }
  const cleanFile = (f) => (f && Number.isInteger(f.n) && f.n > 0 && f.n <= 40 && Number.isFinite(f.size) && f.size >= 0 && T_OK(f.at)
    ? { n: f.n, size: f.size, type: /^[\w.+-]+\/[\w.+-]+$/.test(f.type || '') ? f.type : '', at: f.at } : null);

  // ---- The document ------------------------------------------------------------------------

  const emptyDoc = () => ({ v: 1, items: {}, spaces: {}, chats: {}, settings: { t: 0, d: {} }, files: {} });

  // This device's library as a document. `tombs` are this device's deletion markers.
  function local(tombs, files) {
    const doc = emptyDoc();
    const st = Lib.state;
    for (const i of st.items) {
      const { reading, ...d } = i;
      if (d.ai === 'processing') d.ai = 'pending';
      doc.items[i.id] = { t: i.updatedAt || i.createdAt || 0, d };
    }
    for (const s of st.spaces) doc.spaces[s.id] = { t: s.updatedAt || s.createdAt || 0, d: s };
    for (const c of st.chats) if (c.messages.length) doc.chats[c.id] = { t: c.updatedAt || 0, d: c };
    const { updatedAt, ...settings } = st.settings;
    doc.settings = { t: updatedAt || 0, d: { auto: !!settings.auto, theme: settings.theme || '' } };
    for (const [key, t] of Object.entries(tombs)) {
      const [sec, id] = key.split(':');
      if (doc[sec] && (!doc[sec][id] || doc[sec][id].t < t)) doc[sec][id] = { t, x: 1 };
    }
    doc.files = { ...files };
    return doc;
  }

  // For each entry the later change wins; on a tie the synced copy does. Returns the merged
  // document and the files whose item is gone (to remove from the site).
  function merge(mine, theirs, now) {
    const out = emptyDoc();
    const later = (a, b) => (!b ? a : !a ? b : a.t > b.t ? a : b);
    for (const sec of SECTIONS) {
      const a = mine[sec] || {}, b = (theirs && theirs[sec]) || {};
      for (const id of new Set([...Object.keys(a), ...Object.keys(b)])) {
        const e = later(a[id], b[id]);
        if (!e || !T_OK(e.t) || (e.x && now - e.t > MARKER_DAYS * DAY)) continue;
        out[sec][id] = e;
      }
    }
    out.settings = later(mine.settings, theirs && theirs.settings) || out.settings;
    const dead = [];
    const fa = mine.files || {}, fb = (theirs && theirs.files) || {};
    for (const id of new Set([...Object.keys(fa), ...Object.keys(fb)])) {
      const f = [fa[id], fb[id]].map(cleanFile).filter(Boolean).sort((x, y) => y.at - x.at)[0];
      if (!f) continue;
      if (!out.items[id] || out.items[id].x) dead.push(id);
      else out.files[id] = f;
    }
    return { doc: out, dead };
  }

  function canonical(v) {
    if (Array.isArray(v)) return v.map(canonical);
    if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical(v[k])]));
    return v;
  }
  const same = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

  // ---- The engine --------------------------------------------------------------------------

  const MESSAGES = {
    code: 'That isn’t a sync code. It has 25 letters and digits.',
    empty: 'Nothing is saved under that code. Check it against the one on your other device.',
    erased: 'Sync was erased from another device. Everything is still saved here.',
    unreadable: 'The synced library couldn’t be read with this code.',
    rate_limited: 'Too many requests. Sync will try again shortly.',
    offline: 'Couldn’t reach sync. It will try again.',
    too_large: 'Your library is too big to sync as one piece. Long link texts were left out; try removing a few large notes.',
  };
  const failure = (reason, message) => Object.assign(new Error(message || MESSAGES[reason] || MESSAGES.offline), { reason });

  // meta: { code, version, syncedAt, tombs: { 'items:<id>': t }, files: { <id>: { n, size, type, at } } }
  let meta = null, keys = null, remote = null; // remote: the synced document at meta.version
  let available = false, phase = 'idle', problem = null, transfer = null;
  let dirty = false, timer = null, poller = null, applying = false;
  let queue = Promise.resolve();
  const listeners = new Set();
  const tell = () => listeners.forEach((fn) => fn());
  const serial = (job) => { const run = queue.then(job, job); queue = run.catch(() => {}); return run; };
  const persist = () => DB.put('kv', meta, 'sync').catch(() => {});

  async function request(method, path, body) {
    if (!keys) keys = await derive(meta.code);
    let r;
    try {
      r = await fetch(BASE + path, {
        method, cache: 'no-store',
        headers: { Authorization: 'Bearer ' + keys.id, ...(body ? { 'Content-Type': 'application/json' } : {}) },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch { throw failure('offline'); }
    const data = await r.json().catch(() => null);
    if (r.ok || r.status === 404 || r.status === 409) return { status: r.status, data: data || {} };
    throw failure((data && data.reason) || 'offline');
  }
  async function readDoc(payload) {
    try { return await unpack(await unseal(keys.key, payload)); } catch { throw failure('unreadable'); }
  }
  async function writeDoc(doc) {
    let payload = await seal(keys.key, await pack(doc));
    if (payload.length <= MAX_PAYLOAD) return payload;
    // Too big: send a slimmer copy. Thumbnails come back from the files, and a link's page text
    // was only there to be summarized; the summary itself stays.
    const slim = JSON.parse(JSON.stringify(doc));
    for (const e of Object.values(slim.items)) if (e.d) { e.d.thumb = ''; if (e.d.kind === 'link') e.d.text = ''; }
    payload = await seal(keys.key, await pack(slim));
    if (payload.length <= MAX_PAYLOAD) return payload;
    throw failure('too_large');
  }

  // Brings this device's library in line with the merged document.
  async function apply(doc) {
    const st = Lib.state;
    const change = { items: [], removedItems: [], spaces: [], removedSpaces: [], chats: [], removedChats: [], settings: null };
    const have = { items: Lib.byId, spaces: new Map(st.spaces.map((s) => [s.id, s])), chats: new Map(st.chats.map((c) => [c.id, c])) };
    for (const sec of SECTIONS) {
      const removed = 'removed' + sec[0].toUpperCase() + sec.slice(1);
      for (const [id, e] of Object.entries(doc[sec])) {
        const mine = have[sec].get(id);
        if (e.x) { if (mine) change[removed].push(id); continue; }
        const t = sec === 'chats' || sec === 'items' ? mine?.updatedAt : mine && (mine.updatedAt || mine.createdAt);
        if (mine && (t || 0) >= e.t) continue;
        const clean = CLEAN[sec](e.d, id);
        if (!clean) continue;
        if (sec === 'items') { clean.updatedAt = e.t; if (!clean.thumb && mine?.thumb) clean.thumb = mine.thumb; }
        else clean.updatedAt = e.t;
        change[sec].push(clean);
      }
    }
    if (doc.settings && doc.settings.t > (st.settings.updatedAt || 0)) change.settings = { ...cleanSettings(doc.settings.d), updatedAt: doc.settings.t };
    const any = Object.values(change).some((v) => (Array.isArray(v) ? v.length : v));
    if (!any) return;
    applying = true;
    try { await Lib.applyRemote(change); } finally { applying = false; }
  }

  function tombsOf(doc) {
    const t = {};
    for (const sec of SECTIONS) for (const [id, e] of Object.entries(doc[sec])) if (e.x) t[`${sec}:${id}`] = e.t;
    return t;
  }

  // One round: fetch what changed elsewhere, fold it in, send what changed here.
  async function round() {
    const now = Date.now();
    const r = await request('GET', 'loom' + (remote && meta.version ? '?since=' + encodeURIComponent(meta.version) : ''));
    let theirs, version;
    if (r.status === 404) {
      // This device has synced before, so the library was erased from another one.
      if (meta.version) { await stop(); throw failure('erased'); }
      theirs = null; version = null;
    } else if (r.data.unchanged) {
      if (!dirty) { meta.syncedAt = now; return; }
      theirs = remote; version = r.data.version;
    } else {
      theirs = await readDoc(r.data.payload); version = r.data.version;
    }
    for (let attempt = 0; attempt < 4; attempt++) {
      dirty = false;
      const { doc, dead } = merge(local(meta.tombs, meta.files), theirs, now);
      await apply(doc);
      meta.tombs = tombsOf(doc);
      meta.files = doc.files;
      for (const id of dead) deadFiles.add(id);
      if (theirs && same(doc, theirs)) { remote = theirs; meta.version = version; break; }
      const put = await request('PUT', 'loom', { payload: await writeDoc(doc), base: version });
      if (put.status === 200) { remote = doc; meta.version = put.data.version; break; }
      if (put.status !== 409 || !put.data.current) throw failure('offline');
      theirs = await readDoc(put.data.current.payload); version = put.data.current.version;
      if (attempt === 3) throw failure('offline');
    }
    meta.syncedAt = now;
  }

  // ---- Files -------------------------------------------------------------------------------

  const deadFiles = new Set();
  const failedFiles = new Map(); // id -> time of the last failure, so one bad file doesn't spin
  const hasFile = (i) => !!i.fileName && ['image', 'video', 'pdf', 'file'].includes(i.kind);

  async function upload(item, blob) {
    const n = Math.max(1, Math.ceil(blob.size / CHUNK));
    for (let c = 0; c < n; c++) {
      transfer = { dir: 'up', name: displayTitle(item), part: c + 1, of: n }; tell();
      const bytes = new Uint8Array(await blob.slice(c * CHUNK, (c + 1) * CHUNK).arrayBuffer());
      const data = await seal(keys.key, bytes, `${item.id}:${c}:${n}`);
      const r = await request('PUT', `loom-files?f=${item.id}&c=${c}`, { data });
      if (r.status !== 200) throw failure(r.data.reason || 'offline');
    }
    meta.files[item.id] = { n, size: blob.size, type: blob.type || item.fileType || '', at: Date.now() };
  }

  async function download(item, f) {
    const parts = [];
    for (let c = 0; c < f.n; c++) {
      transfer = { dir: 'down', name: displayTitle(item), part: c + 1, of: f.n }; tell();
      const r = await request('GET', `loom-files?f=${item.id}&c=${c}`);
      if (r.status !== 200 || typeof r.data.data !== 'string') throw failure('offline');
      try { parts.push(await unseal(keys.key, r.data.data, `${item.id}:${c}:${f.n}`)); } catch { throw failure('unreadable'); }
    }
    const blob = new Blob(parts, { type: f.type || item.fileType || '' });
    if (blob.size !== f.size) throw failure('unreadable');
    return blob;
  }

  // Sends this device's files that the others don't have yet, and fetches theirs. One at a time,
  // so a big video doesn't hold up the library itself, which has already synced by now.
  async function files() {
    let changed = false;
    for (const id of [...deadFiles]) {
      try { await request('DELETE', `loom-files?f=${id}`); deadFiles.delete(id); } catch { break; }
    }
    const stale = Date.now() - REFRESH_DAYS * DAY;
    for (const item of [...Lib.state.items]) {
      if (!meta || !hasFile(item) || !Lib.byId.has(item.id)) continue;
      if (failedFiles.has(item.id) && Date.now() - failedFiles.get(item.id) < 10 * 60_000) continue;
      const f = meta.files[item.id];
      const blob = await DB.get('blobs', item.id);
      try {
        if (blob && (!f || f.at < stale || f.size !== blob.size)) {
          if (blob.size > MAX_FILE) continue; // stays on this device; the item itself still syncs
          await upload(item, blob);
          changed = true;
        } else if (!blob && f) {
          const got = await download(item, f);
          if (!Lib.byId.has(item.id)) continue;
          await DB.put('blobs', got, item.id);
          await Lib.fileArrived(item, got);
        }
        failedFiles.delete(item.id);
      } catch (e) {
        failedFiles.set(item.id, Date.now());
        if (e.reason === 'rate_limited' || e.reason === 'offline') { transfer = null; throw e; }
      }
    }
    transfer = null;
    if (changed) { dirty = true; await round(); }
  }

  // ---- Running it --------------------------------------------------------------------------

  function run() {
    return serial(async () => {
      if (!meta) return;
      phase = 'syncing'; tell();
      try {
        await round();
        await persist();
        await files();
        await persist();
        phase = 'idle'; problem = null;
      } catch (e) {
        if (meta) await persist();
        problem = e && e.reason ? e : failure('offline');
        phase = problem.reason === 'erased' ? 'idle' : 'error';
        if (problem.reason === 'erased') toast(problem.message);
      }
      transfer = null;
      tell();
    });
  }

  async function stop() {
    clearTimeout(timer);
    meta = null; keys = null; remote = null; dirty = false; deadFiles.clear();
    await DB.del('kv', 'sync').catch(() => {});
  }

  function schedule(delay = 2000) {
    if (!meta) return;
    clearTimeout(timer);
    timer = setTimeout(() => run(), delay);
  }

  async function init() {
    try {
      const r = await fetch(BASE + 'status', { cache: 'no-store' });
      const d = r.ok ? await r.json() : null;
      available = !!(d && d.sync && Array.isArray(d.apps) && d.apps.includes('loom'));
    } catch { available = false; }
    meta = await DB.get('kv', 'sync').catch(() => null);
    if (meta && !normalizeCode(meta.code)) meta = null;
    if (meta) { meta.tombs = meta.tombs || {}; meta.files = meta.files || {}; available = true; }
    tell();

    // Changes here: note deletions, then sync a moment later (several quick edits go together).
    Lib.on((what, detail) => {
      if (!meta || applying) return;
      if (what === 'removed') { meta.tombs[`${detail.store}:${detail.id}`] = Date.now(); persist(); }
      if (['items', 'spaces', 'settings', 'chats', 'removed', 'dirty'].includes(what)) { dirty = true; schedule(); }
    });
    // Changes elsewhere: look when the page comes back into view, comes back online, and every
    // minute while it's showing.
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') schedule(200); });
    addEventListener('online', () => schedule(200));
    clearInterval(poller);
    poller = setInterval(() => { if (document.visibilityState === 'visible') schedule(0); }, POLL);
    if (meta) schedule(0);
  }

  return {
    init,
    on: (fn) => listeners.add(fn),
    get available() { return available; },
    status: () => ({ on: !!meta, code: meta ? formatCode(meta.code) : null, phase, problem, syncedAt: meta?.syncedAt || null, transfer }),
    // Starts sync with a new code; this device's library becomes the synced one.
    create() {
      return serial(async () => {
        if (meta) return;
        meta = { code: newCode(), version: null, syncedAt: null, tombs: {}, files: {} };
        keys = null; remote = null; dirty = true;
        try { keys = await derive(meta.code); await round(); await persist(); }
        catch (e) { await stop(); throw e; }
      }).then(() => { tell(); run(); });
    },
    // Joins the devices already syncing under a code. What's here is added to what's there.
    join(typed) {
      const code = normalizeCode(typed);
      if (!code) return Promise.reject(failure('code'));
      return serial(async () => {
        if (meta) throw failure('code', 'Turn sync off before entering a different code.');
        meta = { code, version: null, syncedAt: null, tombs: {}, files: {} };
        keys = null; remote = null; dirty = true;
        try {
          keys = await derive(code);
          const r = await request('GET', 'loom');
          if (r.status === 404) throw failure('empty');
          await readDoc(r.data.payload); // a wrong code fails here, before anything is merged
          await round();
          await persist();
        } catch (e) { await stop(); throw e; }
      }).then(() => { tell(); run(); });
    },
    // Stops syncing here. The library stays on this device and on the others.
    leave() { return serial(stop).then(tell); },
    // Removes the synced library and its files from the site. Every device keeps its own copy and
    // stops syncing the next time it checks.
    erase() {
      return serial(async () => {
        if (!meta) return;
        const r = await request('DELETE', 'loom');
        if (r.status !== 200 && r.status !== 404) throw failure('offline');
        await stop();
      }).then(tell);
    },
    now: () => run(),
    // For tests.
    _: { merge, local, cleanItem, normalizeCode, formatCode, emptyDoc, same },
  };
})();
