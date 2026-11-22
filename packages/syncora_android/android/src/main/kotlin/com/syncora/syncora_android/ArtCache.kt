package com.syncora.syncora_android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.util.Base64
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Portadas en disco para Android Auto y los widgets.
 *
 * Android Auto solo dibuja portadas con URIs locales y los widgets necesitan un
 * Bitmap: las dos cosas salen de aquí. Las URLs se bajan una vez a la caché de
 * la app; las rutas locales solo se sirven si están dentro de los datos de la
 * app (el proveedor es público para que Android Auto pueda leerlo).
 */
object ArtCache {
    private const val MAX_BYTES = 8L * 1024 * 1024

    /** Hosts de los que sale una portada de Syncora. */
    private val allowedHostSuffixes = listOf(
        "dzcdn.net", "deezer.com", "ytimg.com", "ggpht.com", "googleusercontent.com",
    )

    fun isAllowedUrl(url: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme != "https" && uri.scheme != "http") return false
        val host = uri.host?.lowercase() ?: return false
        if (host.startsWith("syncora-images.") && host.endsWith(".workers.dev")) return true
        return allowedHostSuffixes.any { host == it || host.endsWith(".$it") }
    }

    /** `content://<auth>/img/<base64url>` o `/file/<base64url>` -> fuente. */
    fun decodeSegment(encoded: String): String? = try {
        String(Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP), Charsets.UTF_8)
    } catch (e: IllegalArgumentException) {
        null
    }

    /**
     * Archivo local para [source] (URL o ruta). Descarga si hace falta, así que
     * nunca se llama desde el hilo principal. `null` si no se puede.
     */
    fun fileFor(context: Context, source: String?): File? {
        if (source.isNullOrBlank()) return null
        if (source.startsWith("/")) return localFile(context, source)
        if (source.startsWith("file://")) return Uri.parse(source).path?.let { localFile(context, it) }
        if (!isAllowedUrl(source)) return null
        val target = cachedFile(context, source)
        if (target.exists() && target.length() > 0) return target
        return download(source, target)
    }

    /** Solo lo que ya está en disco (para pintar sin red desde el hilo principal). */
    fun cachedOnly(context: Context, source: String?): File? {
        if (source.isNullOrBlank()) return null
        if (source.startsWith("/") || source.startsWith("file://")) return fileFor(context, source)
        val target = cachedFile(context, source)
        return if (target.exists() && target.length() > 0) target else null
    }

    private fun localFile(context: Context, path: String): File? {
        val file = File(path)
        if (!file.isFile) return null
        val canonical = file.canonicalPath
        val roots = listOfNotNull(
            context.applicationInfo.dataDir,
            context.getExternalFilesDir(null)?.parentFile?.canonicalPath,
        ).map { File(it).canonicalPath }
        return if (roots.any { canonical.startsWith("$it/") }) file else null
    }

    private fun cachedFile(context: Context, url: String): File {
        val dir = File(context.cacheDir, "syncora_art").apply { mkdirs() }
        val digest = MessageDigest.getInstance("SHA-1").digest(url.toByteArray())
        return File(dir, digest.joinToString("") { "%02x".format(it) })
    }

    private fun download(url: String, target: File): File? {
        var connection: HttpURLConnection? = null
        val tmp = File(target.parentFile, target.name + ".tmp")
        return try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 8000
                readTimeout = 10000
                instanceFollowRedirects = true
            }
            if (connection.responseCode !in 200..299) return null
            if (connection.contentType?.startsWith("image/") == false) return null
            var total = 0L
            connection.inputStream.use { input ->
                tmp.outputStream().use { out ->
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > MAX_BYTES) return null
                        out.write(buffer, 0, n)
                    }
                }
            }
            if (tmp.renameTo(target)) target else null
        } catch (e: Exception) {
            null
        } finally {
            connection?.disconnect()
            if (tmp.exists()) tmp.delete()
        }
    }

    /**
     * Bitmap cuadrado de [sizePx] con esquinas redondeadas. Los widgets tienen
     * un tope de memoria para imágenes: una portada de 1000 px puede hacer que
     * no se pinten, así que se decodifica ya reducida.
     */
    fun roundedSquare(file: File?, sizePx: Int, radiusPx: Float): Bitmap? {
        if (file == null) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= sizePx) sample *= 2
            val source = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            val side = minOf(source.width, source.height)
            val square = Bitmap.createBitmap(source, (source.width - side) / 2, (source.height - side) / 2, side, side)
            val scaled = Bitmap.createScaledBitmap(square, sizePx, sizePx, true)
            val output = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            }
            Canvas(output).drawRoundRect(RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat()), radiusPx, radiusPx, paint)
            output
        } catch (e: Throwable) {
            null
        }
    }
}
