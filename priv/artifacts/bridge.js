// The artifact bridge, injected first in every HTML page of an artifact
// (robot-docs/artifacts.md). The page runs with an opaque origin, so the
// browser's own storage throws; this stands in for it, keeps what the page
// saves, reports what breaks, gives the page albedo's colours, and lets it
// talk to the chat through the window that holds it.
(function () {
  'use strict';
  var boot = window.__albedo || {};
  delete window.__albedo;
  var base = boot.base || './';
  var embedded = window.parent !== window;

  function post(path, body, keepalive) {
    try {
      fetch(base + '.albedo/' + path, {
        method: 'POST',
        mode: 'no-cors',
        body: body,
        // A body past 64 KiB cannot ride along with a closing page.
        keepalive: !!keepalive && body.length < 60000,
        credentials: 'omit'
      }).catch(function () {});
    } catch (_) {}
  }

  // Storage. localStorage is kept per artifact, across reloads and versions;
  // sessionStorage and cookies last as long as the page.
  function memory(initial, changed) {
    var items = Object.create(null);
    for (var name in initial) items[name] = String(initial[name]);
    var storage = {
      getItem: function (key) {
        key = String(key);
        return key in items ? items[key] : null;
      },
      setItem: function (key, value) {
        items[String(key)] = String(value);
        changed(items);
      },
      removeItem: function (key) {
        key = String(key);
        if (key in items) {
          delete items[key];
          changed(items);
        }
      },
      clear: function () {
        items = Object.create(null);
        changed(items);
      },
      key: function (index) {
        var keys = Object.keys(items);
        return index >= 0 && index < keys.length ? keys[index] : null;
      }
    };
    Object.defineProperty(storage, 'length', {
      get: function () {
        return Object.keys(items).length;
      }
    });
    // storage.foo and storage.foo = 'x' work as they do on real storage.
    return typeof Proxy === 'function'
      ? new Proxy(storage, {
          get: function (target, key) {
            if (typeof key !== 'string' || key in target) return target[key];
            return target.getItem(key) === null ? undefined : target.getItem(key);
          },
          set: function (target, key, value) {
            if (typeof key === 'string' && !(key in target)) target.setItem(key, value);
            return true;
          },
          deleteProperty: function (target, key) {
            target.removeItem(key);
            return true;
          },
          ownKeys: function () {
            return Object.keys(items);
          },
          getOwnPropertyDescriptor: function (_, key) {
            return key in items ? { value: items[key], enumerable: true, configurable: true } : undefined;
          }
        })
      : storage;
  }

  var saved = {};
  try {
    saved = JSON.parse(boot.state || '{}') || {};
  } catch (_) {}
  var pending = null;
  var timer = 0;
  function flush(closing) {
    if (pending === null) return;
    var body = pending;
    pending = null;
    clearTimeout(timer);
    post('state', body, closing);
  }
  var local = memory(saved, function (items) {
    pending = JSON.stringify(items);
    clearTimeout(timer);
    timer = setTimeout(flush, 400);
  });
  window.addEventListener('pagehide', function () {
    flush(true);
  });
  function stand(name, value) {
    try {
      Object.defineProperty(window, name, { value: value, configurable: true, enumerable: true });
    } catch (_) {}
  }
  stand('localStorage', local);
  stand('sessionStorage', memory({}, function () {}));
  var cookies = Object.create(null);
  try {
    Object.defineProperty(document, 'cookie', {
      configurable: true,
      get: function () {
        return Object.keys(cookies)
          .map(function (name) {
            return name + '=' + cookies[name];
          })
          .join('; ');
      },
      set: function (text) {
        var pair = String(text).split(';')[0];
        var at = pair.indexOf('=');
        if (at < 1) return;
        var name = pair.slice(0, at).trim();
        var value = pair.slice(at + 1).trim();
        if (/max-age=0|expires=thu, 01 jan 1970/i.test(text)) delete cookies[name];
        else cookies[name] = value;
      }
    });
  } catch (_) {}

  // Theme. Until the window says otherwise, albedo's palette for the
  // system's colour scheme.
  var palettes = {
    light: {
      '--albedo-bg': '#f6eff8',
      '--albedo-surface': '#fdfafd',
      '--albedo-text': '#584a5c',
      '--albedo-muted': '#7a6c7e',
      '--albedo-faint': '#9d90a1',
      '--albedo-accent': '#6928bd',
      '--albedo-border': '#e7dcea',
      '--albedo-added': '#5e8933',
      '--albedo-danger': '#ce2700'
    },
    dark: {
      '--albedo-bg': '#241c26',
      '--albedo-surface': '#2b222d',
      '--albedo-text': '#e1d1e7',
      '--albedo-muted': '#ad9db2',
      '--albedo-faint': '#86788b',
      '--albedo-accent': '#ddb3ff',
      '--albedo-border': '#3d3241',
      '--albedo-added': '#c1dd4a',
      '--albedo-danger': '#ff8b79'
    }
  };
  var fonts = {
    '--albedo-sans': "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif",
    '--albedo-mono': "ui-monospace, 'SF Mono', Menlo, Consolas, monospace"
  };
  var themeStyle = document.createElement('style');
  themeStyle.setAttribute('data-albedo', 'theme');
  (document.head || document.documentElement).appendChild(themeStyle);
  var scheme = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  var hosted = false;
  var listeners = [];
  var theme = 'light';
  function apply(name, variables) {
    theme = name === 'dark' ? 'dark' : 'light';
    var values = {};
    var key;
    for (key in palettes[theme]) values[key] = palettes[theme][key];
    for (key in fonts) values[key] = fonts[key];
    for (key in variables || {}) {
      if (/^--albedo-[a-z-]+$/.test(key) && typeof variables[key] === 'string') values[key] = variables[key];
    }
    var css = ':root{color-scheme:' + theme + ';';
    for (key in values) css += key + ':' + String(values[key]).replace(/[;{}<]/g, '') + ';';
    themeStyle.textContent = css + '}';
    document.documentElement.setAttribute('data-albedo-theme', theme);
    listeners.forEach(function (listener) {
      try {
        listener(theme);
      } catch (_) {}
    });
  }
  apply(scheme && scheme.matches ? 'dark' : 'light');
  if (scheme && scheme.addEventListener) {
    scheme.addEventListener('change', function (event) {
      if (!hosted) apply(event.matches ? 'dark' : 'light');
    });
  }
  function context(hostContext) {
    if (!hostContext) return;
    hosted = true;
    apply(hostContext.theme, hostContext.styles && hostContext.styles.variables);
  }

  // The window: JSON-RPC 2.0 over postMessage, as MCP Apps speaks it.
  var calls = Object.create(null);
  var counter = 0;
  function send(message) {
    if (embedded) window.parent.postMessage(Object.assign({ jsonrpc: '2.0' }, message), '*');
  }
  function request(method, params) {
    return new Promise(function (resolve, reject) {
      if (!embedded) return reject(new Error('this page is open on its own, outside albedo'));
      var id = 'albedo-' + ++counter;
      calls[id] = { resolve: resolve, reject: reject };
      send({ id: id, method: method, params: params });
    });
  }
  window.addEventListener('message', function (event) {
    if (event.source !== window.parent || !event.data || event.data.jsonrpc !== '2.0') return;
    var data = event.data;
    if (data.id in calls && (data.result !== undefined || data.error !== undefined)) {
      var call = calls[data.id];
      delete calls[data.id];
      if (data.error) call.reject(new Error(data.error.message || 'the window refused'));
      else call.resolve(data.result);
    } else if (data.method === 'ui/notifications/host-context-changed') {
      context(data.params);
    } else if (data.method === 'albedo/point') {
      point(data.params);
    } else if (data.method === 'albedo/watch') {
      follow(data.params);
    }
  });

  // Notes. A note on the canvas can be tied to a part of the page: while its
  // tie is drawn over the page the window asks what is under the pointer, and
  // for every part a note is tied to, where it is now.
  var PARTS = 'h1,h2,h3,h4,h5,h6,p,li,dt,dd,button,a,label,img,svg,canvas,video,figure,blockquote,pre,table,tr,td,th,input,select,textarea,article,section,aside,nav,header,footer,form,[role],[id]';
  function partAt(x, y) {
    var element = document.elementFromPoint(x, y);
    if (element && element.closest) element = element.closest(PARTS) || element;
    if (!element || element === document.body || element === document.documentElement) return null;
    // An svg's shapes are one picture.
    if (element.ownerSVGElement) element = element.ownerSVGElement;
    return element;
  }
  function selectorOf(element) {
    var steps = [];
    for (var node = element; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      if (node.id && document.querySelectorAll('#' + CSS.escape(node.id)).length === 1) {
        steps.unshift('#' + CSS.escape(node.id));
        return steps.join(' > ');
      }
      var tag = node.tagName.toLowerCase();
      var same = 0;
      var index = 0;
      for (var sibling = node.parentElement && node.parentElement.firstElementChild; sibling; sibling = sibling.nextElementSibling) {
        if (sibling.tagName === node.tagName) same++;
        if (sibling === node) index = same;
      }
      steps.unshift(same > 1 ? tag + ':nth-of-type(' + index + ')' : tag);
    }
    steps.unshift('body');
    return steps.join(' > ');
  }
  function quoteOf(element) {
    var tag = element.tagName.toLowerCase();
    var text = tag === 'img' ? element.alt || '' : tag === 'input' || tag === 'textarea' ? element.value || element.placeholder || '' : element.innerText || element.textContent || '';
    text = String(text).replace(/[ \t]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim();
    if (!text) return 'a <' + tag + '>';
    return text.length > 600 ? text.slice(0, 600) + '…' : text;
  }
  function box(element) {
    var rect = element.getBoundingClientRect();
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  }
  function point(params) {
    if (!params || typeof params.x !== 'number' || typeof params.y !== 'number') return;
    var element = partAt(params.x, params.y);
    send({
      method: 'albedo/pointed',
      params: element
        ? { x: params.x, y: params.y, selector: selectorOf(element), quote: quoteOf(element), rect: box(element) }
        : { x: params.x, y: params.y, selector: null }
    });
  }
  var watched = [];
  var measuring = 0;
  function locate() {
    measuring = 0;
    var rects = {};
    watched.forEach(function (selector) {
      var element = null;
      try {
        element = document.querySelector(selector);
      } catch (_) {}
      rects[selector] = element ? box(element) : null;
    });
    send({ method: 'albedo/rects', params: { rects: rects } });
  }
  function soon() {
    if (watched.length && !measuring) measuring = requestAnimationFrame(locate);
  }
  function follow(params) {
    watched = params && Array.isArray(params.selectors) ? params.selectors.filter(function (item) {
      return typeof item === 'string';
    }).slice(0, 64) : [];
    soon();
  }
  if (embedded) {
    window.addEventListener('scroll', soon, true);
    window.addEventListener('resize', soon);
    if (typeof MutationObserver === 'function') {
      var changes = new MutationObserver(soon);
      var observe = function () {
        changes.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', observe);
      else observe();
    }
  }

  // What breaks, the agent hears about: it keeps the newest twenty.
  var reported = 0;
  function report(message, source, line, column, stack) {
    if (reported >= 20) return;
    reported++;
    var failure = {
      message: String(message || 'unknown error').slice(0, 4000),
      source: String(source || '').slice(0, 2000),
      line: line | 0,
      column: column | 0,
      stack: String(stack || '').slice(0, 8000)
    };
    post('errors', JSON.stringify(failure), false);
    send({ method: 'albedo/error', params: failure });
  }
  window.addEventListener('error', function (event) {
    if (event.error || event.message) {
      report(event.message, event.filename, event.lineno, event.colno, event.error && event.error.stack);
    } else if (event.target && event.target !== window) {
      var target = event.target;
      report('could not load ' + (target.src || target.href || target.tagName), target.src || target.href, 0, 0, '');
    }
  }, true);
  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    report(reason && reason.message ? reason.message : String(reason), '', 0, 0, reason && reason.stack);
  });

  // Size, for the phone, which fits an artifact to its content.
  var height = 0;
  var frame = 0;
  function measure() {
    frame = 0;
    // The content's own height: scrollHeight never reports less than the frame.
    var next = Math.ceil(document.documentElement.getBoundingClientRect().height);
    if (next !== height) {
      height = next;
      send({ method: 'ui/notifications/size-changed', params: { width: Math.ceil(document.documentElement.getBoundingClientRect().width), height: next } });
    }
  }
  if (embedded && typeof ResizeObserver === 'function') {
    var observer = new ResizeObserver(function () {
      if (!frame) frame = requestAnimationFrame(measure);
    });
    var watch = function () {
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watch);
    else watch();
  }

  // A pinch over the page zooms albedo's canvas, as it does anywhere else.
  if (embedded) {
    window.addEventListener('wheel', function (event) {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      send({
        method: 'albedo/wheel',
        params: { deltaX: event.deltaX, deltaY: event.deltaY, deltaMode: event.deltaMode, x: event.clientX, y: event.clientY }
      });
    }, { passive: false });
  }

  if (embedded) {
    request('ui/initialize', {
      protocolVersion: '2026-01-26',
      appInfo: { name: boot.title || 'artifact', version: String(boot.version || '') },
      appCapabilities: {}
    }).then(function (result) {
      context(result && result.hostContext);
      send({ method: 'ui/notifications/initialized' });
    }, function () {});
  }

  var fresh = false;
  ['pointerdown', 'keydown'].forEach(function (type) {
    window.addEventListener(type, function (event) {
      if (event.isTrusted) fresh = true;
    }, true);
  });

  window.albedo = Object.freeze({
    artifact: Object.freeze({ id: boot.id, version: boot.version, latest: boot.latest, title: boot.title }),
    get theme() {
      return theme;
    },
    /** Calls `listener(theme)` whenever albedo's colours change. */
    onTheme: function (listener) {
      if (typeof listener === 'function') listeners.push(listener);
    },
    /** Posts `text` to the chat as the person; resolves to {sent, reason}. */
    send: function (text) {
      // One click or key press vouches for one message: a timer started by
      // a click stays inside the browser's activation window, but is not
      // the person asking again.
      var gesture = fresh && !!(navigator.userActivation ? navigator.userActivation.isActive : true);
      fresh = false;
      return request('ui/message', {
        role: 'user',
        content: [{ type: 'text', text: String(text) }],
        gesture: gesture
      }).then(
        function () {
          return { sent: true };
        },
        function (error) {
          return { sent: false, reason: error.message };
        }
      );
    }
  });
})();
