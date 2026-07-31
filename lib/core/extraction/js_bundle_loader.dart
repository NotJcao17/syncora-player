import 'package:flutter/services.dart';

class JsBundleLoader {
  static const String _polyfillCode = '''
if (typeof globalThis === 'undefined') {
  var globalThis = this;
}

// Polyfill Console
globalThis.console = globalThis.console || {
  log: function(...args) { sendMessage('consoleLog', JSON.stringify({ type: 'log', message: args.join(' ') })); },
  error: function(...args) { sendMessage('consoleLog', JSON.stringify({ type: 'error', message: args.join(' ') })); },
  warn: function(...args) { sendMessage('consoleLog', JSON.stringify({ type: 'warn', message: args.join(' ') })); },
  info: function(...args) { sendMessage('consoleLog', JSON.stringify({ type: 'info', message: args.join(' ') })); }
};

// Polyfill TextEncoder / TextDecoder
if (typeof globalThis.TextEncoder === 'undefined') {
  globalThis.TextEncoder = function TextEncoder() {};
  globalThis.TextEncoder.prototype.encode = function(string) {
    var octets = [];
    var length = string ? string.length : 0;
    var i = 0;
    while (i < length) {
      var codePoint = string.codePointAt(i);
      var c = 0;
      var bits = 0;
      if (codePoint <= 0x7f) {
        c = 0; bits = 0x00;
      } else if (codePoint <= 0x7ff) {
        c = 6; bits = 0xc0;
      } else if (codePoint <= 0xffff) {
        c = 12; bits = 0xe0;
      } else if (codePoint <= 0x1f9ff) {
        c = 18; bits = 0xf0;
      }
      octets.push((codePoint >> c) | bits);
      c -= 6;
      while (c >= 0) {
        octets.push(((codePoint >> c) & 0x3f) | 0x80);
        c -= 6;
      }
      i += codePoint >= 0x10000 ? 2 : 1;
    }
    return new Uint8Array(octets);
  };

  globalThis.TextDecoder = function TextDecoder(encoding) {
    this.encoding = encoding || 'utf-8';
  };
  globalThis.TextDecoder.prototype.decode = function(octets) {
    if (!octets) return '';
    var bytes = octets instanceof Uint8Array ? octets : new Uint8Array(octets);
    var string = '';
    var i = 0;
    while (i < bytes.length) {
      var octet = bytes[i];
      var bytesNeeded = 0;
      var codePoint = 0;
      if (octet <= 0x7f) {
        bytesNeeded = 0; codePoint = octet & 0xff;
      } else if ((octet & 0xe0) === 0xc0) {
        bytesNeeded = 1; codePoint = octet & 0x1f;
      } else if ((octet & 0xf0) === 0xe0) {
        bytesNeeded = 2; codePoint = octet & 0x0f;
      } else if ((octet & 0xf8) === 0xf0) {
        bytesNeeded = 3; codePoint = octet & 0x07;
      }
      if (bytes.length - i - 1 < bytesNeeded) {
        codePoint = 0xfffd;
      } else {
        for (var k = 0; k < bytesNeeded; k++) {
          i++;
          codePoint = (codePoint << 6) | (bytes[i] & 0x3f);
        }
      }
      string += String.fromCodePoint(codePoint);
      i++;
    }
    return string;
  };
}

// Polyfill URLSearchParams & URL
if (typeof globalThis.URLSearchParams === 'undefined') {
  globalThis.URLSearchParams = function URLSearchParams(init) {
    this._params = new Map();
    if (typeof init === 'string') {
      if (init.startsWith('?')) init = init.slice(1);
      if (init.length > 0) {
        init.split('&').forEach(function(pair) {
          var parts = pair.split('=');
          var k = parts[0];
          var v = parts[1];
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
  globalThis.URLSearchParams.prototype.get = function(name) {
    var list = this._params.get(name);
    return list ? list[0] : null;
  };
  globalThis.URLSearchParams.prototype.toString = function() {
    var res = [];
    this._params.forEach(function(values, name) {
      values.forEach(function(v) {
        res.push(encodeURIComponent(name) + '=' + encodeURIComponent(v));
      });
    });
    return res.join('&');
  };
}

if (typeof globalThis.URL === 'undefined') {
  globalThis.URL = function URL(url, base) {
    var fullUrl = url;
    if (base && !url.includes('://')) {
      fullUrl = base.endsWith('/') ? base + url : base + '/' + url;
    }
    var match = fullUrl.match(/^(https?:)\\/\\/([^\\/?#]+)([^?#]*)\\??([^#]*)#?(.*)/i);
    if (!match) {
      this.href = fullUrl;
      this.origin = '';
      this.protocol = '';
      this.host = '';
      this.pathname = fullUrl;
      this.search = '';
      this.searchParams = new globalThis.URLSearchParams('');
      return;
    }
    this.href = fullUrl;
    this.protocol = match[1];
    this.host = match[2];
    this.hostname = match[2].split(':')[0];
    this.port = match[2].split(':')[1] || '';
    this.pathname = match[3] || '/';
    this.search = match[4] ? '?' + match[4] : '';
    this.searchParams = new globalThis.URLSearchParams(match[4] || '');
    this.hash = match[5] ? '#' + match[5] : '';
    this.origin = this.protocol + '//' + this.host;
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

  globalThis.clearTimeout = function(id) {
    activeTimers.delete(id);
  };

  globalThis.__fireTimeout = function(id) {
    var fn = activeTimers.get(id);
    if (fn) {
      activeTimers.delete(id);
      fn();
    }
  };
}

// Polyfill Fetch Bridge
var pendingFetches = new Map();
var fetchIdCounter = 0;

globalThis.fetch = function(url, options) {
  options = options || {};
  return new Promise(function(resolve, reject) {
    var id = ++fetchIdCounter;
    pendingFetches.set(id, { resolve: resolve, reject: reject });
    sendMessage('dartFetch', JSON.stringify({
      id: id,
      url: url ? url.toString() : '',
      method: options.method || 'GET',
      headers: options.headers || {},
      body: options.body || null
    }));
  });
};

globalThis.__dartFetchResponse = function(id, status, statusText, headersJson, bodyText, error) {
  var pending = pendingFetches.get(id);
  if (!pending) return;
  pendingFetches.delete(id);
  if (error) {
    pending.reject(new Error(error));
  } else {
    var parsedHeaders = JSON.parse(headersJson || '{}');
    pending.resolve({
      ok: status >= 200 && status < 300,
      status: status,
      statusText: statusText || 'OK',
      headers: {
        get: function(name) { return parsedHeaders[name.toLowerCase()] || null; },
        forEach: function(cb) {
          Object.keys(parsedHeaders).forEach(function(k) { cb(parsedHeaders[k], k); });
        }
      },
      text: function() { return Promise.resolve(bodyText); },
      json: function() { return Promise.resolve(JSON.parse(bodyText)); }
    });
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
    return '$_polyfillCode\n\n$bundleCode';
  }

  static String get polyfillOnly => _polyfillCode;
}
