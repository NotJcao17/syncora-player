package com.syncora.syncora_android

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import java.io.File
import java.io.FileNotFoundException

/**
 * Actualizar la app desde la app: le pasa el APK bajado al instalador del
 * sistema (el mismo que se abre al tocar un APK en el navegador).
 *
 * Se usa ACTION_VIEW y no una sesión de PackageInstaller porque así Android
 * maneja solo el permiso de "instalar apps desconocidas" la primera vez y al
 * terminar ofrece "Abrir". Android solo lo instala encima si va firmado con la
 * misma llave que la app instalada.
 */
object UpdateInstaller {
    const val MIME = "application/vnd.android.package-archive"
    private const val TAG = "SyncoraUpdate"

    fun dir(context: Context) = File(context.cacheDir, "updates")

    fun install(context: Context, path: String?): Boolean {
        val file = path?.let { File(it) } ?: return false
        if (UpdateFileProvider.resolve(context, file.name)?.canonicalPath != file.canonicalPath) {
            Log.w(TAG, "APK fuera de cache/updates")
            return false
        }
        val uri = Uri.parse("content://${context.packageName}.updates/${file.name}")
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, MIME)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo abrir el instalador: ${e.javaClass.simpleName}")
            false
        }
    }
}

/**
 * Sirve, solo de lectura, los APK de `cache/updates` al instalador del sistema.
 * No es público: el instalador lo lee con el permiso temporal que da el
 * intent (FLAG_GRANT_READ_URI_PERMISSION).
 */
class UpdateFileProvider : ContentProvider() {
    override fun onCreate() = true

    override fun getType(uri: Uri) = UpdateInstaller.MIME

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Solo lectura")
        val file = fileFor(uri) ?: throw FileNotFoundException()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val file = fileFor(uri) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = columns.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            }
        }
        return MatrixCursor(columns).apply { addRow(row) }
    }

    private fun fileFor(uri: Uri): File? {
        val ctx = context ?: return null
        val name = uri.lastPathSegment ?: return null
        return resolve(ctx, name)?.takeIf { it.isFile }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        private val NAME = Regex("^[A-Za-z0-9._-]+\\.apk$")

        /** El archivo [name] dentro de `cache/updates`, o `null` si el nombre no es válido. */
        fun resolve(context: Context, name: String): File? {
            if (!NAME.matches(name) || name.startsWith(".")) return null
            val dir = UpdateInstaller.dir(context).canonicalFile
            val file = File(dir, name).canonicalFile
            return if (file.parentFile == dir) file else null
        }
    }
}
