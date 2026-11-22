package com.syncora.syncora_android

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.util.concurrent.Executors

/**
 * Widget de una playlist o un álbum: portada y nombre; tocarlo abre esa
 * colección en la app. Se elige al ponerlo (pantalla [CollectionConfigActivity])
 * o desde la app con "Agregar a la pantalla de inicio".
 */
class CollectionWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        update(context, ids)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        ids.forEach { WidgetStore.removeCollection(context, it) }
    }

    companion object {
        private val io = Executors.newSingleThreadExecutor()

        fun allIds(context: Context): IntArray =
            AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, CollectionWidget::class.java))

        /**
         * La biblioteca cambió (nombre o portada): los widgets que apuntan a
         * algo de ella se actualizan; los de algo borrado se quedan como estaban
         * (tocarlos abre la app, que avisa).
         */
        fun refreshFromLibrary(context: Context, library: List<CollectionRef>) {
            val byKey = library.associateBy { it.key }
            val ids = allIds(context)
            for (id in ids) {
                val current = WidgetStore.collection(context, id) ?: continue
                val fresh = byKey[current.key] ?: continue
                if (fresh != current) WidgetStore.saveCollection(context, id, fresh)
            }
            if (ids.isNotEmpty()) update(context, ids)
        }

        fun update(context: Context, ids: IntArray) {
            val app = context.applicationContext
            val manager = AppWidgetManager.getInstance(app)
            for (id in ids) {
                val ref = WidgetStore.collection(app, id)
                // Primero lo que ya está en disco, sin red; si falta la
                // portada, se baja en segundo plano y se vuelve a pintar.
                manager.updateAppWidget(id, build(app, id, ref, ArtCache.cachedOnly(app, ref?.cover)))
                if (ref?.cover != null && ArtCache.cachedOnly(app, ref.cover) == null) {
                    io.execute {
                        val file = ArtCache.fileFor(app, ref.cover)
                        if (file != null && WidgetStore.collection(app, id) == ref) {
                            manager.updateAppWidget(id, build(app, id, ref, file))
                        }
                    }
                }
            }
        }

        private fun build(context: Context, widgetId: Int, ref: CollectionRef?, coverFile: java.io.File?): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.syncora_widget_collection)
            val density = context.resources.displayMetrics.density
            if (ref == null) {
                views.setTextViewText(R.id.syncora_col_title, context.getString(R.string.syncora_widget_pick))
                views.setTextViewText(R.id.syncora_col_subtitle, "")
                views.setImageViewResource(R.id.syncora_col_cover, R.drawable.syncora_widget_cover_placeholder)
                val configure = Intent(context, CollectionConfigActivity::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                views.setOnClickPendingIntent(
                    R.id.syncora_col_root,
                    PendingIntent.getActivity(
                        context, 20000 + widgetId, configure,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                return views
            }
            views.setTextViewText(R.id.syncora_col_title, ref.title)
            views.setTextViewText(R.id.syncora_col_subtitle, ref.subtitle)
            val cover = ArtCache.roundedSquare(coverFile, (160 * density).toInt().coerceAtMost(400), 12 * density)
            if (cover != null) {
                views.setImageViewBitmap(R.id.syncora_col_cover, cover)
            } else {
                views.setImageViewResource(R.id.syncora_col_cover, R.drawable.syncora_widget_cover_placeholder)
            }
            views.setOnClickPendingIntent(
                R.id.syncora_col_root,
                WidgetIntents.openApp(context, "syncoraplayer://widget/${ref.kind}/${ref.id}", 10000 + widgetId),
            )
            return views
        }
    }
}
