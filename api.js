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

  function uuid4() {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    var b = window.crypto && window.crypto.getRandomValues
      ? window.crypto.getRandomValues(new Uint8Array(16)) : null;
    var out = '';
    for (var i = 0; i < 16; i++) {
      var n = b ? b[i] : Math.floor(Math.random() * 256);
      if (i === 6) n = (n & 0x0f) | 0x40;
      if (i === 8) n = (n & 0x3f) | 0x80;
      out += ('0' + n.toString(16)).slice(-2);
      if (i === 3 || i === 5 || i === 7 || i === 9) out += '-';
    }
    return out;
  }

  // Shrink a picked photo on the phone so uploads are small and fast.
  function downscale(file, maxPx) {
    return new Promise(function (resolve) {
      if (!file || !file.type || file.type.indexOf('image/') !== 0) { resolve(file); return; }
      var url = URL.createObjectURL(file), img = new Image();
      img.onload = function () {
        var sc = Math.min(1, maxPx / Math.max(img.width, img.height));
        var c = document.createElement('canvas');
        c.width = Math.round(img.width * sc);
        c.height = Math.round(img.height * sc);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        c.toBlob(function (b) { resolve(b || file); }, 'image/jpeg', 0.82);
      };
      img.onerror = function () { URL.revokeObjectURL(url); resolve(file); };
      img.src = url;
    });
  }
  function blobToDataURL(blob) {
    return new Promise(function (resolve) {
      var fr = new FileReader();
      fr.onload = function () { resolve(fr.result); };
      fr.onerror = function () { resolve(null); };
      fr.readAsDataURL(blob);
    });
  }

  var api = {
    demo: demo,

    /*
      Turns a Nigerian number typed any normal way (0803..., 803...,
      +234803..., 234803..., 00234803..., with spaces or dashes) into the
      plain international digits WhatsApp needs (234803...). Handles a
      stray extra 0 typed after +234 by mistake too.
    */
    toIntl: function (p) {
      var d = String(p || '').replace(/\D/g, '');
      if (d.indexOf('00') === 0) d = d.slice(2);
      if (d.indexOf('234') === 0) d = d.slice(3);
      if (d.charAt(0) === '0') d = d.slice(1);
      return d ? '234' + d : '';
    },
    /* True only when the number looks like a real Nigerian mobile once converted. */
    isValidNgPhone: function (p) {
      var d = window.API.toIntl(p);
      return /^234[7-9]\d{9}$/.test(d);
    },
    /* 234803...  ->  +234 803 000 0001, for showing the person what will be used. */
    formatDisplay: function (p) {
      var d = window.API.toIntl(p);
      if (!/^234\d{10}$/.test(d)) return '';
      return '+234 ' + d.slice(3, 6) + ' ' + d.slice(6, 9) + ' ' + d.slice(9);
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
        return Promise.resolve(copy);
      }
      // Anon has no SELECT policy on requests, so INSERT ... RETURNING is
      // rejected by RLS; supply the id ourselves and insert without .select().
      var copy = JSON.parse(JSON.stringify(row));
      copy.id = uuid4();
      return sb.from('requests').insert(copy).then(check).then(function () { return copy; });
    },

    // Returns a list of photo URLs to store on the request. Demo keeps them in
    // this browser as data URLs; live uploads to Supabase Storage under <ref>/.
    uploadPhotos: function (ref, files) {
      if (!files || !files.length) return Promise.resolve([]);
      var maxPx = demo ? 800 : 1280;
      var picks = Array.prototype.slice.call(files, 0, 3);
      return Promise.all(picks.map(function (f, i) {
        return downscale(f, maxPx).then(function (blob) {
          if (demo) return blobToDataURL(blob);
          var path = ref + '/' + i + '-' + Math.random().toString(36).slice(2) + '.jpg';
          return sb.storage.from('request-photos')
            .upload(path, blob, { contentType: 'image/jpeg', upsert: false })
            .then(check)
            .then(function () {
              return sb.storage.from('request-photos').getPublicUrl(path).data.publicUrl;
            });
        });
      })).then(function (urls) {
        return urls.filter(function (u) { return !!u; });
      });
    },

    /* ---------- job offers (any available welder) ---------- */
    makeToken: function () {
      var b = window.crypto && window.crypto.getRandomValues
        ? window.crypto.getRandomValues(new Uint8Array(16)) : null;
      var out = '';
      for (var i = 0; i < 16; i++) {
        var n = b ? b[i] : Math.floor(Math.random() * 256);
        out += ('0' + n.toString(16)).slice(-2);
      }
      return out;
    },    createOffers: function (requestId, workerIds) {
      var rows = workerIds.map(function (wid) {
        return { request_id: requestId, worker_id: wid, token: api.makeToken(), status: 'open' };
      });
      if (demo) {
        var list = load('demo_offers', []);
        rows.forEach(function (r) {
          r.id = 'o' + Date.now() + Math.floor(Math.random() * 1000);
          r.created_at = new Date().toISOString();
          list.unshift(r);
        });
        save('demo_offers', list);
        return Promise.resolve(rows);
      }
      return sb.from('offers').insert(rows).then(check);
    },
    getOffer: function (token) {
      if (demo) {
        var o = (load('demo_offers', []).filter(function (x) { return x.token === token; })[0]) || null;
        if (!o) return Promise.resolve(null);
        var req = load('demo_requests', []).filter(function (r) { return r.id === o.request_id; })[0] || {};
        var wk = load('demo_workers', DEMO_WORKERS).filter(function (w) { return w.id === o.worker_id; })[0] || {};
        return Promise.resolve({
          offer: { id: o.id, status: o.status },
          worker: { name: wk.name },
          request: {
            ref: req.ref, item: req.item, details: req.details, material: req.material,
            finish: req.finish, budget: req.budget, needed_by: req.needed_by,
            location: req.location, notes: req.notes, photos: req.photos || []
          }
        });
      }
      return sb.rpc('get_offer', { p_token: token }).then(unwrap);
    },
    respondOffer: function (token, accept) {
      if (demo) {
        var list = load('demo_offers', []);
        var o = null;
        list.forEach(function (x) { if (x.token === token) o = x; });
        if (!o) return Promise.resolve({ error: 'not found' });
        if (o.status !== 'open') return Promise.resolve({ error: o.status });
        if (accept) {
          var taken = list.some(function (x) { return x.request_id === o.request_id && x.status === 'accepted'; });
          if (taken) {
            o.status = 'declined'; o.responded_at = new Date().toISOString();
            save('demo_offers', list);
            return Promise.resolve({ error: 'taken' });
          }
          o.status = 'accepted'; o.responded_at = new Date().toISOString();
          save('demo_offers', list);
          var reqs = load('demo_requests', []);
          var req = null;
          reqs.forEach(function (r) {
            if (r.id === o.request_id) { r.worker_id = o.worker_id; req = r; }
          });
          save('demo_requests', reqs);
          return Promise.resolve({
            ok: true, status: 'accepted',
            request: { ref: req.ref, item: req.item, customer_name: req.customer_name, customer_phone: req.customer_phone }
          });
        }
        o.status = 'declined'; o.responded_at = new Date().toISOString();
        save('demo_offers', list);
        var rq = load('demo_requests', []).filter(function (r) { return r.id === o.request_id; })[0] || {};
        return Promise.resolve({
          ok: true, status: 'declined',
          request: { ref: rq.ref, item: rq.item, customer_name: rq.customer_name, customer_phone: rq.customer_phone }
        });
      }
      return sb.rpc('respond_offer', { p_token: token, p_accept: accept }).then(unwrap);
    },
    listOffers: function (requestIds) {
      if (demo) {
        return Promise.resolve(load('demo_offers', []).filter(function (o) {
          return requestIds.indexOf(o.request_id) > -1;
        }));
      }
      if (!requestIds.length) return Promise.resolve([]);
      return sb.from('offers').select('*').in('request_id', requestIds).then(unwrap);
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
    resetPassword: function (email) {
      if (demo) return Promise.resolve({ demo: true });
      return sb.auth.resetPasswordForEmail(email, {
        redirectTo: location.origin + location.pathname.replace(/[^/]*$/, 'admin.html')
      }).then(unwrap);
    },
    updatePassword: function (pw) {
      if (demo) return Promise.resolve({});
      return sb.auth.updateUser({ password: pw }).then(unwrap);
    },
    onPasswordRecovery: function (cb) {
      if (demo) return;
      sb.auth.onAuthStateChange(function (ev) { if (ev === 'PASSWORD_RECOVERY') cb(); });
    },
    signInWithPasskey: function () {
      if (demo) return Promise.reject(new Error('demo'));
      return sb.auth.signInWithPasskey().then(unwrap);
    },
    registerPasskey: function () {
      if (demo) return Promise.reject(new Error('demo'));
      return sb.auth.registerPasskey().then(unwrap);
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
