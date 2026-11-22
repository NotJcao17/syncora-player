package com.syncora.syncora_android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader

/**
 * Dibuja las portadas que en la app no son imágenes: degradados, colores y
 * las de "Tus me gusta" / "On Repeat" (degradado con su ícono). Formato que
 * manda Dart (`nativeCoverSpec`): `paint:AARRGGBB,AARRGGBB[;heart|;repeat]`.
 */
object CoverPainter {
    fun isSpec(source: String?) = source?.startsWith("paint:") == true

    fun draw(context: Context, spec: String, sizePx: Int, radiusPx: Float): Bitmap? {
        if (!isSpec(spec)) return null
        val body = spec.removePrefix("paint:")
        val parts = body.split(';')
        val colors = parts[0].split(',').mapNotNull { it.trim().toLongOrNull(16)?.toInt() }
        if (colors.isEmpty()) return null
        val icon = when (parts.getOrNull(1)) {
            "heart" -> R.drawable.syncora_cover_icon_heart
            "repeat" -> R.drawable.syncora_cover_icon_repeat
            else -> null
        }

        val size = sizePx.toFloat()
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        if (colors.size == 1) {
            paint.color = colors[0]
        } else {
            // Como `LinearGradient(begin: topLeft, end: bottomRight)` de Flutter.
            paint.shader = LinearGradient(0f, 0f, size, size, colors.toIntArray(), null, Shader.TileMode.CLAMP)
        }
        canvas.drawRoundRect(RectF(0f, 0f, size, size), radiusPx, radiusPx, paint)

        if (icon != null) {
            val drawable = context.getDrawable(icon) ?: return bitmap
            // Mismo tamaño que en la app: 42 % del lado.
            val iconSize = (size * 0.42f).toInt()
            val left = ((size - iconSize) / 2).toInt()
            drawable.setBounds(left, left, left + iconSize, left + iconSize)
            drawable.draw(canvas)
        }
        return bitmap
    }
}
