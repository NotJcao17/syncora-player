import 'package:flutter/services.dart';

class JsBundleLoader {
  static const String _polyfillCode = r'''
if (typeof globalThis === 'undefined') {
  var globalThis = this;
}

(function() {
  if (typeof globalThis === 'undefined') var globalThis = this;

  function shouldSilence(args) {
    if (!args || !args.length) return false;
    for (var i = 0; i < args.length; i++) {
      var s = String(args[i] || '');
      if (s.indexOf('[YOUTUBEJS]') !== -1 || s.indexOf('MenuConditionalServiceItem') !== -1) {
        return true;
      }
    }
    return false;
  }

  if (globalThis.console) {
    var origLog = globalThis.console.log;
    var origWarn = globalThis.console.warn;
    var origInfo = globalThis.console.info;
    var origErr = globalThis.console.error;

    globalThis.console.log = function(...args) {
      if (shouldSilence(args)) return;
      if (origLog) origLog.apply(globalThis.console, args);
      else sendMessage('consoleLog', JSON.stringify({ type: 'log', message: args.join(' ') }));
    };
    globalThis.console.warn = function(...args) {
      if (shouldSilence(args)) return;
      if (origWarn) origWarn.apply(globalThis.console, args);
      else sendMessage('consoleLog', JSON.stringify({ type: 'warn', message: args.join(' ') }));
    };
    globalThis.console.info = function(...args) {
      if (shouldSilence(args)) return;
      if (origInfo) origInfo.apply(globalThis.console, args);
      else sendMessage('consoleLog', JSON.stringify({ type: 'info', message: args.join(' ') }));
    };
    globalThis.console.error = function(...args) {
      if (shouldSilence(args)) return;
      if (origErr) origErr.apply(globalThis.console, args);
      else sendMessage('consoleLog', JSON.stringify({ type: 'error', message: args.join(' ') }));
    };
  } else {
    globalThis.console = {
      log: function(...args) {
        if (shouldSilence(args)) return;
        sendMessage('consoleLog', JSON.stringify({ type: 'log', message: args.join(' ') }));
      },
      warn: function(...args) {
        if (shouldSilence(args)) return;
        sendMessage('consoleLog', JSON.stringify({ type: 'warn', message: args.join(' ') }));
      },
      info: function(...args) {
        if (shouldSilence(args)) return;
        sendMessage('consoleLog', JSON.stringify({ type: 'info', message: args.join(' ') }));
      },
      error: function(...args) {
        if (shouldSilence(args)) return;
        sendMessage('consoleLog', JSON.stringify({ type: 'error', message: args.join(' ') }));
      }
    };
  }
})();

// Polyfill Event, CustomEvent, EventTarget
if (typeof globalThis.Event === 'undefined') {
  globalThis.Event = function Event(type, options) {
    this.type = type;
    options = options || {};
    this.bubbles = !!options.bubbles;
    this.cancelable = !!options.cancelable;
  };
}
if (typeof globalThis.CustomEvent === 'undefined') {
  globalThis.CustomEvent = function CustomEvent(type, options) {
    globalThis.Event.call(this, type, options);
    options = options || {};
    this.detail = options.detail || null;
  };
  globalThis.CustomEvent.prototype = Object.create(globalThis.Event.prototype);
  globalThis.CustomEvent.prototype.constructor = globalThis.CustomEvent;
}
if (typeof globalThis.EventTarget === 'undefined') {
  globalThis.EventTarget = function EventTarget() {
    this._listeners = {};
  };
  globalThis.EventTarget.prototype.addEventListener = function(type, listener) {
    if (!this._listeners[type]) this._listeners[type] = [];
    this._listeners[type].push(listener);
  };
  globalThis.EventTarget.prototype.removeEventListener = function(type, listener) {
    if (!this._listeners[type]) return;
    var idx = this._listeners[type].indexOf(listener);
    if (idx !== -1) this._listeners[type].splice(idx, 1);
  };
  globalThis.EventTarget.prototype.dispatchEvent = function(event) {
    if (!event.type) return true;
    var listeners = this._listeners[event.type];
    if (listeners) {
      listeners = listeners.slice();
      for (var i = 0; i < listeners.length; i++) {
        if (typeof listeners[i] === 'function') {
          listeners[i].call(this, event);
        } else if (listeners[i] && typeof listeners[i].handleEvent === 'function') {
          listeners[i].handleEvent(event);
        }
      }
    }
    return !event.defaultPrevented;
  };
}

// Polyfill AbortSignal & AbortController
if (typeof globalThis.AbortSignal === 'undefined') {
  globalThis.AbortSignal = function AbortSignal() {
    globalThis.EventTarget.call(this);
    this.aborted = false;
    this.reason = undefined;
  };
  globalThis.AbortSignal.prototype = Object.create(globalThis.EventTarget.prototype);
  globalThis.AbortSignal.prototype.constructor = globalThis.AbortSignal;
}
if (typeof globalThis.AbortController === 'undefined') {
  globalThis.AbortController = function AbortController() {
    this.signal = new globalThis.AbortSignal();
  };
  globalThis.AbortController.prototype.abort = function(reason) {
    if (this.signal.aborted) return;
    this.signal.aborted = true;
    this.signal.reason = reason;
    this.signal.dispatchEvent(new globalThis.Event('abort'));
  };
}

// Polyfill Intl (usado por youtubei.js para tz)
if (typeof globalThis.Intl === 'undefined') {
  globalThis.Intl = {
    DateTimeFormat: function() {
      return {
        resolvedOptions: function() {
          return { timeZone: 'UTC' };
        }
      };
    }
  };
}

// Polyfills ES2022 (Seguros)
if (typeof Object.hasOwn !== 'function') {
  Object.hasOwn = function(obj, prop) {
    return Object.prototype.hasOwnProperty.call(obj, prop);
  };
}
if (typeof Array.prototype.at !== 'function') {
  Array.prototype.at = function(index) {
    index = Math.trunc(index) || 0;
    if (index < 0) index += this.length;
    if (index < 0 || index >= this.length) return undefined;
    return this[index];
  };
}
if (typeof Array.prototype.findLast !== 'function') {
  Array.prototype.findLast = function(predicate, thisArg) {
    for (var i = this.length - 1; i >= 0; i--) {
      if (predicate.call(thisArg, this[i], i, this)) return this[i];
    }
    return undefined;
  };
}
if (typeof Array.prototype.findLastIndex !== 'function') {
  Array.prototype.findLastIndex = function(predicate, thisArg) {
    for (var i = this.length - 1; i >= 0; i--) {
      if (predicate.call(thisArg, this[i], i, this)) return i;
    }
    return -1;
  };
}
if (typeof String.prototype.at !== 'function') {
  String.prototype.at = function(index) {
    index = Math.trunc(index) || 0;
    if (index < 0) index += this.length;
    if (index < 0 || index >= this.length) return undefined;
    return String(this)[index];
  };
}
if (typeof String.prototype.replaceAll !== 'function') {
  String.prototype.replaceAll = function(str, newStr) {
    if (Object.prototype.toString.call(str).toLowerCase() === '[object regexp]') {
      return this.replace(str, newStr);
    }
    return this.replace(new RegExp(String(str).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), newStr);
  };
}

// Web APIs extras (FormData, File, Blob, ReadableStream)
if (typeof globalThis.FormData === 'undefined') globalThis.FormData = function FormData() {};
if (typeof globalThis.File === 'undefined') globalThis.File = function File() {};
if (typeof globalThis.Blob === 'undefined') globalThis.Blob = function Blob() {};
if (typeof globalThis.ReadableStream === 'undefined') globalThis.ReadableStream = function ReadableStream() { this.locked = false; };

// Polyfill btoa y atob
if (typeof globalThis.btoa === 'undefined') {
  var _chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  globalThis.btoa = function(input) {
    var str = String(input);
    var output = '';
    for (var block, charCode, idx = 0, map = _chars;
        str.charAt(idx | 0) || (map = '=', idx % 1);
        output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
      charCode = str.charCodeAt(idx += 3/4);
      if (charCode > 0xFF) throw new Error("'btoa' failed");
      block = block << 8 | charCode;
    }
    return output;
  };
  globalThis.atob = function(input) {
    var str = String(input).replace(/=+$/,'');
    if (str.length % 4 == 1) throw new Error("'atob' failed");
    for (var bc = 0, bs, buffer, idx = 0, output = '';
        buffer = str.charAt(idx++);
        ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer,
          bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0
    ) {
      buffer = _chars.indexOf(buffer);
    }
    return output;
  };
}

// Polyfill Crypto.getRandomValues
if (typeof globalThis.crypto === 'undefined') {
  globalThis.crypto = {
    getRandomValues: function(array) {
      if (!array) return array;
      for (var i = 0; i < array.length; i++) array[i] = Math.floor(Math.random() * 256);
      return array;
    }
  };
} else if (typeof globalThis.crypto.getRandomValues === 'undefined') {
  globalThis.crypto.getRandomValues = function(array) {
    if (!array) return array;
    for (var i = 0; i < array.length; i++) array[i] = Math.floor(Math.random() * 256);
    return array;
  };
}

// Polyfill TextEncoder / TextDecoder
if (typeof globalThis.TextEncoder === 'undefined') {
  globalThis.TextEncoder = function TextEncoder() {};
  globalThis.TextEncoder.prototype.encode = function(string) {
    var octets = [];
    var length = string ? string.length : 0;
    var i = 0;
    while (i < length) {
      var codePoint = string.codePointAt(i);
      var c = 0, bits = 0;
      if (codePoint <= 0x7f) { c = 0; bits = 0x00; }
      else if (codePoint <= 0x7ff) { c = 6; bits = 0xc0; }
      else if (codePoint <= 0xffff) { c = 12; bits = 0xe0; }
      else if (codePoint <= 0x1f9ff) { c = 18; bits = 0xf0; }
      octets.push((codePoint >> c) | bits);
      c -= 6;
      while (c >= 0) { octets.push(((codePoint >> c) & 0x3f) | 0x80); c -= 6; }
      i += codePoint >= 0x10000 ? 2 : 1;
    }
    return new Uint8Array(octets);
  };
  globalThis.TextDecoder = function TextDecoder(encoding) { this.encoding = encoding || 'utf-8'; };
  globalThis.TextDecoder.prototype.decode = function(octets) {
    if (!octets) return '';
    var bytes = octets instanceof Uint8Array ? octets : new Uint8Array(octets);
    var string = '', i = 0;
    while (i < bytes.length) {
      var octet = bytes[i], bytesNeeded = 0, codePoint = 0;
      if (octet <= 0x7f) { bytesNeeded = 0; codePoint = octet & 0xff; }
      else if ((octet & 0xe0) === 0xc0) { bytesNeeded = 1; codePoint = octet & 0x1f; }
      else if ((octet & 0xf0) === 0xe0) { bytesNeeded = 2; codePoint = octet & 0x0f; }
      else if ((octet & 0xf8) === 0xf0) { bytesNeeded = 3; codePoint = octet & 0x07; }
      if (bytes.length - i - 1 < bytesNeeded) { codePoint = 0xfffd; }
      else {
        for (var k = 0; k < bytesNeeded; k++) {
          i++; codePoint = (codePoint << 6) | (bytes[i] & 0x3f);
        }
      }
      string += String.fromCodePoint(codePoint); i++;
    }
    return string;
  };
}

// Polyfill URLSearchParams & URL
globalThis.URLSearchParams = function URLSearchParams(init) {
    this._params = new Map();
    if (typeof init === 'string') {
      if (init.startsWith('?')) init = init.slice(1);
      if (init.length > 0) {
        init.split('&').forEach(function(pair) {
          var parts = pair.split('=');
          var k = parts[0], v = parts[1];
          if (k) {
            var list = this._params.get(decodeURIComponent(k)) || [];
            list.push(v ? decodeURIComponent(v) : '');
            this._params.set(decodeURIComponent(k), list);
          }
        }.bind(this));
      }
    }
  };
  globalThis.URLSearchParams.prototype.append = function(name, value) {
    var list = this._params.get(name) || [];
    list.push(String(value));
    this._params.set(name, list);
  };
  globalThis.URLSearchParams.prototype.set = function(name, value) {
    this._params.set(name, [String(value)]);
  };
  globalThis.URLSearchParams.prototype.delete = function(name) {
    this._params.delete(name);
  };
  globalThis.URLSearchParams.prototype.get = function(name) {
    var list = this._params.get(name);
    return list ? list[0] : null;
  };
  globalThis.URLSearchParams.prototype.getAll = function(name) { return this._params.get(name) || []; };
  globalThis.URLSearchParams.prototype.has = function(name) { return this._params.has(name); };
  globalThis.URLSearchParams.prototype.toString = function() {
    var res = [];
    this._params.forEach(function(values, name) {
      values.forEach(function(v) { res.push(encodeURIComponent(name) + '=' + encodeURIComponent(v)); });
    });
    return res.join('&');
  };

globalThis.URL = function URL(url, base) {
    url = url != null ? String(url) : '';
    base = base != null ? String(base) : '';
    var fullUrl = url;
    if (base && !url.includes('://')) fullUrl = base.endsWith('/') ? base + url : base + '/' + url;
    var match = fullUrl.match(/^(https?:)\/\/([^\/?#]+)([^?#]*)\??([^#]*)#?(.*)/i);
    if (!match) {
      this.href = fullUrl; this.origin = ''; this.protocol = ''; this.host = '';
      this.pathname = fullUrl; this.search = ''; this.searchParams = new globalThis.URLSearchParams('');
      return;
    }
    this.href = fullUrl; this.protocol = match[1]; this.host = match[2];
    this.hostname = match[2].split(':')[0]; this.port = match[2].split(':')[1] || '';
    this.pathname = match[3] || '/'; this.search = match[4] ? '?' + match[4] : '';
    this.searchParams = new globalThis.URLSearchParams(match[4] || '');
    this.hash = match[5] ? '#' + match[5] : '';
    this.origin = this.protocol + '//' + this.host;
  };
globalThis.URL.prototype.toString = function() {
  var search = this.searchParams.toString();
  if (search) search = '?' + search;
  return this.origin + this.pathname + search + this.hash;
};
Object.defineProperty(globalThis.URL.prototype, 'url', {
  get: function() { return this.toString(); },
  configurable: true
});

// Polyfill Headers
if (typeof globalThis.Headers === 'undefined') {
  globalThis.Headers = function Headers(init) {
    this._map = new Map();
    if (init) {
      if (init instanceof globalThis.Headers) { init.forEach(function(v, k) { this.set(k, v); }.bind(this)); }
      else if (Array.isArray(init)) { init.forEach(function(pair) { this.append(pair[0], pair[1]); }.bind(this)); }
      else if (typeof init === 'object') { Object.keys(init).forEach(function(k) { this.set(k, init[k]); }.bind(this)); }
    }
  };
  globalThis.Headers.prototype.append = function(name, value) {
    var k = String(name).toLowerCase(), existing = this._map.get(k);
    this._map.set(k, existing ? existing + ', ' + value : String(value));
  };
  globalThis.Headers.prototype.set = function(name, value) { this._map.set(String(name).toLowerCase(), String(value)); };
  globalThis.Headers.prototype.get = function(name) {
    var v = this._map.get(String(name).toLowerCase());
    return v !== undefined ? v : null;
  };
  globalThis.Headers.prototype.has = function(name) { return this._map.has(String(name).toLowerCase()); };
  globalThis.Headers.prototype.delete = function(name) { this._map.delete(String(name).toLowerCase()); };
  globalThis.Headers.prototype.forEach = function(cb, thisArg) {
    this._map.forEach(function(v, k) { cb.call(thisArg, v, k, this); }.bind(this));
  };
}

// Polyfill Request
if (typeof globalThis.Request === 'undefined') {
  globalThis.Request = function Request(input, options) {
    options = options || {};
    this.url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
    this.method = options.method || (input && input.method) || 'GET';
    this.headers = new globalThis.Headers(options.headers || (input && input.headers));
    this.body = options.body || (input && input.body) || null;
  };
}

// Polyfill Response
if (typeof globalThis.Response === 'undefined') {
  globalThis.Response = function Response(body, options) {
    options = options || {};
    this.status = options.status || 200;
    this.statusText = options.statusText || 'OK';
    this.ok = this.status >= 200 && this.status < 300;
    this.headers = new globalThis.Headers(options.headers);
    this.url = options.url || '';
    this._bodyText = body != null ? String(body) : '';
  };
  globalThis.Response.prototype.text = function() { return Promise.resolve(this._bodyText); };
  globalThis.Response.prototype.json = function() {
    try { return Promise.resolve(JSON.parse(this._bodyText)); }
    catch(e) { return Promise.reject(e); }
  };
  globalThis.Response.prototype.arrayBuffer = function() {
    var encoder = new globalThis.TextEncoder();
    var u8 = encoder.encode(this._bodyText);
    return Promise.resolve(u8.buffer);
  };
  globalThis.Response.prototype.clone = function() {
    return new globalThis.Response(this._bodyText, {
      status: this.status,
      statusText: this.statusText,
      headers: this.headers,
      url: this.url
    });
  };
}

// Polyfill Timers
if (typeof globalThis.setTimeout === 'undefined') {
  var timerIdCounter = 0;
  var activeTimers = new Map();
  globalThis.setTimeout = function(fn, delay) {
    var id = ++timerIdCounter;
    activeTimers.set(id, fn);
    sendMessage('setTimeout', JSON.stringify({ id: id, delay: delay || 0 }));
    return id;
  };
  globalThis.clearTimeout = function(id) { activeTimers.delete(id); };
  globalThis.__fireTimeout = function(id) {
    var fn = activeTimers.get(id);
    if (fn) { activeTimers.delete(id); fn(); }
  };
}

// Polyfill Fetch Bridge
var pendingFetches = new Map();
var fetchIdCounter = 0;

globalThis.fetch = function(url, options) {
  options = options || {};
  var requestUrl = '';
  if (typeof url === 'string') {
    requestUrl = url;
  } else if (url && typeof url.url === 'string') {
    requestUrl = url.url;
  } else if (url && typeof url.href === 'string') {
    requestUrl = url.href;
  } else if (url && url instanceof globalThis.URL) {
    requestUrl = url.toString();
  } else if (url && typeof url.toString === 'function' && url.toString !== Object.prototype.toString) {
    requestUrl = url.toString();
  }

  if (url && typeof url === 'object') {
    if (!options.method && url.method) options.method = url.method;
    if (!options.headers && url.headers) options.headers = url.headers;
    if (!options.body && url.body) options.body = url.body;
  }

  var method = options.method || 'GET';
  var headersObj = {};

  if (options.headers) {
    if (options.headers instanceof globalThis.Headers) {
      options.headers.forEach(function(v, k) { headersObj[k] = v; });
    } else if (typeof options.headers === 'object') {
      headersObj = options.headers;
    }
  }

  return new Promise(function(resolve, reject) {
    var id = ++fetchIdCounter;
    pendingFetches.set(id, { resolve: resolve, reject: reject, requestUrl: requestUrl });
    sendMessage('dartFetch', JSON.stringify({
      id: id,
      url: requestUrl,
      method: method,
      headers: headersObj,
      body: options.body || null
    }));
  });
};

globalThis.__dartFetchResponse = function(id, status, statusText, headers, bodyText, error) {
  var pending = pendingFetches.get(id);
  if (!pending) return;
  pendingFetches.delete(id);
  if (error) {
    pending.reject(new Error(error));
  } else {
    var response = new globalThis.Response(bodyText, {
      status: status,
      statusText: statusText,
      headers: headers || {},
      url: pending.requestUrl
    });
    pending.resolve(response);
  }
};
''';

  /// Carga y concatena los polyfills JS con el bundle youtubei.bundle.js
  static Future<String> loadCompleteBundle() async {
    String bundleCode = '';
    try {
      bundleCode = await rootBundle.loadString('assets/js/youtubei.bundle.js');
    } catch (_) {
      bundleCode = '// Asset no encontrado o stub temporal';
    }
    const postScript = r'''
if (typeof globalThis.Innertube === 'undefined' && typeof globalThis.YouTubeJS !== 'undefined') {
  globalThis.Innertube = globalThis.YouTubeJS.Innertube || globalThis.YouTubeJS.default;
}

globalThis._ytInstances = globalThis._ytInstances || {};

if (globalThis.YouTubeJS && globalThis.YouTubeJS.Utils && globalThis.YouTubeJS.Utils.Log) {
  try { globalThis.YouTubeJS.Utils.Log.setLevel(0); } catch(_) {}
}

globalThis.resetJsEngine = function() {
  globalThis._ytInstances = {};
  console.log('[JS] Instancias de Innertube reiniciadas.');
};

globalThis.extractVideo = function(videoId, client, jsRequestId) {
  console.log('[JS] extractVideo iniciado para videoId=' + videoId + ', client=' + client + ', reqId=' + jsRequestId);
  (async function() {
    try {
      var InnertubeClass = globalThis.Innertube || (globalThis.YouTubeJS ? (globalThis.YouTubeJS.Innertube || globalThis.YouTubeJS.default) : null);
      if (!InnertubeClass) {
        console.log('[JS ERROR] Clase Innertube no encontrada.');
        sendMessage('extractionResult', JSON.stringify({
          requestId: jsRequestId,
          error: 'Clase Innertube no encontrada en el contexto JS.'
        }));
        return;
      }
      
      var yt = globalThis._ytInstances[client];
      if (!yt) {
        console.log('[JS] Creando nueva instancia Innertube para cliente: ' + client);
        yt = await InnertubeClass.create({ client_type: client, retrieve_player: false });
        globalThis._ytInstances[client] = yt;
        console.log('[JS] Instancia creada y cacheada para cliente: ' + client);
      } else {
        console.log('[JS] Usando instancia cacheada para cliente: ' + client);
      }

      console.log('[JS] Obteniendo respuesta directa de /player para: ' + videoId);
      var playerRes;
      try {
        playerRes = await yt.actions.execute('/player', { videoId: videoId });
      } catch (ePlayer) {
        console.log('[JS WARN] /player directo falló: ' + ePlayer + '. Intentando getBasicInfo...');
        try {
          var bInfo = await yt.getBasicInfo(videoId);
          playerRes = { data: bInfo.page };
        } catch (eB) {
          throw ePlayer;
        }
      }

      var playerData = (playerRes && playerRes.data) || playerRes || {};
      var streamingData = playerData.streamingData;

      if (!streamingData || (!streamingData.adaptiveFormats && !streamingData.formats)) {
        console.log('[JS WARN] streamingData no disponible en respuesta de /player.');
        throw new Error('Streaming data not available');
      }

      var formats = (streamingData.adaptiveFormats || []).concat(streamingData.formats || []);
      console.log('[JS] Formatos totales encontrados en streamingData: ' + formats.length);


      // Filtrar únicamente formatos que contengan URL directa o cipher para descifrado
      var usableFormats = formats.filter(function(f) {
        return !!(f.url || f.signatureCipher || f.cipher);
      });
      console.log('[JS] Formatos usables (con URL o Cipher): ' + usableFormats.length);

      if (usableFormats.length === 0) {
        console.log('[JS WARN] Ningún formato contiene URL o Cipher.');
        throw new Error('Streaming data not available');
      }

      // Buscar mejor formato de audio de entre los formatos usables
      var audioFormats = usableFormats.filter(function(f) {
        return f.mimeType && f.mimeType.indexOf('audio') !== -1;
      });

      if (audioFormats.length === 0) {
        audioFormats = usableFormats; // Fallback a cualquier formato usable (video+audio)
      }

      // Ordenar por bitrate descendente
      audioFormats.sort(function(a, b) {
        return (b.bitrate || 0) - (a.bitrate || 0);
      });

      var selectedFormat;
      if (client === 'ANDROID' || client === 'ANDROID_VR') {
        // ExoPlayer en Android tiene mejor compatibilidad con MP4/AAC que WebM/Opus.
        // Preferir formatos mp4 (AAC) sobre webm (Opus) para evitar errores (0) Source error.
        var mp4Formats = audioFormats.filter(function(f) {
          return f.mimeType && f.mimeType.indexOf('mp4') !== -1;
        });
        selectedFormat = mp4Formats.length > 0 ? mp4Formats[0] : audioFormats[0];
      } else {
        selectedFormat = audioFormats[0]; // WEB: mayor bitrate sin importar formato
      }
      if (!selectedFormat) {
        throw new Error('No se encontró ningún formato de audio disponible (intentó ' + client + ')');
      }

      console.log('[JS] Formato seleccionado itag=' + selectedFormat.itag + ', mimeType=' + selectedFormat.mimeType);
      console.log('[JS FORMAT JSON DUMP] ' + JSON.stringify(selectedFormat));

      var finalUrl = selectedFormat.url;
      var cipherStr = selectedFormat.signatureCipher || selectedFormat.cipher;

      if (!finalUrl && cipherStr) {
        console.log('[JS] Descifrando signatureCipher para itag ' + selectedFormat.itag + '...');
        try {
          var params = new URLSearchParams(cipherStr);
          var targetUrl = params.get('url');
          var sig = params.get('s');
          var sp = params.get('sp') || 'sig';

          if (targetUrl && sig && yt.session && yt.session.player && yt.session.player.decipher) {
            var decipheredSig = yt.session.player.decipher(sig);
            finalUrl = targetUrl + '&' + sp + '=' + encodeURIComponent(decipheredSig);
            console.log('[JS ÉXITO] Signature descifrada correctamente!');
          } else if (targetUrl && !sig) {
            finalUrl = targetUrl;
          }
        } catch (eSig) {
          console.log('[JS WARN] Error descifrando signature: ' + eSig);
        }
      }

      if (!finalUrl) {
        console.log('[JS ERROR] No se pudo determinar la URL final de reproducción.');
        sendMessage('extractionResult', JSON.stringify({
          requestId: jsRequestId,
          error: 'No se pudo obtener URL final para ' + videoId
        }));
        return;
      }

      console.log('[JS ÉXITO] URL obtenida correctamente!');
      var userAgent;
      if (client === 'ANDROID' || client === 'ANDROID_VR') {
        userAgent = 'com.google.android.youtube/19.29.37 (Linux; U; Android 11; gts7xl)';
      } else {
        userAgent = (yt.session && yt.session.context && yt.session.context.client && yt.session.context.client.userAgent) ||
                        (yt.session && yt.session.player && yt.session.player.userAgent) ||
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';
      }

      var isAndroidClient = (client === 'ANDROID' || client === 'ANDROID_VR');
      var resHeaders = isAndroidClient ? {
        'User-Agent': userAgent
      } : {
        'User-Agent': userAgent,
        'Referer': 'https://www.youtube.com/',
        'Origin': 'https://www.youtube.com'
      };

      sendMessage('extractionResult', JSON.stringify({
        requestId: jsRequestId,
        url: finalUrl,
        headers: resHeaders
      }));
      return;
    } catch(e) {
      var errStr = e ? e.toString() : 'unknown error';
      var stackStr = e && e.stack ? e.stack : '';
      console.log('[JS EXCEPCIÓN] ' + errStr + '\n' + stackStr);
      sendMessage('extractionResult', JSON.stringify({
        requestId: jsRequestId,
        error: errStr + '\n' + stackStr
      }));
    }
  })();
};

function extractVideoCandidatesFromRaw(data) {
  var results = [];
  if (!data) return results;
  try {
    var seenIds = new Map();
    function walk(node) {
      if (!node || typeof node !== 'object') return;
      var vr = node.videoRenderer || node.compactVideoRenderer;
      if (vr && vr.videoId) {
        var vId = String(vr.videoId);
        if (!seenIds.has(vId)) {
          var title = '';
          if (vr.title) {
            if (vr.title.runs && vr.title.runs[0] && vr.title.runs[0].text) title = vr.title.runs[0].text;
            else if (vr.title.simpleText) title = vr.title.simpleText;
          }

          var author = '';
          if (vr.ownerText && vr.ownerText.runs && vr.ownerText.runs[0] && vr.ownerText.runs[0].text) {
            author = vr.ownerText.runs[0].text;
          } else if (vr.shortBylineText && vr.shortBylineText.runs && vr.shortBylineText.runs[0] && vr.shortBylineText.runs[0].text) {
            author = vr.shortBylineText.runs[0].text;
          }

          var durationSec = null;
          if (vr.lengthText && vr.lengthText.simpleText) {
            var parts = String(vr.lengthText.simpleText).split(':').map(Number);
            if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
              durationSec = parts[0] * 60 + parts[1];
            } else if (parts.length === 3 && !isNaN(parts[0]) && !isNaN(parts[1]) && !isNaN(parts[2])) {
              durationSec = parts[0] * 3600 + parts[1] * 60 + parts[2];
            }
          } else if (vr.lengthSeconds) {
            durationSec = parseInt(vr.lengthSeconds, 10);
          }

          var cand = {
            videoId: vId,
            title: title,
            author: author,
            durationSec: (durationSec != null && !isNaN(durationSec)) ? durationSec : null
          };
          seenIds.set(vId, cand);
          results.push(cand);
        }
        return;
      }

      if (Array.isArray(node)) {
        for (var i = 0; i < node.length; i++) walk(node[i]);
      } else {
        var keys = Object.keys(node);
        for (var k = 0; k < keys.length; k++) {
          if (keys[k] !== 'trackingParams') walk(node[keys[k]]);
        }
      }
    }
    walk(data);
  } catch(e) {
    console.log('[JS extractVideoCandidatesFromRaw Exception] ' + e);
  }
  return results;
}

globalThis.searchVideos = function(query, client, jsRequestId) {
  console.log('[JS] searchVideos iniciado query="' + query + '", client=' + client + ', reqId=' + jsRequestId);
  (async function() {
    try {
      var InnertubeClass = globalThis.Innertube || (globalThis.YouTubeJS ? (globalThis.YouTubeJS.Innertube || globalThis.YouTubeJS.default) : null);
      if (!InnertubeClass) {
        sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, error: 'Clase Innertube no encontrada.' }));
        return;
      }
      var yt = globalThis._ytInstances[client];
      if (!yt) {
        yt = await InnertubeClass.create({ client_type: client, retrieve_player: false });
        globalThis._ytInstances[client] = yt;
      }

      var results = [];

      // Intento 1: yt.search (Parser estándar de youtubei.js)
      try {
        var search = await yt.search(query, { type: 'video' });
        var videos = (search && search.videos) ? search.videos : [];
        for (var i = 0; i < videos.length; i++) {
          var v = videos[i];
          if (v && v.id) {
            results.push({
              videoId: String(v.id),
              title: (v.title && v.title.text) ? String(v.title.text) : '',
              author: (v.author && v.author.name) ? String(v.author.name) : '',
              durationSec: (v.duration && typeof v.duration.seconds === 'number') ? v.duration.seconds : null
            });
          }
        }
      } catch (e1) {
        console.log('[JS searchVideos fallback por excepción AST] ' + (e1 ? e1.toString() : ''));
      }

      // Intento 2: Raw search vía yt.actions.execute si Intento 1 falló por error de AST / SearchHeader
      if (results.length === 0 && yt.actions && typeof yt.actions.execute === 'function') {
        try {
          var rawResponse = await yt.actions.execute('/search', { query: query });
          var rawData = (rawResponse && rawResponse.data) ? rawResponse.data : rawResponse;
          results = extractVideoCandidatesFromRaw(rawData);
        } catch (e2) {
          console.log('[JS searchVideos raw fallback excepción] ' + (e2 ? e2.toString() : ''));
        }
      }

      // Intento 3: YouTube Music search si sigue sin resultados
      if (results.length === 0 && yt.music && typeof yt.music.search === 'function') {
        try {
          var musicSearch = await yt.music.search(query, { type: 'song' });
          var songs = (musicSearch && musicSearch.songs) ? musicSearch.songs : [];
          for (var j = 0; j < songs.length; j++) {
            var s = songs[j];
            if (s && s.id) {
              results.push({
                videoId: String(s.id),
                title: (s.title && s.title.text) ? String(s.title.text) : (s.name || ''),
                author: (s.artists && s.artists[0] && s.artists[0].name) ? String(s.artists[0].name) : '',
                durationSec: (s.duration && typeof s.duration.seconds === 'number') ? s.duration.seconds : null
              });
            }
          }
        } catch (e3) {
          console.log('[JS searchVideos music fallback excepción] ' + (e3 ? e3.toString() : ''));
        }
      }

      console.log('[JS] searchVideos OK: ' + results.length + ' candidatos resueltos');
      sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, results: results }));
    } catch (e) {
      console.log('[JS searchVideos EXCEPCIÓN FINAL] ' + (e ? e.toString() : 'search error'));
      sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, error: e ? e.toString() : 'search error' }));
    }
  })();
};
''';
    return '$_polyfillCode\n\n$bundleCode\n\n$postScript';
  }

  static String get polyfillOnly => _polyfillCode;
}
