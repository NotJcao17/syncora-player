package com.syncora.syncora_android

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.LruCache
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import java.util.concurrent.Executors

/**
 * "¿Qué abre este widget?": lista de playlists y álbumes de la biblioteca.
 *
 * La lista la publica la app (Dart) cada vez que cambia la biblioteca, así que
 * esta pantalla no necesita abrir la base de datos ni arrancar Flutter.
 */
class CollectionConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private val thumbs = LruCache<String, Bitmap>(60)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        widgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // Salir sin elegir no deja un widget vacío puesto.
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        window.statusBarColor = BG
        window.navigationBarColor = BG

        val items = WidgetStore.library(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(BG)
            setPadding(0, dp(24), 0, 0)
        }
        root.addView(TextView(this).apply {
            text = getString(R.string.syncora_widget_pick_title)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(20), dp(16), dp(20), dp(12))
        })
        if (items.isEmpty()) {
            root.addView(TextView(this).apply {
                text = getString(R.string.syncora_widget_pick_empty)
                setTextColor(SECONDARY)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                setPadding(dp(20), dp(8), dp(20), dp(8))
            })
        } else {
            root.addView(ListView(this).apply {
                divider = null
                selector.alpha = 40
                adapter = Adapter(items)
                setOnItemClickListener { _, _, position, _ -> pick(items[position]) }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)
    }

    override fun onDestroy() {
        io.shutdownNow()
        super.onDestroy()
    }

    private fun pick(ref: CollectionRef) {
        WidgetStore.saveCollection(this, widgetId, ref)
        CollectionWidget.update(this, intArrayOf(widgetId))
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private inner class Adapter(val items: List<CollectionRef>) : BaseAdapter() {
        override fun getCount() = items.size
        override fun getItem(position: Int) = items[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? LinearLayout) ?: newRow()
            val ref = items[position]
            val image = row.getChildAt(0) as ImageView
            val texts = row.getChildAt(1) as LinearLayout
            (texts.getChildAt(0) as TextView).text = ref.title
            (texts.getChildAt(1) as TextView).text = ref.subtitle
            image.tag = ref.cover
            val cached = ref.cover?.let { thumbs.get(it) }
            if (cached != null) {
                image.setImageBitmap(cached)
            } else {
                image.setImageResource(R.drawable.syncora_widget_cover_placeholder)
                val cover = ref.cover
                if (cover != null) {
                    io.execute {
                        val bitmap = ArtCache.bitmapFor(this@CollectionConfigActivity, cover, dp(52), dp(6).toFloat(), network = true)
                            ?: return@execute
                        thumbs.put(cover, bitmap)
                        main.post { if (image.tag == cover) image.setImageBitmap(bitmap) }
                    }
                }
            }
            return row
        }

        private fun newRow(): LinearLayout = LinearLayout(this@CollectionConfigActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(8), dp(20), dp(8))
            addView(ImageView(context), LinearLayout.LayoutParams(dp(52), dp(52)))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(14), 0, 0, 0)
                addView(TextView(context).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                })
                addView(TextView(context).apply {
                    setTextColor(SECONDARY)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                })
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    companion object {
        private val BG = Color.parseColor("#181C27")
        private val SECONDARY = Color.parseColor("#A0A8B8")
    }
}
