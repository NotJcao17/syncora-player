package com.syncora.syncora_android

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.FileNotFoundException

/**
 * Sirve portadas a Android Auto (`content://<applicationId>.art/img/<url>`,
 * `/file/<ruta>` o `/paint/<degradado>`, codificadas en base64url).
 *
 * Android Auto no carga portadas de navegación por http: exige una URI local
 * (`content://` o `android.resource://`). Es público porque lo lee el proceso
 * de Android Auto; por eso solo acepta hosts de portadas conocidos y archivos
 * dentro de los datos de la app (ver [ArtCache]).
 */
class CoverArtProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") throw SecurityException("Solo lectura")
        val context = context ?: throw FileNotFoundException()
        val segments = uri.pathSegments
        if (segments.size != 2) throw FileNotFoundException(uri.toString())
        val source = ArtCache.decodeSegment(segments[1]) ?: throw FileNotFoundException(uri.toString())
        val file = when (segments[0]) {
            "img" -> if (source.startsWith("http")) ArtCache.fileFor(context, source) else null
            "file" -> if (source.startsWith("/")) ArtCache.fileFor(context, source) else null
            "paint" -> ArtCache.paintedFile(context, source)
            else -> null
        } ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = "image/*"

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
