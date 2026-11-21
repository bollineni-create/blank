// Loom (web): sync across devices, with no account. Turned on once for the whole site (Settings →
// Sync, or the Apps section on bollineni.co), Loom keeps the library, spaces, Ask conversations
// and settings the same on every linked device. Photos, PDFs and other files up to 25 MB follow,
// each encrypted with its own key. Everything is encrypted in this browser before it leaves.
// The rules live in the site's /sync/kit.js; without it (Loom opened on its own) this does nothing.
'use strict';

const LoomSync = (() => {
  const S = window.BollineniSync;
  if (!S || !window.crypto?.subtle) return null;

  const FILE_MAX = 25 * 1048576;
  const FILE_KINDS = new Set(['image', 'video', 'pdf', 'file']);
  const TEXT_MAX = 20000; // the page or file text Claude reads; enough to search and ask
  const THUMB_MAX = 80000; // video posters travel with the item; image thumbnails are made from the file
  const MAX_CHAT_MESSAGES = 80;
  let files = {}; // item id -> { k, b, n, size, type }: this library's synced files
  const fetching = new Set();

  // ---- What syncs --------------------------------------------------------------------------

  function syncedItem(i) {
    const { thumb, ...rest } = i;
    const out = { ...rest, ai: i.ai === 'processing' ? 'pending' : i.ai };
    if (typeof out.text === 'string' && out.text.length > TEXT_MAX) out.text = out.text.slice(0, TEXT_MAX);
    // Only a real poster travels; a video the browser couldn't draw a frame from has thumb '' and
    // sends none (an empty one used to make every other device reject the whole item).
    if (i.kind === 'video' && typeof thumb === 'string' && thumb && thumb.length < THUMB_MAX) out.thumb = thumb;
    return out;
  }
  function read() {
    const items = {}, spaces = {}, chats = {}, fileMap = {};
    for (const i of Lib.state.items) {
      items[i.id] = syncedItem(i);
      if (files[i.id]) fileMap[i.id] = files[i.id];
    }
    for (const s of Lib.state.spaces) spaces[s.id] = { ...s };
    for (const c of Lib.state.chats) if (c.messages?.length) chats[c.id] = { ...c, messages: c.messages.slice(-MAX_CHAT_MESSAGES) };
    const { auto, theme } = Lib.state.settings;
    return { items, spaces, chats, settings: { auto: !!auto, theme: theme || '' }, files: fileMap };
  }

  // Whatever arrives was written by whoever holds the code, so it is checked against the shapes
  // Loom saves. Loom escapes everything it shows, so strings only need to be strings.
  const str = (v, max) => typeof v === 'string' && v.length <= max;
  const ID = (id) => typeof id === 'string' && /^[\w-]{1,64}$/.test(id);
  const SAFE_URL = (u) => u === '' || u == null || (typeof u === 'string' && u.length < 4000 && /^https?:\/\//i.test(u));
  const strings = (a, n, max) => Array.isArray(a) && a.length <= n && a.every((x) => str(x, max));
  function clean(col, v, id) {
    if (!v || typeof v !== 'object' || Array.isArray(v) || !ID(id)) return null;
    if (col === 'items') {
      if (v.id !== id || !Object.hasOwn(KINDS, v.kind) || !Number.isFinite(v.createdAt)) return null;
      if (!SAFE_URL(v.url) || !SAFE_URL(v.image)) return null;
      // A video with no poster may arrive with thumb '' from a device on an older version: take it.
      if (v.thumb != null && v.thumb !== '' && !(str(v.thumb, THUMB_MAX) && v.thumb.startsWith('data:image/jpeg;base64,'))) return null;
      for (const k of ['title', 'body', 'summary', 'space', 'fileName', 'fileType', 'pageTitle', 'description', 'aiError', 'linkError']) if (v[k] != null && !str(v[k], 200000)) return null;
      if (v.text != null && !str(v.text, TEXT_MAX)) return null;
      if (!strings(v.tags || [], 60, 80) || !strings(v.userTags || [], 60, 80) || !strings(v.takeaways || [], 20, 600)) return null;
      return { ...v, tags: v.tags || [], userTags: v.userTags || [], takeaways: v.takeaways || [] };
    }
    if (col === 'spaces') return v.id === id && str(v.name, 40) && str(v.emoji || '', 16) ? v : null;
    if (col === 'chats') {
      if (v.id !== id || !Array.isArray(v.messages) || v.messages.length > MAX_CHAT_MESSAGES) return null;
      const ok = v.messages.every((m) => m && str(m.text, 40000) && (m.sources == null || strings(m.sources, 20, 64)));
      return ok && str(v.title || '', 200) ? v : null;
    }
    if (col === 'settings') return v;
    if (col === 'files') return S.validFile(v) && v.size <= FILE_MAX ? v : null;
    return null;
  }
  // settings are stored as one record per key ({ auto: true }), so check them one by one.
  function cleanSetting(key, value) {
    if (key === 'auto') return typeof value === 'boolean' ? value : undefined;
    if (key === 'theme') return value === '' || value === 'light' || value === 'dark' ? value : undefined;
    return undefined;
  }

  // Makes this browser's library match what sync says, then reloads it.
  async function write(v) {
    const local = new Map(Lib.state.items.map((i) => [i.id, i]));
    for (const [id, item] of Object.entries(v.items)) {
      const mine = local.get(id);
      // An image's thumbnail is made here from its file; keep the one this browser has.
      const out = mine?.thumb && !item.thumb ? { ...item, thumb: mine.thumb } : item;
      await DB.put('items', out);
      local.delete(id);
    }
    for (const id of local.keys()) { await DB.del('items', id); await DB.del('blobs', id); }
    const spaces = new Set(Lib.state.spaces.map((s) => s.id));
    for (const [id, s] of Object.entries(v.spaces)) { await DB.put('spaces', s); spaces.delete(id); }
    for (const id of spaces) await DB.del('spaces', id);
    const chats = new Set(Lib.state.chats.filter((c) => c.messages?.length).map((c) => c.id));
    for (const [id, c] of Object.entries(v.chats)) { await DB.put('chats', c); chats.delete(id); }
    for (const id of chats) await DB.del('chats', id);
    const settings = { ...Lib.state.settings };
    for (const [k, val] of Object.entries(v.settings)) { const ok = cleanSetting(k, val); if (ok !== undefined) settings[k] = ok; }
    await DB.put('kv', settings, 'settings');
    files = { ...v.files };
    await DB.put('kv', files, 'syncFiles');
    await Lib.load();
  }

  const engine = S.createEngine({
    app: 'loom',
    collections: { items: { first: 'keep' }, spaces: { first: 'keep' }, chats: { first: 'keep' }, settings: { first: 'remote' }, files: { first: 'keep' } },
    read: () => {
      const r = read();
      return r;
    },
    write,
    clean: (col, v, id) => (col === 'settings' ? (cleanSetting(id, v) === undefined ? null : v) : clean(col, v, id)),
    maxPayload: 3_950_000,
    delay: 2000,
    onApplied: () => { fetchFiles(); },
    onProblem: (e) => { if (e.reason === 'erased' || e.reason === 'too_large') toast(e.reason === 'too_large' ? 'Your library is too big to sync in full. It’s all still here.' : e.message); },
  });
  S.register(engine, 'Loom');

  // ---- Files ------------------------------------------------------------------------------

  let uploading = false;
  // Sends this browser's files that aren't synced yet, one at a time, after the library itself.
  async function uploadFiles() {
    const st = engine.status();
    if (uploading || !st.on || !engine.doc()?.c?.items || !navigator.onLine) return;
    uploading = true;
    try {
      for (const item of [...Lib.state.items]) {
        if (!engine.status().on) break;
        if (!FILE_KINDS.has(item.kind) || files[item.id] || !item.fileSize || item.fileSize > FILE_MAX) continue;
        const blob = await DB.get('blobs', item.id);
        if (!blob || !Lib.byId.has(item.id)) continue;
        try {
          files[item.id] = await S.putFile('loom', engine.code(), blob);
          await DB.put('kv', files, 'syncFiles');
          engine.changed();
        } catch (e) {
          if (e?.reason === 'rate_limited' || e?.reason === 'offline') break;
          if (e?.reason === 'empty') break; // the library hasn't reached the server yet; next sync tries again
        }
      }
    } finally { uploading = false; }
  }
  // Fetches files that other devices synced and this browser doesn't have, newest first.
  async function fetchFiles() {
    if (!engine.status().on) return;
    const want = Lib.state.items.filter((i) => files[i.id] && !fetching.has(i.id));
    for (const item of want) {
      if (await DB.get('blobs', item.id)) continue;
      fetching.add(item.id);
      try {
        const blob = await S.getFile('loom', engine.code(), files[item.id]);
        if (!Lib.byId.has(item.id)) continue;
        await DB.put('blobs', new File([blob], item.fileName || 'file', { type: item.fileType || blob.type }), item.id);
        if (item.kind === 'image' && !item.thumb) {
          const thumb = await scaleImage(blob, 400, 0.78, true);
          if (thumb) { item.thumb = thumb; await DB.put('items', item); }
        }
        Lib.state && document.dispatchEvent(new CustomEvent('loom:file', { detail: item.id }));
      } catch (e) {
        if (e?.reason === 'offline' || e?.reason === 'rate_limited') break;
      } finally { fetching.delete(item.id); }
    }
    DB.persist();
  }
  // Files whose item was deleted here: their parts are removed from the server, a little later so
  // an Undo can still bring the item back first.
  let pruneTimer;
  function prune() {
    clearTimeout(pruneTimer);
    pruneTimer = setTimeout(async () => {
      if (!engine.status().on) return;
      let changed = false;
      for (const [id, entry] of Object.entries(files)) {
        if (Lib.byId.has(id)) continue;
        delete files[id];
        changed = true;
        S.removeFile('loom', engine.code(), entry);
      }
      if (changed) { await DB.put('kv', files, 'syncFiles'); engine.changed(); }
    }, 10000);
  }
  // A file this browser is asked to show but hasn't fetched yet.
  async function fileFor(id) {
    if (!files[id] || !engine.status().on) return null;
    const blob = await S.getFile('loom', engine.code(), files[id]);
    await DB.put('blobs', blob, id);
    return blob;
  }

  // ---- Start -------------------------------------------------------------------------------

  async function start() {
    files = (await DB.get('kv', 'syncFiles').catch(() => null)) || {};
    Lib.on((what) => {
      if (what === 'items' || what === 'spaces' || what === 'settings' || what === 'chats') engine.changed();
      if (what === 'items') prune();
    });
    engine.onStatus(() => {
      const st = engine.status();
      if (st.on && st.phase === 'idle' && st.syncedAt) { uploadFiles(); fetchFiles(); }
    });
    await engine.start();
  }

  return { engine, start, fileFor, synced: (id) => !!files[id], status: () => engine.status(), open: () => S.openPanel({ app: 'loom', tint: '#A48CF7' }) };
})();
