'use strict';
/* YouTube Downloader - phone edition (works in any mobile or desktop browser). */
(function () {
  var UNITS = ['days', 'hours', 'minutes', 'seconds'];
  var UNIT_LABEL = { days: 'Days', hours: 'Hours', minutes: 'Minutes', seconds: 'Seconds' };
  var state = null, tab = 'add', pollTimer = null, settingsReady = false, polling = false;

  function $(s) { return document.querySelector(s); }
  function $$(s) { return Array.prototype.slice.call(document.querySelectorAll(s)); }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  var toastTimer = null;
  function toast(msg) {
    var t = $('#toast');
    t.textContent = msg; t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, 3200);
  }

  // ---------------------------------------------------------------- network
  function api(path, body) {
    var opts = { credentials: 'same-origin', headers: {} };
    if (body !== undefined) {
      opts.method = 'POST';
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        if (r.status === 401 && path !== '/api/login') { showLogin(); throw new Error('login'); }
        if (!r.ok) throw new Error(data.error || ('Error ' + r.status));
        return data;
      });
    });
  }

  function showLogin(message) {
    stopPolling();
    $('#app').hidden = true; $('#tabs').hidden = true;
    $('#login').hidden = false;
    $('#loginErr').textContent = message || '';
    $('#pill').textContent = 'Locked';
    setTimeout(function () { $('#pin').focus(); }, 50);
  }

  function showApp() {
    $('#login').hidden = true; $('#app').hidden = false; $('#tabs').hidden = false;
    startPolling();
  }

  // ---------------------------------------------------------------- polling
  function startPolling() { stopPolling(); refresh(); pollTimer = setInterval(refresh, 1500); }
  function stopPolling() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }
  document.addEventListener('visibilitychange', function () { if (!document.hidden && pollTimer) refresh(); });

  function refresh() {
    if (polling || document.hidden) return;
    polling = true;
    api('/api/state').then(function (s) {
      state = s; render();
      if (tab === 'files') loadFiles();
    }).catch(function (e) {
      if (e.message !== 'login') $('#pill').textContent = 'Cannot reach the server - retrying...';
    }).then(function () { polling = false; });
  }

  // ---------------------------------------------------------------- time text
  function clock(epoch) {
    var d = new Date(epoch * 1000), now = new Date();
    var opt = { hour: 'numeric', minute: '2-digit' };
    if (d.toDateString() !== now.toDateString()) { opt.weekday = 'short'; opt.month = 'short'; opt.day = 'numeric'; }
    return d.toLocaleString([], opt);
  }

  function pillText(s) {
    var cur = s.jobs.filter(function (j) { return j.status === 'downloading'; })[0];
    if (cur) {
      var label = cur.display || cur.url, more = s.waiting ? ' (+' + s.waiting + ' waiting)' : '';
      if (/^Downloading/.test(cur.text)) return 'Downloading ' + label + ' ' + Math.round(cur.percent || 0) + '%' + more;
      return cur.text + ' ' + label + more;
    }
    if (s.paused) return 'Paused' + (s.resume_at ? ' until ' + clock(s.resume_at) : '') + (s.waiting ? ' (' + s.waiting + ' waiting)' : '');
    if (s.waiting && s.limit_next) return 'Limit reached - next download at ' + clock(s.limit_next) + ' (' + s.waiting + ' waiting)';
    if (s.waiting) return 'Starting... (' + s.waiting + ' waiting)';
    return 'Idle';
  }

  // ---------------------------------------------------------------- render
  function render() {
    var s = state;
    $('#pill').textContent = pillText(s);
    $('#outDir').textContent = s.out_dir;
    $('#infoOut').textContent = s.out_dir;
    $('#infoYt').textContent = s.ytdlp || 'not found';
    $('#infoVer').textContent = s.version;
    $('#pauseBtn').textContent = s.paused ? 'Resume' : 'Pause';
    var active = s.jobs.filter(function (j) { return j.status === 'queued' || j.status === 'downloading'; }).length;
    var badge = $('#queueCount');
    badge.hidden = active === 0; badge.textContent = active;
    renderQueue(s.jobs);
    if (!settingsReady) hydrateSettings();
  }

  function renderQueue(jobs) {
    var ul = $('#queue');
    var frag = document.createDocumentFragment();
    jobs.forEach(function (j) {
      var li = el('li', 'job s-' + j.status);
      li.dataset.id = j.id;
      li.appendChild(el('span', 'badge ' + j.kind, j.kind.toUpperCase()));
      var meta = el('div', 'meta');
      meta.appendChild(el('div', 'title', j.display || '(original title)'));
      meta.appendChild(el('div', 'sub', j.url));
      if (j.status === 'downloading') {
        var p = el('div', 'prog'), i = el('i'); i.style.width = Math.max(2, Math.min(100, j.percent || 0)) + '%';
        p.appendChild(i); meta.appendChild(p);
      }
      meta.appendChild(el('div', 'st', j.text));
      li.appendChild(meta);
      var acts = el('div', 'acts');
      if (j.status === 'failed' || j.status === 'cancelled') {
        var r = el('button', 'icon', '↻'); r.dataset.act = 'retry'; r.setAttribute('aria-label', 'Retry'); acts.appendChild(r);
      }
      if (j.status === 'done' && j.file) {
        var a = el('a', 'icon', '⬇'); a.href = '/files/' + j.file.split('/').map(encodeURIComponent).join('/');
        a.setAttribute('download', ''); a.setAttribute('aria-label', 'Save to this device');
        a.style.cssText = 'display:flex;align-items:center;justify-content:center;text-decoration:none;color:inherit';
        acts.appendChild(a);
      }
      var x = el('button', 'icon', '✕'); x.dataset.act = 'remove';
      x.setAttribute('aria-label', j.status === 'downloading' ? 'Cancel' : 'Remove'); acts.appendChild(x);
      li.appendChild(acts);
      frag.appendChild(li);
    });
    ul.replaceChildren ? ul.replaceChildren(frag) : (ul.innerHTML = '', ul.appendChild(frag));
    $('#queueEmpty').hidden = jobs.length > 0;
  }

  // ---------------------------------------------------------------- files tab
  function size(n) {
    if (n > 1048576) return (n / 1048576).toFixed(1) + ' MB';
    return Math.max(1, Math.round(n / 1024)) + ' KB';
  }
  function loadFiles() {
    api('/api/files').then(function (d) {
      var ul = $('#files'), frag = document.createDocumentFragment();
      d.files.forEach(function (f) {
        var li = el('li', 'file');
        var a = el('a'); a.href = '/files/' + f.path.split('/').map(encodeURIComponent).join('/'); a.setAttribute('download', f.name);
        a.appendChild(el('span', 'badge ' + (f.name.toLowerCase().slice(-4) === '.mp4' ? 'mp4' : 'mp3'), f.name.slice(-3).toUpperCase()));
        var meta = el('div', 'meta');
        meta.appendChild(el('div', 'title', f.name));
        meta.appendChild(el('div', 'sub', size(f.size) + ' - ' + new Date(f.mtime * 1000).toLocaleString()));
        a.appendChild(meta); a.appendChild(el('span', 'dl', 'Save'));
        li.appendChild(a); frag.appendChild(li);
      });
      ul.replaceChildren ? ul.replaceChildren(frag) : (ul.innerHTML = '', ul.appendChild(frag));
      $('#filesEmpty').hidden = d.files.length > 0;
    }).catch(function () {});
  }

  // ---------------------------------------------------------------- unit dropdowns
  function fillUnit1(sel) {
    sel.innerHTML = '';
    UNITS.forEach(function (u) { var o = el('option', null, UNIT_LABEL[u]); o.value = u; sel.appendChild(o); });
  }
  // second dropdown: only units SMALLER than the first one; disabled when the first is Seconds
  function link(u1, num2, u2, wantU2) {
    var prev = wantU2 || u2.value;
    var smaller = UNITS.slice(UNITS.indexOf(u1.value) + 1);
    u2.innerHTML = '';
    smaller.forEach(function (u) { var o = el('option', null, UNIT_LABEL[u]); o.value = u; u2.appendChild(o); });
    var none = smaller.length === 0;
    u2.disabled = none; num2.disabled = none;
    if (none) { num2.value = 0; return; }
    u2.value = smaller.indexOf(prev) >= 0 ? prev : smaller[0];
  }
  function pair(a1, u1, a2, u2) { return { a: +$(a1).value || 0, u1: $(u1).value, b: $(a2).disabled ? 0 : (+$(a2).value || 0), u2: $(u2).disabled ? '' : $(u2).value }; }

  function hydrateSettings() {
    var L = state.limit;
    $('#limCount').value = L.count; $('#limA').value = L.a; $('#limU1').value = L.u1;
    link($('#limU1'), $('#limB'), $('#limU2'), L.u2); $('#limB').value = L.b;
    settingsReady = true;
  }

  function localInputValue(d) {
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  // ---------------------------------------------------------------- actions
  function wrap(promise, ok) {
    return promise.then(function (r) { if (ok) toast(ok); refresh(); return r; })
      .catch(function (e) { if (e.message !== 'login') toast(e.message); });
  }

  function setTab(name) {
    tab = name;
    $$('[data-tab]').forEach(function (n) {
      if (n.tagName === 'SECTION') n.hidden = n.dataset.tab !== name;
      else n.classList.toggle('on', n.dataset.tab === name);
    });
    window.scrollTo(0, 0);
    if (name === 'files') loadFiles();
    if (name === 'settings' && state) hydrateSettings();
  }

  function init() {
    fillUnit1($('#limU1')); fillUnit1($('#pU1'));
    $('#limU1').value = 'hours'; $('#pU1').value = 'hours';
    link($('#limU1'), $('#limB'), $('#limU2')); link($('#pU1'), $('#pB'), $('#pU2'));
    $('#limU1').addEventListener('change', function () { link($('#limU1'), $('#limB'), $('#limU2')); });
    $('#pU1').addEventListener('change', function () { link($('#pU1'), $('#pB'), $('#pU2')); });
    $('#pUntil').value = localInputValue(new Date(Date.now() + 3600 * 1000));
    $('#mp4').addEventListener('change', function () { $('#quality').disabled = !$('#mp4').checked; });
    $('#quality').disabled = true;

    $$('#tabs button').forEach(function (b) { b.addEventListener('click', function () { setTab(b.dataset.tab); }); });

    $('#loginForm').addEventListener('submit', function (ev) {
      ev.preventDefault();
      api('/api/login', { pin: $('#pin').value }).then(function () {
        $('#pin').value = ''; settingsReady = false; showApp();
      }).catch(function (e) { $('#loginErr').textContent = e.message; });
    });

    $('#addBtn').addEventListener('click', function () {
      var kinds = [];
      if ($('#mp3').checked) kinds.push('mp3');
      if ($('#mp4').checked) kinds.push('mp4');
      var urls = $('#urls').value.split(/\s+/).filter(Boolean);
      if (!urls.length) { toast('Paste at least one link.'); return; }
      wrap(api('/api/add', { urls: urls, kinds: kinds, name: $('#name').value, quality: $('#quality').value, subfolder: $('#subfolder').value }))
        .then(function (r) {
          if (!r) return;
          $('#urls').value = ''; $('#name').value = '';
          toast('Added ' + r.added.length + ' to the queue' + (r.skipped.length ? ' (' + r.skipped.length + ' skipped)' : ''));
          setTab('queue');
        });
    });

    $('#queue').addEventListener('click', function (ev) {
      var b = ev.target.closest('button[data-act]'); if (!b) return;
      var id = +b.closest('li').dataset.id;
      wrap(api(b.dataset.act === 'retry' ? '/api/retry' : '/api/remove', { ids: [id] }));
    });
    $('#pauseBtn').addEventListener('click', function () { wrap(api('/api/pause', { mode: 'toggle' })); });
    $('#clearBtn').addEventListener('click', function () { wrap(api('/api/clear', {})); });
    $('#filesRefresh').addEventListener('click', loadFiles);

    $('#limSave').addEventListener('click', function () {
      var p = pair('#limA', '#limU1', '#limB', '#limU2');
      wrap(api('/api/limit', { count: +$('#limCount').value || 0, a: p.a, u1: p.u1, b: p.b, u2: p.u2 }), 'Limit saved');
    });
    $('#pauseFor').addEventListener('click', function () {
      var p = pair('#pA', '#pU1', '#pB', '#pU2');
      wrap(api('/api/pause', { mode: 'for', a: p.a, u1: p.u1, b: p.b, u2: p.u2 }), 'Paused');
    });
    $('#pauseUntil').addEventListener('click', function () {
      var t = new Date($('#pUntil').value).getTime();
      if (!t) { toast('Pick a date and time first.'); return; }
      wrap(api('/api/pause', { mode: 'until', until: t / 1000 }), 'Paused');
    });
    $('#updateYt').addEventListener('click', function () {
      var out = $('#updateOut'); out.hidden = false; out.textContent = 'Updating...';
      api('/api/update-ytdlp', {}).then(function (r) { out.textContent = r.output || 'Done.'; refresh(); })
        .catch(function (e) { out.textContent = e.message; });
    });

    // Inside the Android app there is a native "change server" screen.
    if (window.Android && window.Android.changeServer) {
      $('#changeServer').hidden = false; $('#loginChange').hidden = false;
      $('#changeServer').addEventListener('click', function () { window.Android.changeServer(); });
      $('#loginChange').addEventListener('click', function () { window.Android.changeServer(); });
    }

    if ('serviceWorker' in navigator && window.isSecureContext) navigator.serviceWorker.register('/sw.js').catch(function () {});

    api('/api/state').then(function (s) { state = s; showApp(); }).catch(function (e) {
      if (e.message !== 'login') { $('#pill').textContent = 'Cannot reach the server'; showLogin('Cannot reach the server.'); }
    });
  }

  document.addEventListener('DOMContentLoaded', init);
})();
