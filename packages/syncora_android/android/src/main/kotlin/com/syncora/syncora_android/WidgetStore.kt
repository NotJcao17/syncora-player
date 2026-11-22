package com.syncora.syncora_android

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Lo que pinta "Reproduciendo". Lo escribe Dart solo cuando algo cambia. */
data class NowPlaying(
    val hasTrack: Boolean,
    val title: String,
    val artist: String,
    val coverPath: String?,
    val playing: Boolean,
)

/** Una playlist o álbum que un widget puede abrir. */
data class CollectionRef(
    val kind: String, // "playlist" | "album"
    val id: String,
    val title: String,
    val subtitle: String,
    val cover: String?,
) {
    val key get() = "$kind:$id"

    fun toJson(): JSONObject = JSONObject()
        .put("kind", kind).put("id", id).put("title", title).put("subtitle", subtitle).put("cover", cover ?: "")

    companion object {
        fun fromJson(o: JSONObject): CollectionRef? {
            val kind = o.optString("kind")
            val id = o.optString("id")
            if (kind.isEmpty() || id.isEmpty()) return null
            return CollectionRef(
                kind = kind,
                id = id,
                title = o.optString("title"),
                subtitle = o.optString("subtitle"),
                cover = o.optString("cover").ifEmpty { null },
            )
        }

        fun fromMap(map: Map<*, *>): CollectionRef? = fromJson(JSONObject(map))
    }
}

/** Estado persistido de los widgets (sobrevive a que Android mate la app). */
object WidgetStore {
    private const val FILE = "syncora_widgets"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun saveNowPlaying(context: Context, np: NowPlaying) {
        prefs(context).edit()
            .putBoolean("np_has_track", np.hasTrack)
            .putString("np_title", np.title)
            .putString("np_artist", np.artist)
            .putString("np_cover", np.coverPath)
            .putBoolean("np_playing", np.playing)
            .apply()
    }

    fun nowPlaying(context: Context): NowPlaying {
        val p = prefs(context)
        return NowPlaying(
            hasTrack = p.getBoolean("np_has_track", false),
            title = p.getString("np_title", null) ?: "",
            artist = p.getString("np_artist", null) ?: "",
            coverPath = p.getString("np_cover", null),
            playing = p.getBoolean("np_playing", false),
        )
    }

    fun saveLibrary(context: Context, items: List<CollectionRef>) {
        val array = JSONArray()
        items.forEach { array.put(it.toJson()) }
        prefs(context).edit().putString("library", array.toString()).apply()
    }

    fun library(context: Context): List<CollectionRef> {
        val raw = prefs(context).getString("library", null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { CollectionRef.fromJson(array.getJSONObject(it)) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun saveCollection(context: Context, widgetId: Int, ref: CollectionRef) {
        prefs(context).edit().putString("collection_$widgetId", ref.toJson().toString()).apply()
    }

    fun collection(context: Context, widgetId: Int): CollectionRef? {
        val raw = prefs(context).getString("collection_$widgetId", null) ?: return null
        return try {
            CollectionRef.fromJson(JSONObject(raw))
        } catch (e: Exception) {
            null
        }
    }

    fun removeCollection(context: Context, widgetId: Int) {
        prefs(context).edit().remove("collection_$widgetId").apply()
    }
}
