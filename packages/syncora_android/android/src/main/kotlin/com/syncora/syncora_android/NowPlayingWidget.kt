package com.syncora.syncora_android

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import java.io.File

/**
 * Widget "Reproduciendo": portada a un lado; título, artista y
 * anterior / reproducir-pausar / siguiente al otro.
 *
 * Dos diseños: barra (4x1) y con la portada grande (4x2 o más alto). Solo se
 * repinta cuando Dart avisa de un cambio de pista o de play/pausa (nunca la
 * posición: batería, ronda 10).
 */
class NowPlayingWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        render(context, manager, intArrayOf(id))
    }

    companion object {
        private const val REQ_OPEN = 100
        private const val REQ_PREV = 101
        private const val REQ_PLAY = 102
        private const val REQ_NEXT = 103

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, NowPlayingWidget::class.java))
            if (ids.isNotEmpty()) render(context, manager, ids)
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val np = WidgetStore.nowPlaying(context)
            val density = context.resources.displayMetrics.density
            val coverFile = np.coverPath?.let { File(it) }?.takeIf { np.hasTrack && it.isFile }
            val cover = ArtCache.roundedSquare(coverFile, (128 * density).toInt().coerceAtMost(320), 10 * density)
            for (id in ids) {
                val views = if (Build.VERSION.SDK_INT >= 31) {
                    RemoteViews(
                        mapOf(
                            SizeF(180f, 40f) to build(context, R.layout.syncora_widget_now_playing_compact, np, cover),
                            SizeF(180f, 100f) to build(context, R.layout.syncora_widget_now_playing_large, np, cover),
                        ),
                    )
                } else {
                    val minHeight = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
                    val layout = if (minHeight >= 100) {
                        R.layout.syncora_widget_now_playing_large
                    } else {
                        R.layout.syncora_widget_now_playing_compact
                    }
                    build(context, layout, np, cover)
                }
                manager.updateAppWidget(id, views)
            }
        }

        private fun build(context: Context, layout: Int, np: NowPlaying, cover: Bitmap?): RemoteViews {
            val views = RemoteViews(context.packageName, layout)
            if (np.hasTrack) {
                views.setTextViewText(R.id.syncora_np_title, np.title)
                views.setTextViewText(R.id.syncora_np_artist, np.artist)
            } else {
                views.setTextViewText(R.id.syncora_np_title, context.getString(R.string.syncora_widget_idle_title))
                views.setTextViewText(R.id.syncora_np_artist, context.getString(R.string.syncora_widget_idle_subtitle))
            }
            if (cover != null) {
                views.setImageViewBitmap(R.id.syncora_np_cover, cover)
            } else {
                views.setImageViewResource(R.id.syncora_np_cover, R.drawable.syncora_widget_cover_placeholder)
            }
            views.setImageViewResource(
                R.id.syncora_np_play,
                if (np.playing) R.drawable.syncora_widget_pause else R.drawable.syncora_widget_play,
            )
            views.setContentDescription(R.id.syncora_np_play, if (np.playing) "Pausar" else "Reproducir")
            views.setOnClickPendingIntent(R.id.syncora_np_root, WidgetIntents.openApp(context, "syncoraplayer://widget/player", REQ_OPEN))
            views.setOnClickPendingIntent(R.id.syncora_np_prev, WidgetIntents.mediaAction(context, WidgetActionReceiver.ACTION_PREVIOUS, REQ_PREV))
            views.setOnClickPendingIntent(R.id.syncora_np_play, WidgetIntents.mediaAction(context, WidgetActionReceiver.ACTION_PLAY_PAUSE, REQ_PLAY))
            views.setOnClickPendingIntent(R.id.syncora_np_next, WidgetIntents.mediaAction(context, WidgetActionReceiver.ACTION_NEXT, REQ_NEXT))
            return views
        }
    }
}
