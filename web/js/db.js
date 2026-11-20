// Loom (web): IndexedDB storage. Everything stays in this browser.
'use strict';

const DB = (() => {
  const STORES = ['items', 'blobs', 'spaces', 'chats', 'kv'];
  let dbp;
  function open() {
    if (dbp) return dbp;
    dbp = new Promise((res, rej) => {
      const r = indexedDB.open('loom', 1);
      r.onupgradeneeded = () => {
        const db = r.result;
        for (const s of STORES) if (!db.objectStoreNames.contains(s)) db.createObjectStore(s, s === 'kv' || s === 'blobs' ? undefined : { keyPath: 'id' });
      };
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
      r.onblocked = () => rej(new Error('Loom is open in another tab that needs to be closed first.'));
    });
    return dbp;
  }
  async function tx(store, mode, fn) {
    const db = await open();
    return new Promise((res, rej) => {
      const t = db.transaction(store, mode);
      const s = t.objectStore(store);
      let out;
      const r = fn(s);
      if (r) r.onsuccess = () => { out = r.result; };
      t.oncomplete = () => res(out);
      t.onerror = () => rej(t.error);
      t.onabort = () => rej(t.error || new Error('Storage is full.'));
    });
  }
  // Files. Safari won't store a Blob in IndexedDB when it keeps nothing on disk (Private Browsing,
  // and in-app browsers such as Gmail's or Instagram's), and the save fails with no error at all.
  // Its bytes store fine, so a file that won't go in as a Blob goes in as { bytes, type, name } and
  // comes back out as a Blob. Without this, uploads there fail and synced files never arrive.
  async function putBlob(blob, key) {
    try { return await tx('blobs', 'readwrite', (s) => s.put(blob, key)); }
    catch (e) {
      if (!(blob instanceof Blob)) throw e;
      const bytes = await blob.arrayBuffer();
      return tx('blobs', 'readwrite', (s) => s.put({ bytes, type: blob.type || '', name: blob.name || '' }, key));
    }
  }
  const asBlob = (v) => (v && !(v instanceof Blob) && v.bytes instanceof ArrayBuffer
    ? (v.name ? new File([v.bytes], v.name, { type: v.type }) : new Blob([v.bytes], { type: v.type })) : v);
  const api = {
    all: (store) => tx(store, 'readonly', (s) => s.getAll()),
    get: async (store, key) => { const v = await tx(store, 'readonly', (s) => s.get(key)); return store === 'blobs' ? asBlob(v) : v; },
    put: (store, value, key) => (store === 'blobs' ? putBlob(value, key) : tx(store, 'readwrite', (s) => (key === undefined ? s.put(value) : s.put(value, key)))),
    del: (store, key) => tx(store, 'readwrite', (s) => s.delete(key)),
    clear: async () => { for (const s of STORES) await tx(s, 'readwrite', (st) => st.clear()); },
    estimate: async () => (navigator.storage?.estimate ? navigator.storage.estimate() : null),
    persist: () => navigator.storage?.persist?.().catch(() => false),
  };
  // A saved file: from this browser, or fetched from sync when another device saved it.
  api.file = async (id) => (await api.get('blobs', id)) || (typeof LoomSync !== 'undefined' && LoomSync ? LoomSync.fileFor(id).catch(() => null) : null);
  return api;
})();
