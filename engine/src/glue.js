
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

globalThis.extractVideo = function(videoId, client, jsRequestId, quality) {
  quality = quality || 'high';
  console.log('[JS] extractVideo iniciado para videoId=' + videoId + ', client=' + client + ', reqId=' + jsRequestId + ', quality=' + quality);
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

      var targetFormats = audioFormats.slice();
      if (client === 'ANDROID' || client === 'ANDROID_VR') {
        // ExoPlayer en Android tiene mejor compatibilidad con MP4/AAC que WebM/Opus.
        var mp4Formats = audioFormats.filter(function(f) {
          return f.mimeType && f.mimeType.indexOf('mp4') !== -1;
        });
        if (mp4Formats.length > 0) {
          targetFormats = mp4Formats;
        }
      }

      var selectedFormat;
      if (quality === 'low') {
        // Baja (~64-96 kbps / Ahorro): formato más cercano a 70 kbps
        targetFormats.sort(function(a, b) {
          var diffA = Math.abs((a.bitrate || 0) - 70000);
          var diffB = Math.abs((b.bitrate || 0) - 70000);
          return diffA - diffB;
        });
        selectedFormat = targetFormats[0];
      } else if (quality === 'medium') {
        // Normal (~128 kbps): formato más cercano a 128 kbps
        targetFormats.sort(function(a, b) {
          var diffA = Math.abs((a.bitrate || 0) - 128000);
          var diffB = Math.abs((b.bitrate || 0) - 128000);
          return diffA - diffB;
        });
        selectedFormat = targetFormats[0];
      } else {
        // Alta (~160-256 kbps / máxima disponible): ordenar por mayor bitrate
        targetFormats.sort(function(a, b) {
          return (b.bitrate || 0) - (a.bitrate || 0);
        });
        selectedFormat = targetFormats[0];
      }

      if (!selectedFormat) {
        throw new Error('No se encontró ningún formato de audio disponible (intentó ' + client + ')');
      }

      console.log('[JS] Formato seleccionado itag=' + selectedFormat.itag + ', mimeType=' + selectedFormat.mimeType + ', bitrate=' + selectedFormat.bitrate + ' (calidad ' + quality + ')');
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

// Extrae las filas de canciones de una respuesta de yt.music.search.
//
// NO usa el getter `.songs` de youtubei.js: ese getter busca el estante cuyo
// titulo sea exactamente la cadena inglesa "Songs", y YouTube Music localiza
// ese titulo segun el `hl` de la sesion -- que youtubei.js toma del propio
// ytcfg de YouTube, es decir, de la IP del usuario. Medido contra la API en
// vivo: hl=en devuelve "Songs" y hl=es/MX devuelve "Canciones". Con cualquier
// idioma que no sea ingles el getter devuelve undefined y esta via se quedaba
// SIN CANDIDATOS en silencio.
//
// Como la busqueda ya va filtrada por `type: 'song'`, todos los estantes de la
// respuesta son de canciones: recorrerlos todos es correcto ademas de
// independiente del idioma.
globalThis.extractMusicSongRows = function(musicSearch) {
  var rows = [];
  if (!musicSearch) return rows;

  var shelf = musicSearch.songs;
  if (shelf) {
    if (Array.isArray(shelf)) return shelf.slice();
    if (Array.isArray(shelf.contents)) return shelf.contents.slice();
  }

  var sections = musicSearch.contents;
  if (!Array.isArray(sections)) return rows;
  for (var i = 0; i < sections.length; i++) {
    var section = sections[i];
    if (section && Array.isArray(section.contents)) {
      for (var j = 0; j < section.contents.length; j++) rows.push(section.contents[j]);
    }
  }
  return rows;
};

// Normaliza una fila de YouTube Music al mismo shape que usa la busqueda de
// videos. `parseSong` de youtubei.js rellena title/artists/duration/album para
// las pistas auto-generadas del sello (musicVideoType ATV), que son
// exactamente las que nos interesan.
globalThis.musicRowToCandidate = function(s) {
  if (!s || !s.id) return null;

  var title = '';
  if (s.title && s.title.text) title = String(s.title.text);
  else if (typeof s.title === 'string') title = s.title;
  else if (s.name) title = String(s.name);

  var author = '';
  if (s.artists && s.artists[0] && s.artists[0].name) author = String(s.artists[0].name);
  else if (s.author && s.author.name) author = String(s.author.name);

  return {
    videoId: String(s.id),
    title: title,
    author: author,
    durationSec: (s.duration && typeof s.duration.seconds === 'number') ? s.duration.seconds : null,
    // Marca de procedencia: el shelf de canciones de YouTube Music son masters
    // oficiales por construccion, nunca re-subidas ni karaokes.
    // `YtSearchMatcher` lo puntua igual que un canal "- Topic"/VEVO -- y hace
    // falta la marca porque aqui el autor llega como nombre de artista, sin el
    // sufijo "- Topic".
    source: 'ytmusic'
  };
};

// `mode`: 'music' consulta SOLO el catalogo de YouTube Music; cualquier otro
// valor mantiene la busqueda de videos de siempre.
globalThis.searchVideos = function(query, client, jsRequestId, mode) {
  console.log('[JS] searchVideos iniciado query="' + query + '", client=' + client + ', mode=' + (mode || 'video') + ', reqId=' + jsRequestId);
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

      // Modo dedicado a YouTube Music: se usa como PRIMER intento de la
      // escalera (ver `extraction_isolate.dart`). Devuelve solo masters
      // oficiales, asi que evita de raiz los karaokes/instrumentales
      // re-subidos con titulo de marketing.
      if (mode === 'music') {
        if (!yt.music || typeof yt.music.search !== 'function') {
          console.log('[JS] searchVideos: este cliente no expone yt.music');
          sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, results: [] }));
          return;
        }
        try {
          var mSearch = await yt.music.search(query, { type: 'song' });
          var mRows = globalThis.extractMusicSongRows(mSearch);
          var mSeen = {};
          for (var mi = 0; mi < mRows.length; mi++) {
            var cand = globalThis.musicRowToCandidate(mRows[mi]);
            if (!cand || mSeen[cand.videoId]) continue;
            mSeen[cand.videoId] = true;
            results.push(cand);
          }
          console.log('[JS] searchVideos (music): ' + results.length + ' candidatos');
        } catch (em) {
          console.log('[JS searchVideos music excepción] ' + (em ? em.toString() : ''));
        }
        sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, results: results }));
        return;
      }

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

      // Intento 3: YouTube Music como red de rescate dentro de la busqueda de
      // videos, cuando esta devolvio pocos candidatos.
      //
      // Sigue existiendo aunque la escalera ya consulte YouTube Music primero
      // (`mode: 'music'`): esta rama tambien corre para las queries de la
      // escalera que el paso de musica NO cubre (el hint "official audio", el
      // cliente ANDROID y el titulo pelado). El dedup por videoId de
      // `extraction_isolate.dart` evita que aporte duplicados.
      if (results.length < 8 && yt.music && typeof yt.music.search === 'function') {
        try {
          var seenMusic = {};
          for (var q = 0; q < results.length; q++) seenMusic[results[q].videoId] = true;

          var musicSearch = await yt.music.search(query, { type: 'song' });
          var songs = globalThis.extractMusicSongRows(musicSearch);

          var addedFromMusic = 0;
          for (var j = 0; j < songs.length; j++) {
            var cand2 = globalThis.musicRowToCandidate(songs[j]);
            if (!cand2 || seenMusic[cand2.videoId]) continue;
            seenMusic[cand2.videoId] = true;
            results.push(cand2);
            addedFromMusic++;
          }
          if (addedFromMusic > 0) {
            console.log('[JS] searchVideos: +' + addedFromMusic + ' candidatos desde YouTube Music');
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
