package com.syncora.syncora_android

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.view.KeyEvent

/**
 * Botones de los widgets y el aviso de "widget fijado".
 *
 * Con la app viva, los botones mandan la misma tecla multimedia que unos
 * auriculares al receptor de `audio_service`, que ya sabe qué hacer. Con la app
 * cerrada no hay reproductor que despertar sin abrir la interfaz (el motor de
 * Flutter arma el reproductor desde la UI), así que se abre la app.
 */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_PREVIOUS -> media(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            ACTION_PLAY_PAUSE -> media(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            ACTION_NEXT -> media(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            ACTION_PINNED -> pinned(context, intent)
        }
    }

    private fun media(context: Context, keyCode: Int) {
        if (!WidgetBridge.playerAlive) {
            openApp(context)
            return
        }
        // `audio_service` solo actúa con ACTION_DOWN; el UP no hace falta.
        val now = SystemClock.uptimeMillis()
        val button = Intent(Intent.ACTION_MEDIA_BUTTON)
            .setComponent(ComponentName(context.packageName, AUDIO_SERVICE_RECEIVER))
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0))
        context.sendBroadcast(button)
    }

    private fun openApp(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse("syncoraplayer://widget/player"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            context.startActivity(launch)
        } catch (e: Exception) {
            // Android puede bloquear abrir una actividad desde segundo plano.
        }
    }

    private fun pinned(context: Context, intent: Intent) {
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return
        val ref = CollectionRef(
            kind = intent.getStringExtra("kind") ?: return,
            id = intent.getStringExtra("id") ?: return,
            title = intent.getStringExtra("title") ?: "",
            subtitle = intent.getStringExtra("subtitle") ?: "",
            cover = intent.getStringExtra("cover"),
        )
        WidgetStore.saveCollection(context, widgetId, ref)
        CollectionWidget.update(context, intArrayOf(widgetId))
    }

    companion object {
        const val ACTION_PREVIOUS = "com.syncora.syncora_android.WIDGET_PREVIOUS"
        const val ACTION_PLAY_PAUSE = "com.syncora.syncora_android.WIDGET_PLAY_PAUSE"
        const val ACTION_NEXT = "com.syncora.syncora_android.WIDGET_NEXT"
        const val ACTION_PINNED = "com.syncora.syncora_android.WIDGET_PINNED"
        private const val AUDIO_SERVICE_RECEIVER = "com.ryanheise.audioservice.MediaButtonReceiver"
    }
}

/** ¿Hay reproductor vivo en este proceso? Lo marca Dart al iniciar `audio_service`. */
object WidgetBridge {
    @Volatile
    var playerAlive = false
}
