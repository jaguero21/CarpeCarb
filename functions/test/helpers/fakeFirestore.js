// Minimal in-memory stand-in for the parts of the Firestore Admin API the
// functions use: collection().doc().get()/set(), and runTransaction with
// tx.get/tx.set/tx.update. Transactions run sequentially (no contention).
function createFakeFirestore(initialDocs = {}) {
  const docs = new Map(Object.entries(initialDocs));
  const state = { failTransactions: false, failReads: false };

  function write(path, data, options = {}) {
    const base = options.merge ? docs.get(path) ?? {} : {};
    docs.set(path, { ...base, ...data });
  }

  function ref(path) {
    return {
      path,
      async get() {
        if (state.failReads) throw new Error("fake read failure");
        return {
          exists: docs.has(path),
          data: () => (docs.has(path) ? { ...docs.get(path) } : undefined),
        };
      },
      async set(data, options) {
        write(path, data, options);
      },
    };
  }

  return {
    docs,
    state,
    collection: (name) => ({ doc: (id) => ref(`${name}/${id}`) }),
    async runTransaction(fn) {
      if (state.failTransactions) throw new Error("fake transaction failure");
      return fn({
        get: (r) => r.get(),
        set: (r, data, options) => write(r.path, data, options),
        update: (r, data) => write(r.path, data, { merge: true }),
      });
    },
  };
}

module.exports = { createFakeFirestore };
