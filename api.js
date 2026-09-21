/*
  Data layer shared by index.html and admin.html.
  Live mode: uses Supabase (database + login).
  Demo mode: keeps everything in this browser only, so you can try the site
  before setting up Supabase.
*/
(function () {
  'use strict';
  var cfg = window.SITE_CONFIG || {};
  var demo = !cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf('YOUR-PROJECT') !== -1 || !window.supabase;
  var sb = demo ? null : window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);

  var mem = {};
  function save(key, val) {
    mem[key] = val;
    try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) { /* storage blocked */ }
  }
  function load(key, fallback) {
    try {
      var v = localStorage.getItem(key);
      if (v) return JSON.parse(v);
    } catch (e) { /* storage blocked */ }
    return mem[key] !== undefined ? mem[key] : fallback;
  }

  var DEMO_WORKERS = [
    { id: 'w1', name: 'Emeka', phone: '2348030000001', specialty: 'Lead welder, cages and frames', available: true },
    { id: 'w2', name: 'Tunde', phone: '2348030000002', specialty: 'Gates and doors', available: true },
    { id: 'w3', name: 'Ibrahim', phone: '2348030000003', specialty: 'Window guards and railings', available: false }
  ];

  function unwrap(res) {
    if (res.error) throw res.error;
    return res.data;
  }
  function check(res) {
    if (res.error) throw res.error;
  }

  var api = {
    demo: demo,

    toIntl: function (p) {
      var d = String(p || '').replace(/\D/g, '');
      if (d.indexOf('234') === 0) return d;
      if (d.charAt(0) === '0') return '234' + d.slice(1);
      if (d.length === 10) return '234' + d;
      return d;
    },

    /* ---------- public (customers) ---------- */
    getWorkers: function () {
      if (demo) return Promise.resolve(load('demo_workers', DEMO_WORKERS).slice());
      return sb.from('workers').select('*').order('name').then(unwrap);
    },
    createRequest: function (row) {
      if (demo) {
        var list = load('demo_requests', []);
        var copy = JSON.parse(JSON.stringify(row));
        copy.id = 'd' + Date.now();
        copy.created_at = new Date().toISOString();
        copy.status = 'New';
        list.unshift(copy);
        save('demo_requests', list);
        return Promise.resolve();
      }
      return sb.from('requests').insert(row).then(check);
    },

    /* ---------- admin ---------- */
    signIn: function (email, password) {
      if (demo) {
        try { sessionStorage.setItem('demo_admin', '1'); } catch (e) { mem.demo_admin = 1; }
        return Promise.resolve({});
      }
      return sb.auth.signInWithPassword({ email: email, password: password }).then(unwrap);
    },
    signOut: function () {
      if (demo) {
        try { sessionStorage.removeItem('demo_admin'); } catch (e) { /* ignore */ }
        mem.demo_admin = 0;
        return Promise.resolve();
      }
      return sb.auth.signOut().then(function () {});
    },
    getSession: function () {
      if (demo) {
        var on = false;
        try { on = sessionStorage.getItem('demo_admin') === '1'; } catch (e) { on = !!mem.demo_admin; }
        return Promise.resolve(on ? {} : null);
      }
      return sb.auth.getSession().then(function (r) { return r.data.session; });
    },
    listRequests: function () {
      if (demo) return Promise.resolve(load('demo_requests', []).slice());
      return sb.from('requests').select('*').order('created_at', { ascending: false }).then(unwrap);
    },
    updateRequest: function (id, patch) {
      if (demo) {
        var list = load('demo_requests', []);
        list.forEach(function (r) { if (r.id === id) Object.keys(patch).forEach(function (k) { r[k] = patch[k]; }); });
        save('demo_requests', list);
        return Promise.resolve();
      }
      return sb.from('requests').update(patch).eq('id', id).then(check);
    },
    deleteRequest: function (id) {
      if (demo) {
        save('demo_requests', load('demo_requests', []).filter(function (r) { return r.id !== id; }));
        return Promise.resolve();
      }
      return sb.from('requests').delete().eq('id', id).then(check);
    },
    addWorker: function (w) {
      if (demo) {
        var list = load('demo_workers', DEMO_WORKERS);
        w.id = 'w' + Date.now();
        list.push(w);
        save('demo_workers', list);
        return Promise.resolve();
      }
      return sb.from('workers').insert(w).then(check);
    },
    updateWorker: function (id, patch) {
      if (demo) {
        var list = load('demo_workers', DEMO_WORKERS);
        list.forEach(function (w) { if (w.id === id) Object.keys(patch).forEach(function (k) { w[k] = patch[k]; }); });
        save('demo_workers', list);
        return Promise.resolve();
      }
      return sb.from('workers').update(patch).eq('id', id).then(check);
    },
    deleteWorker: function (id) {
      if (demo) {
        save('demo_workers', load('demo_workers', DEMO_WORKERS).filter(function (w) { return w.id !== id; }));
        return Promise.resolve();
      }
      return sb.from('workers').delete().eq('id', id).then(check);
    }
  };

  window.API = api;
})();
