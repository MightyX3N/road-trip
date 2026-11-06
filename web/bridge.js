// Road Trip in a browser: the translation layer. Road Trip's Lua code (run by love.js) asks for
// things the same way it asks LauncherBridge.java on Android; this file answers with what a
// browser can do: real web requests, GPS, internet radio and Jellyfin audio, the voice, the
// MapLibre map under the canvas, video, and the keyboard. What only Android can do (other apps'
// notifications, Keep in front, being the home app) answers "not here", and the app hides it.
//
// How a call travels: Lua prints "\x01RT{json}" (love.js hands stdout to Module.print at once);
// we answer by writing {ok, data} to __rt_reply in Road Trip's save folder before print returns.
"use strict";
(function () {
  const SAVE = "/home/web_user/love/roadtrip";
  const enc = new TextEncoder();
  let M = null; // the love.js Module
  const RT = (window.RT = { handlers: {} });
  const H = RT.handlers;

  // ------------------------------------------------------------------------------------------
  // files in love.js's file system

  function mkdirs(dir) {
    const parts = dir.split("/").filter(Boolean);
    let cur = "";
    for (const p of parts) {
      const parent = cur || "/";
      cur += "/" + p;
      try { M.FS_createPath(parent, p, true, true); } catch (e) { /* there already */ }
    }
  }
  function writeFile(path, data) {
    const i = path.lastIndexOf("/");
    const dir = path.slice(0, i), name = path.slice(i + 1);
    mkdirs(dir);
    try { M.FS_unlink(path); } catch (e) { /* not there yet */ }
    M.FS_createDataFile(dir, name, typeof data === "string" ? enc.encode(data) : data, true, true, true);
  }
  function reply(data, error) {
    writeFile(SAVE + "/__rt_reply", JSON.stringify(error ? { ok: false, error: String(error) } : { ok: true, data: data === undefined ? null : data }));
  }

  RT.attach = function (module) {
    M = module;
    const print = module.print || console.log.bind(console);
    module.print = function (text) {
      if (typeof text === "string" && text.charCodeAt(0) === 1 && text.startsWith("\x01RT")) {
        let req;
        try { req = JSON.parse(text.slice(3)); } catch (e) { reply(null, "bad request"); return; }
        const h = H[req.m];
        if (!h) { reply(null); return; }
        try { reply(h(req.a || {})); } catch (e) { console.warn("[bridge]", req.m, e); reply(null, e && e.message); }
        return;
      }
      print(text);
    };
  };

  // ------------------------------------------------------------------------------------------
  // the device

  const lang = (navigator.language || "en").toLowerCase();
  H.language = () => lang.split("-")[0];
  H.country = () => {
    const loc = (Intl.DateTimeFormat().resolvedOptions().locale || navigator.language || "");
    const m = loc.match(/-([A-Z]{2})\b/i);
    if (m) return m[1].toUpperCase();
    const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
    return tz.startsWith("Europe/Copenhagen") ? "DK" : "US";
  };
  H.uptime = () => Math.floor(performance.now());
  H.resumed = () => document.visibilityState === "visible";
  H.homePresses = () => 0;
  H.isDefaultHome = () => true;
  H.web = () => ({ standalone: matchMedia("(display-mode: standalone)").matches || navigator.standalone === true,
    ios: /iPhone|iPad|iPod/.test(navigator.userAgent) });
  H.viewport = () => { const c = document.getElementById("canvas");
    return { w: Math.round(c.clientWidth), h: Math.round(c.clientHeight), dpr: window.devicePixelRatio || 1 }; };
  H.openURL = (a) => { window.open(a.url, "_blank", "noopener"); return true; };
  H.logSlow = (a) => { console.info("[slow]", a.text); return true; };
  H.diagnostics = () => ({ defaultHome: "web browser", watched: [], guard: [], nav: [], slow: [] });
  H.updateStatus = () => ({ state: "none", current: 0, currentName: "web", latest: 0, latestName: "", notes: "", progress: 0 });
  H.guardStatus = () => ({ serviceOn: false, enabled: false, stock: [], web: true });
  H.overlayStatus = () => ({ canDraw: false, guard: false, moving: moving(), why: "web", front: "", covering: false });
  let overlay = { video: true, noSpeed: "block" };
  H.overlayConfig = (a) => { overlay = a; return true; };
  H.overlayNav = () => true;
  H.mediaStatus = () => ({ access: true, current: null });
  H.navStatus = () => ({ active: false });
  H.calendar = () => ({ permission: false, events: [] });
  let quota = { free: -1 };
  if (navigator.storage && navigator.storage.estimate) navigator.storage.estimate().then(e => { quota.free = (e.quota || 0) - (e.usage || 0); });
  H.storage = () => ({ free: quota.free, size: 0 });
  H.deleteTree = () => true;
  H.mapDownload = () => false;
  H.mapDownloadStatus = () => ({ state: "idle", done: 0, total: 0, failed: 0, bytes: 0 });

  // web apps for the Apps screen and favorites: they open in a new tab
  const APPS = [
    ["YouTube", "https://m.youtube.com", "#FF0033"], ["YouTube Music", "https://music.youtube.com", "#FF0033"],
    ["Spotify", "https://open.spotify.com", "#1DB954"], ["Google Maps", "https://maps.google.com", "#34A853"],
    ["Waze", "https://www.waze.com/live-map", "#33CCFF"], ["Netflix", "https://www.netflix.com", "#E50914"],
    ["Podimo", "https://podimo.com", "#7B4DFF"], ["DR TV", "https://www.dr.dk/drtv", "#E8E5DD"],
    ["Wikipedia", "https://m.wikipedia.org", "#BBBBBB"], ["Weather", "https://www.yr.no", "#00B9F1"],
  ];
  function iconPNG(label, color) {
    const c = document.createElement("canvas");
    c.width = c.height = 256; // a power of two: WebGL 1 is picky
    const g = c.getContext("2d");
    g.scale(256 / 192, 256 / 192);
    g.fillStyle = color; g.beginPath(); g.arc(96, 96, 96, 0, Math.PI * 2); g.fill();
    const light = parseInt(color.slice(1, 3), 16) * 0.3 + parseInt(color.slice(3, 5), 16) * 0.59 + parseInt(color.slice(5, 7), 16) * 0.11 > 170;
    g.fillStyle = light ? "#111" : "#fff";
    g.font = "bold 96px Manrope, system-ui, sans-serif"; g.textAlign = "center"; g.textBaseline = "middle";
    g.fillText(label[0], 96, 104);
    const b64 = c.toDataURL("image/png").split(",")[1];
    return Uint8Array.from(atob(b64), ch => ch.charCodeAt(0));
  }
  H.getApps = (a) => {
    if (a.known === 1) return { version: 1 };
    const apps = APPS.map(([label, url, color], i) => {
      const name = "web" + i + ".png";
      if (a.iconDir) writeFile(a.iconDir + "/" + name, iconPNG(label, color));
      return { pkg: url, activity: "web", label, icon: name };
    });
    return { version: 1, apps };
  };
  H.launch = (a) => { window.open(a.pkg, "_blank", "noopener"); return true; };
  H.openAppInfo = () => false;

  // ------------------------------------------------------------------------------------------
  // the network: fetch, POST, downloads (all polled with fetchResult)

  let nextId = 1;
  const results = {};
  function startFetch(url, opts, toPath) {
    const id = nextId++;
    results[id] = { done: false };
    fetch(url, opts || {}).then(async r => {
      if (toPath) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        writeFile(toPath, new Uint8Array(await r.arrayBuffer()));
        results[id] = { done: true, ok: true, status: r.status };
      } else {
        const body = await r.text();
        results[id] = { done: true, ok: r.ok, status: r.status, body, error: r.ok ? undefined : "HTTP " + r.status };
      }
    }).catch(e => {
      results[id] = { done: true, ok: false, error: (e && e.message) || "network error" };
    });
    return id;
  }
  H.fetch = (a) => startFetch(a.url);
  H.download = (a) => startFetch(a.url, null, a.path);
  H.httpRequest = (a) => {
    const headers = {};
    // a browser sends its own User-Agent; asking for another only adds a CORS preflight
    for (const [k, v] of Object.entries(a.headers || {})) if (!/^user-agent$/i.test(k)) headers[k] = v;
    return startFetch(a.url, { method: a.method || "GET", headers, body: a.body || undefined });
  };
  H.fetchResult = (a) => {
    const r = results[a.id];
    if (!r) return { done: true, ok: false, error: "unknown request" };
    if (r.done) delete results[a.id];
    return r;
  };

  // ------------------------------------------------------------------------------------------
  // location

  let fix = null, permission = true, watching = false;
  H.locationStart = () => {
    if (watching || !navigator.geolocation) return !!navigator.geolocation;
    watching = true;
    navigator.geolocation.watchPosition(p => {
      permission = true;
      const c = p.coords;
      fix = { lat: c.latitude, lon: c.longitude, accuracy: c.accuracy || 50,
        speed: c.speed == null || isNaN(c.speed) ? -1 : c.speed,
        bearing: c.heading == null || isNaN(c.heading) ? -1 : c.heading, time: p.timestamp, provider: "browser" };
    }, e => { if (e.code === 1) permission = false; }, { enableHighAccuracy: true, maximumAge: 1000 });
    return true;
  };
  H.location = () => {
    if (fix) fix.ageMs = Date.now() - fix.time;
    return { permission, fix };
  };
  function moving() { return fix && fix.speed > 2.8; }

  // ------------------------------------------------------------------------------------------
  // audio: the radio, and Jellyfin's queue; the phone's lock screen and headphone buttons work

  // iOS (and Chrome before the first tap) only start sound from inside a tap. A play() refused
  // that way is kept and tried again on the next tap anywhere on the page.
  const pending = new Set();
  function tryPlay(el, onFail) {
    const p = el.play();
    if (p && p.catch) p.catch(e => { if (e && e.name === "NotAllowedError") { pending.add(el); if (onFail) onFail(); } });
  }
  function onGesture() {
    for (const el of pending) { pending.delete(el); el.play().catch(() => {}); }
    if (window.speechSynthesis && !RT.spoke) { RT.spoke = true; try { speechSynthesis.speak(new SpeechSynthesisUtterance(" ")); } catch (e) {} }
    if (wantKb && document.activeElement !== kb) kb.focus({ preventScroll: true });
  }
  window.addEventListener("touchend", onGesture, true);
  window.addEventListener("mouseup", onGesture, true);
  window.addEventListener("keydown", onGesture, true);

  function upgrade(url) { return location.protocol === "https:" && /^http:/.test(url) ? url.replace(/^http:/, "https:") : url; }
  const radio = { audio: new Audio(), state: "idle", station: null, list: [], error: null, labels: {} };
  radio.audio.preload = "none";
  radio.audio.addEventListener("playing", () => { radio.state = "playing"; radio.error = null; });
  radio.audio.addEventListener("waiting", () => { if (radio.state !== "paused") radio.state = "connecting"; });
  radio.audio.addEventListener("pause", () => { if (radio.state !== "idle") radio.state = "paused"; });
  radio.audio.addEventListener("error", () => {
    if (radio.state === "idle") return;
    radio.state = "error";
    radio.error = location.protocol === "https:" && /^http:/.test(radio.station && radio.station.url || "")
      ? (radio.labels.lHttp || "This station only streams without encryption, which browsers block") : (radio.labels.lError || "Can't play this station");
  });
  function session(meta, handlers) {
    if (!("mediaSession" in navigator)) return;
    try {
      navigator.mediaSession.metadata = new MediaMetadata(meta);
      for (const [k, f] of Object.entries(handlers)) navigator.mediaSession.setActionHandler(k, f);
    } catch (e) { /* older browsers */ }
  }
  function radioPlay(st) {
    music.audio.pause();
    radio.station = st;
    radio.state = "connecting";
    radio.error = null;
    radio.audio.src = upgrade(st.url);
    tryPlay(radio.audio, () => { radio.state = "paused"; radio.error = null; });
    session({ title: st.name || "Radio", artist: st.sub || "Road Trip" }, {
      play: () => H.radioCommand({ what: "play" }), pause: () => H.radioCommand({ what: "pause" }),
      nexttrack: () => H.radioCommand({ what: "next" }), previoustrack: () => H.radioCommand({ what: "prev" }),
    });
  }
  H.radioPlay = (a) => { radioPlay(a.station); return true; };
  H.radioList = (a) => { radio.list = a.list || []; return true; };
  H.radioLabels = (a) => { radio.labels = a; return true; };
  H.radioCommand = (a) => {
    const w = a.what;
    if (w === "stop") { radio.audio.pause(); radio.audio.removeAttribute("src"); radio.state = "idle"; radio.station = null; }
    else if (w === "pause") radio.audio.pause();
    else if (w === "play" && radio.station) { radio.state = "connecting"; tryPlay(radio.audio); }
    else if (w === "toggle" && radio.station) { if (radio.audio.paused) { radio.state = "connecting"; tryPlay(radio.audio); } else radio.audio.pause(); }
    else if ((w === "next" || w === "prev") && radio.list.length) {
      let i = radio.list.findIndex(s => radio.station && s.uuid === radio.station.uuid);
      i = (i + (w === "next" ? 1 : -1) + radio.list.length) % radio.list.length;
      radioPlay(radio.list[i]);
    }
    return true;
  };
  H.radioStatus = () => ({ state: radio.state, station: radio.station, error: radio.error });

  const music = { audio: new Audio(), queue: [], index: 0, error: null, loading: false };
  music.audio.addEventListener("ended", () => { if (music.index < music.queue.length - 1) loadTrack(music.index + 1); });
  music.audio.addEventListener("error", () => { music.error = "Can't play this track"; });
  music.audio.addEventListener("waiting", () => { music.loading = true; });
  music.audio.addEventListener("playing", () => { music.loading = false; music.error = null; });
  function loadTrack(i) {
    music.index = i;
    const t = music.queue[i];
    if (!t) return;
    music.audio.src = t.url;
    music.loading = true;
    tryPlay(music.audio, () => { music.loading = false; });
    session({ title: t.title || "", artist: t.artist || "", album: t.album || "" }, {
      play: () => music.audio.play(), pause: () => music.audio.pause(),
      nexttrack: () => H.musicCommand({ what: "next" }), previoustrack: () => H.musicCommand({ what: "prev" }),
    });
  }
  H.musicPlay = (a) => { radio.audio.pause(); music.queue = a.tracks || []; music.error = null; loadTrack(a.index || 0); return true; };
  H.musicCommand = (a) => {
    const au = music.audio, w = a.what;
    if (w === "play") tryPlay(au);
    else if (w === "pause") au.pause();
    else if (w === "toggle") { if (au.paused) tryPlay(au); else au.pause(); }
    else if (w === "next") loadTrack(Math.min(music.queue.length - 1, music.index + 1));
    else if (w === "prev") { if (au.currentTime > 4) au.currentTime = 0; else loadTrack(Math.max(0, music.index - 1)); }
    else if (w === "seek") au.currentTime = (a.posMs || 0) / 1000;
    else if (w === "stop") { au.pause(); au.removeAttribute("src"); music.queue = []; }
    return true;
  };
  H.musicStatus = () => {
    if (!music.queue.length) return { state: "idle" };
    const au = music.audio;
    const state = music.error ? "error" : au.ended ? "ended" : music.loading ? "connecting" : au.paused ? "paused" : "playing";
    return { state, index: music.index, count: music.queue.length, durationMs: isFinite(au.duration) ? au.duration * 1000 : 0,
      positionMs: au.currentTime * 1000, track: music.queue[music.index] || {}, error: music.error };
  };

  // ------------------------------------------------------------------------------------------
  // the voice: the browser's own speech

  let voiceCfg = { engine: "system", systemVoice: "", lang: "en" };
  function voicesFor(code) {
    const all = (window.speechSynthesis && speechSynthesis.getVoices()) || [];
    return all.filter(v => v.lang && v.lang.toLowerCase().startsWith(code));
  }
  H.voiceConfig = (a) => { voiceCfg = a; return true; };
  H.voicePrepare = () => true;
  H.voiceSpeak = (a) => {
    if (!window.speechSynthesis || voiceCfg.engine === "off") return false;
    const u = new SpeechSynthesisUtterance(a.text);
    const list = voicesFor(voiceCfg.lang || "en");
    const v = list.find(x => x.name === voiceCfg.systemVoice) || list[0];
    if (v) { u.voice = v; u.lang = v.lang; } else u.lang = voiceCfg.lang || "en";
    speechSynthesis.cancel();
    speechSynthesis.speak(u);
    return true;
  };
  const downloads = {};
  H.voiceDownload = (a) => { downloads[a.id] = { state: "error", error: "natural voices need the Android app" }; return false; };
  H.voiceDelete = () => true;
  H.voiceStatus = () => ({ engine: voiceCfg.engine, installed: [], downloads,
    systemVoices: voicesFor(voiceCfg.lang || "en").map(v => ({ name: v.name, country: v.lang, network: !v.localService })) });

  // ------------------------------------------------------------------------------------------
  // the keyboard: a hidden text box brings up the phone's keyboard; what's typed goes to Lua

  const keys = [];
  const kb = document.createElement("input");
  kb.type = "text";
  kb.autocomplete = "off"; kb.autocapitalize = "off"; kb.spellcheck = false;
  kb.setAttribute("autocorrect", "off");
  kb.style.cssText = "position:fixed;left:0;bottom:0;width:1px;height:1px;opacity:0;border:0;padding:0;font-size:16px;z-index:-1";
  const SENTINEL = "​";
  kb.value = SENTINEL;
  document.addEventListener("DOMContentLoaded", () => document.body.appendChild(kb));
  kb.addEventListener("input", () => {
    const v = kb.value;
    if (v.length < SENTINEL.length || !v.startsWith(SENTINEL)) keys.push({ t: "key", v: "backspace" });
    const text = v.replace(SENTINEL, "");
    if (text) keys.push({ t: "text", v: text });
    kb.value = SENTINEL;
  });
  kb.addEventListener("keydown", e => {
    e.stopPropagation(); // love.js would see it too
    if (e.key === "Enter") { keys.push({ t: "key", v: "return" }); e.preventDefault(); }
    else if (e.key === "Escape") { keys.push({ t: "key", v: "escape" }); e.preventDefault(); }
    else if (e.key === "Backspace" && kb.value === SENTINEL) { keys.push({ t: "key", v: "backspace" }); e.preventDefault(); }
  });
  kb.addEventListener("keyup", e => e.stopPropagation());
  kb.addEventListener("keypress", e => e.stopPropagation());
  let wantKb = false;
  const kbPill = document.createElement("button");
  kbPill.id = "kbpill";
  kbPill.textContent = "⌨";
  kbPill.addEventListener("click", e => { e.stopPropagation(); kb.focus({ preventScroll: true }); });
  document.addEventListener("DOMContentLoaded", () => document.body.appendChild(kbPill));
  function kbPillShow() { kbPill.style.display = wantKb && document.activeElement !== kb ? "block" : "none"; }
  kb.addEventListener("focus", kbPillShow);
  kb.addEventListener("blur", () => setTimeout(kbPillShow, 50));
  H.keyboard = (a) => {
    wantKb = !!a.on;
    if (a.on) { kb.value = SENTINEL; kb.focus({ preventScroll: true }); }
    else kb.blur();
    setTimeout(kbPillShow, 120);
    return true;
  };
  H.keys = () => keys.splice(0, keys.length);

  // the microphone button: say where to go (Chrome and Safari can listen; Firefox can't)
  let listening = null;
  H.voice = () => {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) return false;
    if (listening) { try { listening.abort(); } catch (e) {} }
    const r = new SR();
    r.lang = (voiceCfg.lang || navigator.language || "en");
    r.interimResults = false;
    r.maxAlternatives = 1;
    r.onresult = e => { const t = e.results[0] && e.results[0][0] && e.results[0][0].transcript; if (t) keys.push({ t: "heard", v: t.trim() }); };
    r.onend = () => { if (listening === r) listening = null; };
    listening = r;
    try { r.start(); } catch (e) { return false; }
    return true;
  };

  // the phone's back gesture / browser back = Road Trip's back
  history.replaceState({ rt: 0 }, "");
  history.pushState({ rt: 1 }, "");
  window.addEventListener("popstate", () => { keys.push({ t: "key", v: "escape" }); history.pushState({ rt: 1 }, ""); });

  // ------------------------------------------------------------------------------------------
  // Road Trip's real pixels -> CSS pixels

  function canvasEl() { return document.getElementById("canvas"); }
  function px(v) { const c = canvasEl(); return v * (c.clientWidth / (c.width || c.clientWidth || 1)); }
  function placeEl(el, x, y, w, h) {
    el.style.left = px(x) + "px"; el.style.top = px(y) + "px";
    el.style.width = px(w) + "px"; el.style.height = px(h) + "px";
  }

  // ------------------------------------------------------------------------------------------
  // the map: MapLibre GL JS under the canvas (the canvas is see-through where Lua leaves holes)

  const ENGINE_KEY = "roadtrip-map-engine";
  let engine = "maplibre";
  try { engine = localStorage.getItem(ENGINE_KEY) || "maplibre"; } catch (e) { /* private mode */ }
  const mp = { map: null, el: null, ready: false, styleLoaded: false, style: null, error: "", scale: 1, accent: "#F2A23A",
    route: empty(), alt: empty(), pos: empty(), dest: empty(), width: 8, glyphs: null };
  RT.mp = mp;
  function empty() { return { type: "FeatureCollection", features: [] }; }
  const WP_FONTS = new Set(["Waypoint Atlas", "Waypoint Borda", "Waypoint Classic", "Waypoint Condensed", "Waypoint Futura",
    "Waypoint Pixel", "Waypoint Retro", "Waypoint Stratum", "Waypoint Technical", "Waypoint Terminal", "Waypoint Western"]);
  fetch("waypoint/glyphs.json").then(r => r.json()).then(j => { mp.glyphs = j; }).catch(() => { mp.glyphs = {}; });

  function ensureMap() {
    if (mp.map || engine !== "maplibre" || !window.maplibregl) return;
    mp.el = document.getElementById("map");
    mp.map = new maplibregl.Map({
      container: mp.el, style: { version: 8, sources: {}, layers: [{ id: "bg", type: "background", paint: { "background-color": "#15191A" } }] },
      center: [12.5683, 55.6761], zoom: 14, interactive: false, attributionControl: false, fadeDuration: 0,
      transformRequest: (url) => {
        const m = url.match(/^https:\/\/tiles\.openfreemap\.org\/fonts\/([^/]+)\/(\d+-\d+\.pbf)$/);
        if (m) {
          const font = decodeURIComponent(m[1]);
          if (WP_FONTS.has(font)) {
            if (mp.glyphs && mp.glyphs[font] && mp.glyphs[font].includes(m[2])) return { url: new URL("waypoint/glyphs/" + encodeURIComponent(font) + "/" + m[2], location.href).href };
            return { url: "https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/" + m[2] };
          }
        }
        return { url };
      },
    });
    mp.map.on("error", e => { mp.error = (e && e.error && e.error.message) || "map error"; });
    mp.map.on("style.load", () => { addOverlays(); mp.styleLoaded = true; });
    mp.map.on("styleimagemissing", e => {
      const name = e.id;
      if (/^(pixel-grass|pixel-stone|pixel-water|paper-fibre)$/.test(name)) {
        mp.map.loadImage("waypoint/images/" + name.replace("-", "_") + ".png").then(img => {
          if (!mp.map.hasImage(name)) mp.map.addImage(name, img.data);
        }).catch(() => {});
      }
    });
    mp.ready = true;
  }
  H.mapStatus = () => { ensureMap(); return { engine, attached: engine === "maplibre" && !!window.maplibregl, ready: mp.ready,
    failed: false, styleLoaded: mp.styleLoaded, style: mp.style || "", error: mp.error }; };
  H.mapSetEngine = (a) => { try { localStorage.setItem(ENGINE_KEY, a.engine === "classic" ? "classic" : "maplibre"); } catch (e) {} setTimeout(() => location.reload(), 300); return true; };
  H.mapInit = (a) => { ensureMap(); if (a.scale) mp.scale = a.scale; if (a.accent) mp.accent = a.accent; return !!mp.map; };
  H.mapShow = (a) => { ensureMap(); if (!mp.map) return false; mp.el.style.display = "block"; placeEl(mp.el, a.x, a.y, a.w, a.h); mp.map.resize(); return true; };
  H.mapHide = () => { if (mp.el) mp.el.style.display = "none"; return true; };
  H.mapCamera = (a) => {
    if (!mp.map) return false;
    const dpr = window.devicePixelRatio || 1;
    // Lua's zoom: 512-unit tiles in its own units (mp.scale real pixels each); MapLibre: 512 CSS px
    const zoom = Math.max(0, Math.min(21, a.zoom + Math.log2(px(mp.scale) / 1)));
    const h = mp.el.clientHeight;
    const ahead = a.ahead == null ? 0.5 : a.ahead;
    const padding = { top: ahead > 0.5 ? (2 * ahead - 1) * h : 0, bottom: ahead < 0.5 ? (1 - 2 * ahead) * h : 0, left: 0, right: 0 };
    const cam = { center: [a.lon, a.lat], zoom, bearing: a.bearing || 0, pitch: Math.max(0, Math.min(60, a.tilt || 0)), padding };
    if (a.ms > 0) mp.map.easeTo(Object.assign(cam, { duration: a.ms, easing: t => t }));
    else mp.map.jumpTo(cam);
    void dpr;
    return true;
  };
  H.mapStyle = (a) => {
    ensureMap();
    if (!mp.map || a.id === mp.style) return !!mp.map;
    mp.style = a.id;
    mp.styleLoaded = false;
    let url = "https://tiles.openfreemap.org/styles/liberty";
    if (a.id.startsWith("ofm:")) url = "https://tiles.openfreemap.org/styles/" + a.id.slice(4).replace(/[^a-z]/g, "");
    else if (a.id.startsWith("wp:")) url = new URL("waypoint/styles/" + a.id.slice(3).replace(/[^a-z0-9_]/g, "") + ".json", location.href).href;
    mp.map.setStyle(url, { diff: false });
    return true;
  };
  function lines(list, color) {
    return { type: "FeatureCollection", features: (list || []).map(o => {
      const coords = Array.isArray(o) ? o : o.c;
      return { type: "Feature", properties: { color: (o && o.color) || color || mp.accent }, geometry: { type: "LineString", coordinates: coords } };
    }) };
  }
  function setData(id, data) { const s = mp.map && mp.map.getSource(id); if (s) s.setData(data); }
  H.mapRoute = (a) => {
    mp.width = px((a.width || 16) * mp.scale);
    mp.route = lines(Array.isArray(a.route) ? a.route : []);
    mp.alt = lines(Array.isArray(a.alt) ? a.alt : [], "#8A8D93");
    if (mp.styleLoaded) {
      setData("rt-route", mp.route); setData("rt-alt", mp.alt);
      try {
        mp.map.setPaintProperty("rt-route-line", "line-width", mp.width);
        mp.map.setPaintProperty("rt-route-casing", "line-width", mp.width + 5);
        mp.map.setPaintProperty("rt-alt-line", "line-width", mp.width * 0.6);
      } catch (e) { /* not added yet */ }
    }
    return true;
  };
  H.mapMarkers = (a) => {
    const p = a.pos;
    mp.pos = p ? { type: "Feature", geometry: { type: "Point", coordinates: [p.lon, p.lat] },
      properties: { bearing: Math.max(0, p.bearing), moving: p.bearing >= 0, r0: (p.acc || 0) / (40075016.686 * Math.cos(p.lat * Math.PI / 180) / 512) } } : empty();
    mp.dest = a.dest ? { type: "Feature", geometry: { type: "Point", coordinates: [a.dest.lon, a.dest.lat] }, properties: {} } : empty();
    if (mp.styleLoaded) { setData("rt-pos", mp.pos); setData("rt-dest", mp.dest); }
    return true;
  };
  function drawImage(w, h, draw) {
    const dpr = window.devicePixelRatio || 1;
    const c = document.createElement("canvas");
    c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
    const g = c.getContext("2d");
    g.scale(dpr, dpr);
    draw(g);
    return { image: g.getImageData(0, 0, c.width, c.height), pixelRatio: dpr };
  }
  function addOverlays() {
    const m = mp.map;
    try {
      const arrow = drawImage(22, 22, g => { g.fillStyle = "#0E0F11"; g.beginPath(); g.moveTo(11, 2); g.lineTo(19, 19); g.lineTo(11, 15); g.lineTo(3, 19); g.closePath(); g.fill(); });
      const pin = drawImage(32, 44, g => {
        g.fillStyle = "#0E0F11"; g.beginPath(); g.arc(16, 16, 16, 0, 7); g.fill();
        g.beginPath(); g.moveTo(6.4, 24); g.lineTo(25.6, 24); g.lineTo(16, 44); g.closePath(); g.fill();
        g.fillStyle = "#E8E5DD"; g.beginPath(); g.arc(16, 16, 13, 0, 7); g.fill();
        g.beginPath(); g.moveTo(8.6, 24); g.lineTo(23.4, 24); g.lineTo(16, 40); g.closePath(); g.fill();
        g.fillStyle = mp.accent; g.beginPath(); g.arc(16, 16, 6.4, 0, 7); g.fill();
      });
      if (!m.hasImage("rt-arrow")) m.addImage("rt-arrow", arrow.image, { pixelRatio: arrow.pixelRatio });
      if (!m.hasImage("rt-pin")) m.addImage("rt-pin", pin.image, { pixelRatio: pin.pixelRatio });
      m.addSource("rt-alt", { type: "geojson", data: mp.alt });
      m.addSource("rt-route", { type: "geojson", data: mp.route });
      m.addSource("rt-dest", { type: "geojson", data: mp.dest });
      m.addSource("rt-pos", { type: "geojson", data: mp.pos });
      const round = { "line-join": "round", "line-cap": "round" };
      m.addLayer({ id: "rt-alt-line", type: "line", source: "rt-alt", layout: round, paint: { "line-color": ["get", "color"], "line-width": mp.width * 0.6, "line-opacity": 0.8 } });
      m.addLayer({ id: "rt-route-casing", type: "line", source: "rt-route", layout: round, paint: { "line-color": "#0E0F11", "line-width": mp.width + 5 } });
      m.addLayer({ id: "rt-route-line", type: "line", source: "rt-route", layout: round, paint: { "line-color": ["get", "color"], "line-width": mp.width } });
      m.addLayer({ id: "rt-dest-pin", type: "symbol", source: "rt-dest", layout: { "icon-image": "rt-pin", "icon-anchor": "bottom", "icon-allow-overlap": true, "icon-ignore-placement": true } });
      m.addLayer({ id: "rt-pos-acc", type: "circle", source: "rt-pos", paint: {
        "circle-radius": ["interpolate", ["exponential", 2], ["zoom"], 0, ["get", "r0"], 22, ["*", ["get", "r0"], 4194304]],
        "circle-color": mp.accent, "circle-opacity": 0.14, "circle-pitch-alignment": "map" } });
      m.addLayer({ id: "rt-pos-puck", type: "circle", source: "rt-pos", paint: { "circle-radius": 11, "circle-color": "#E8E5DD",
        "circle-stroke-color": "#0E0F11", "circle-stroke-width": 1.5, "circle-pitch-alignment": "map" } });
      m.addLayer({ id: "rt-pos-dot", type: "circle", source: "rt-pos", paint: { "circle-radius": 5.5, "circle-color": mp.accent,
        "circle-opacity": ["case", ["get", "moving"], 0, 1], "circle-pitch-alignment": "map" } });
      m.addLayer({ id: "rt-pos-arrow", type: "symbol", source: "rt-pos", layout: { "icon-image": "rt-arrow", "icon-rotate": ["get", "bearing"],
        "icon-rotation-alignment": "map", "icon-pitch-alignment": "map", "icon-allow-overlap": true, "icon-ignore-placement": true },
        paint: { "icon-opacity": ["case", ["get", "moving"], 1, 0] } });
    } catch (e) { mp.error = "overlay: " + e.message; }
  }

  // ------------------------------------------------------------------------------------------
  // the panel: Jellyfin's video, and the browser (pages open in a new tab: most sites refuse to
  // be shown inside another page)

  const panel = { el: null, kind: "", video: null, note: null, cover: null, labels: {}, shown: false, hls: null,
    web: { url: "", title: "", history: [], pos: -1 }, vErr: null };
  function panelEl() {
    if (panel.el) return panel.el;
    panel.el = document.getElementById("panel");
    panel.video = document.createElement("video");
    panel.video.playsInline = true;
    panel.video.setAttribute("playsinline", "");
    panel.video.style.cssText = "width:100%;height:100%;background:#000;display:none";
    panel.video.addEventListener("error", () => { panel.vErr = "MEDIA_ERR " + (panel.video.error && panel.video.error.code); });
    panel.note = document.createElement("div");
    panel.note.className = "note";
    panel.cover = document.createElement("div");
    panel.cover.className = "cover";
    panel.el.append(panel.video, panel.note, panel.cover);
    setInterval(() => {
      const drive = overlay.video !== false && (moving() || (!fix && overlay.noSpeed === "block" && false));
      panel.cover.style.display = panel.shown && drive ? "flex" : "none";
      panel.cover.textContent = panel.kind === "web" ? (panel.labels.web || "") : (panel.labels.video || "");
    }, 500);
    return panel.el;
  }
  H.panelLabels = (a) => { panel.labels = a.labels || a; return true; };
  H.panelShow = (a) => {
    const el = panelEl();
    panel.kind = a.kind;
    panel.shown = true;
    el.style.display = "block";
    placeEl(el, a.x, a.y, a.w, a.h);
    panel.video.style.display = a.kind === "video" ? "block" : "none";
    panel.note.style.display = a.kind === "web" ? "flex" : "none";
    if (a.kind === "web") renderNote();
    return true;
  };
  H.panelHide = () => {
    if (panel.el) panel.el.style.display = "none";
    panel.shown = false;
    if (panel.video && panel.kind === "video") panel.video.pause();
    return true;
  };
  function renderNote() {
    const w = panel.web;
    panel.note.innerHTML = "";
    const box = document.createElement("div");
    const t = document.createElement("p");
    t.textContent = panel.labels.webNote || "In the browser version, pages open in a new tab: most sites don't allow being shown inside another page.";
    box.append(t);
    if (w.url) {
      const b = document.createElement("button");
      b.textContent = (panel.labels.webOpen || "Open") + " " + w.url.replace(/^https?:\/\//, "").replace(/\/$/, "");
      b.onclick = () => window.open(w.url, "_blank", "noopener");
      box.append(b);
    }
    panel.note.append(box);
  }
  H.webCommand = (a) => {
    const w = panel.web;
    if (a.what === "load" && a.url) {
      w.history = w.history.slice(0, w.pos + 1);
      w.history.push(a.url);
      w.pos = w.history.length - 1;
      w.url = a.url;
      // the first page (the start page) only shows the note; anything you ask for opens
      if (w.pos > 0 || !/duckduckgo\.com\/?$/.test(a.url)) window.open(a.url, "_blank", "noopener");
    } else if (a.what === "back" && w.pos > 0) { w.pos--; w.url = w.history[w.pos]; }
    else if (a.what === "forward" && w.pos < w.history.length - 1) { w.pos++; w.url = w.history[w.pos]; }
    if (panel.note) renderNote();
    return true;
  };
  H.webStatus = () => {
    const w = panel.web;
    return { url: w.url, title: "", progress: 100, canBack: w.pos > 0, canForward: w.pos < w.history.length - 1, open: true };
  };
  function loadScript(src) {
    return new Promise((ok, bad) => { const s = document.createElement("script"); s.src = src; s.onload = ok; s.onerror = bad; document.head.append(s); });
  }
  H.videoPlay = (a) => {
    panelEl();
    const v = panel.video;
    music.audio.pause(); radio.audio.pause();
    panel.vErr = null;
    if (panel.hls) { panel.hls.destroy(); panel.hls = null; }
    const start = () => { if (a.startMs) v.currentTime = a.startMs / 1000; tryPlay(v); };
    if (/\.m3u8/.test(a.url) && !v.canPlayType("application/vnd.apple.mpegurl")) {
      loadScript("https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js").then(() => {
        panel.hls = new Hls();
        panel.hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal) panel.vErr = "HLS " + d.details; });
        panel.hls.loadSource(a.url);
        panel.hls.attachMedia(v);
        panel.hls.on(Hls.Events.MANIFEST_PARSED, start);
      }).catch(() => { panel.vErr = "couldn't load the HLS player"; });
    } else {
      v.src = a.url;
      start();
    }
    panel.vUrl = a.url;
    return true;
  };
  H.videoCommand = (a) => {
    const v = panel.video;
    if (!v) return false;
    if (a.what === "toggle") { if (v.paused) tryPlay(v); else v.pause(); }
    else if (a.what === "play") tryPlay(v);
    else if (a.what === "pause") v.pause();
    else if (a.what === "seek") v.currentTime = (a.posMs || 0) / 1000;
    else if (a.what === "stop") { v.pause(); if (panel.hls) { panel.hls.destroy(); panel.hls = null; } v.removeAttribute("src"); v.load(); }
    return true;
  };
  H.videoStatus = () => {
    const v = panel.video;
    if (!v) return { state: "idle" };
    const state = v.error || panel.vErr ? "error" : v.ended ? "ended" : v.readyState < 3 && !v.paused ? "connecting" : v.paused ? "paused" : "playing";
    return { state, positionMs: v.currentTime * 1000, durationMs: isFinite(v.duration) ? v.duration * 1000 : 0,
      width: v.videoWidth, height: v.videoHeight, url: panel.vUrl || "", error: panel.vErr || undefined };
  };
})();
