package com.example.libdivecomputer_plugin

import android.content.Context
import android.util.Log
import java.io.File

/**
 * File-based fingerprint persistence for dive computers.
 *
 * Mirrors the iOS/macOS FingerprintStore struct. Uses the app's
 * internal files directory (not SharedPreferences) since fingerprint
 * data is binary.
 *
 * Fingerprints are stored as: {filesDir}/DiveComputer/fingerprints/{serial}.fp
 */
object FingerprintStore {

    private const val TAG = "FingerprintStore"

    private fun directory(context: Context): File {
        val dir = File(context.filesDir, "DiveComputer/fingerprints")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    fun save(context: Context, serial: Long, fingerprint: ByteArray) {
        try {
            val file = File(directory(context), "$serial.fp")
            file.writeBytes(fingerprint)
            Log.i(TAG, "Saved fingerprint for serial $serial (${fingerprint.size} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save fingerprint for serial $serial", e)
        }
    }

    fun load(context: Context, serial: Long): ByteArray? {
        return try {
            val file = File(directory(context), "$serial.fp")
            if (file.exists()) file.readBytes() else null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load fingerprint for serial $serial", e)
            null
        }
    }

    fun delete(context: Context, serial: Long) {
        try {
            val file = File(directory(context), "$serial.fp")
            file.delete()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete fingerprint for serial $serial", e)
        }
    }

    fun deleteAll(context: Context) {
        try {
            val dir = directory(context)
            dir.listFiles()?.filter { it.extension == "fp" }?.forEach { it.delete() }
            Log.i(TAG, "All fingerprints deleted")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete all fingerprints", e)
        }
    }
}
