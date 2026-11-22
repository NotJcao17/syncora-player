package com.syncora.syncora_android

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Puente con Dart para los widgets de la pantalla de inicio.
 *
 * Las portadas de Android Auto no pasan por aquí: las sirve [CoverArtProvider]
 * directamente a partir de la URI que arma Dart.
 */
class SyncoraAndroidPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "syncora_android")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "playerReady" -> {
                WidgetBridge.playerAlive = true
                result.success(null)
            }
            "updateNowPlaying" -> {
                WidgetStore.saveNowPlaying(
                    context,
                    NowPlaying(
                        hasTrack = call.argument<Boolean>("hasTrack") ?: false,
                        title = call.argument<String>("title") ?: "",
                        artist = call.argument<String>("artist") ?: "",
                        coverPath = call.argument<String>("coverPath"),
                        playing = call.argument<Boolean>("playing") ?: false,
                    ),
                )
                NowPlayingWidget.updateAll(context)
                result.success(null)
            }
            "publishLibrary" -> {
                val raw = call.argument<List<Map<*, *>>>("items") ?: emptyList()
                val items = raw.mapNotNull { CollectionRef.fromMap(it) }
                WidgetStore.saveLibrary(context, items)
                CollectionWidget.refreshFromLibrary(context, items)
                result.success(null)
            }
            "isPinSupported" -> result.success(pinSupported())
            "pinCollection" -> {
                val ref = call.arguments<Map<*, *>>()?.let { CollectionRef.fromMap(it) }
                result.success(ref != null && pin(ref))
            }
            "installApk" -> result.success(UpdateInstaller.install(context, call.argument<String>("path")))
            else -> result.notImplemented()
        }
    }

    private fun pinSupported(): Boolean =
        Build.VERSION.SDK_INT >= 26 && AppWidgetManager.getInstance(context).isRequestPinAppWidgetSupported

    /**
     * Pide al launcher que ponga un widget de [ref]. El launcher no abre la
     * pantalla de elegir para widgets fijados desde la app: avisa con el id del
     * widget nuevo a [WidgetActionReceiver], que guarda qué abre.
     */
    private fun pin(ref: CollectionRef): Boolean {
        if (!pinSupported()) return false
        val callback = Intent(context, WidgetActionReceiver::class.java)
            .setAction(WidgetActionReceiver.ACTION_PINNED)
            .putExtra("kind", ref.kind)
            .putExtra("id", ref.id)
            .putExtra("title", ref.title)
            .putExtra("subtitle", ref.subtitle)
            .putExtra("cover", ref.cover)
        // MUTABLE: el launcher agrega EXTRA_APPWIDGET_ID al enviarlo.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val pending = PendingIntent.getBroadcast(context, ref.key.hashCode(), callback, flags)
        return AppWidgetManager.getInstance(context)
            .requestPinAppWidget(ComponentName(context, CollectionWidget::class.java), null, pending)
    }
}
