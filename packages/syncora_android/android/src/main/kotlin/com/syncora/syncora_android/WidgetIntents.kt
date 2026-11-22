package com.syncora.syncora_android

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri

/** PendingIntents compartidos por los widgets. */
object WidgetIntents {
    private const val FLAGS = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    /**
     * Abre la app con un enlace `syncoraplayer://widget/...` (lo recibe
     * `app_links` en `main.dart`). Se apunta a la actividad de inicio de la app,
     * sea cual sea, para no depender de su nombre.
     */
    fun openApp(context: Context, link: String, requestCode: Int): PendingIntent {
        val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent())
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse(link))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, requestCode, intent, FLAGS)
    }

    fun mediaAction(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, WidgetActionReceiver::class.java).setAction(action)
        return PendingIntent.getBroadcast(context, requestCode, intent, FLAGS)
    }
}
