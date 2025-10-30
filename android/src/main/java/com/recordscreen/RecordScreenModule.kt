package com.recordscreen

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.ContentValues
import android.media.MediaCodecList
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.SparseIntArray
import android.view.Surface
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.hbisoft.hbrecorder.HBRecorder
import com.hbisoft.hbrecorder.HBRecorderListener
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.*
import kotlin.math.ceil

class RecordScreenModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext), HBRecorderListener {

  private var hbRecorder: HBRecorder? = null
  private var screenWidth: Number = 0
  private var screenHeight: Number = 0
  private var mic: Boolean = true
  private var currentVersion: String = ""
  private var outputUri: File? = null
  private var startPromise: Promise? = null
  private var stopPromise: Promise? = null
  private var activityResultLauncher: ActivityResultLauncher<Intent>? = null

  companion object {
    private val ORIENTATIONS = SparseIntArray()
    const val SCREEN_RECORD_REQUEST_CODE = 1000

    init {
      ORIENTATIONS.append(Surface.ROTATION_0, 90)
      ORIENTATIONS.append(Surface.ROTATION_90, 0)
      ORIENTATIONS.append(Surface.ROTATION_180, 270)
      ORIENTATIONS.append(Surface.ROTATION_270, 180)
    }
  }

  override fun getName(): String {
    return "RecordScreen"
  }

  private val mActivityEventListener: ActivityEventListener = object : BaseActivityEventListener() {
    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, intent: Intent?) {
      if (requestCode == SCREEN_RECORD_REQUEST_CODE) {
        if (resultCode == AppCompatActivity.RESULT_OK && intent != null) {
          hbRecorder?.startScreenRecording(intent, resultCode)
          startPromise?.resolve("started")
        } else {
          startPromise?.resolve("permission_error")
        }
        startPromise = null
      } else {
        startPromise?.reject("404", "cancel!")
        startPromise = null
      }
    }
  }

  override fun initialize() {
    super.initialize()
    currentVersion = Build.VERSION.SDK_INT.toString()

    try {
      outputUri = reactApplicationContext.getExternalFilesDir("ReactNativeRecordScreen")
      if (outputUri == null) {
        outputUri = File(reactApplicationContext.filesDir, "ReactNativeRecordScreen")
        if (!outputUri!!.exists()) {
          outputUri!!.mkdirs()
        }
      }
    } catch (e: Exception) {
      e.printStackTrace()
    }

    // Initialize activity result launcher for newer React Native versions
    UiThreadUtil.runOnUiThread {
      val currentActivity = reactApplicationContext.currentActivity
      if (currentActivity is AppCompatActivity) {
        try {
          activityResultLauncher = currentActivity.registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
          ) { result: ActivityResult ->
            if (result.resultCode == AppCompatActivity.RESULT_OK && result.data != null) {
              hbRecorder?.startScreenRecording(result.data, result.resultCode)
              startPromise?.resolve("started")
            } else {
              startPromise?.resolve("permission_error")
            }
            startPromise = null
          }
        } catch (e: Exception) {
          e.printStackTrace()
        }
      }
    }

    reactApplicationContext.addActivityEventListener(mActivityEventListener)
  }

  override fun onCatalystInstanceDestroy() {
    super.onCatalystInstanceDestroy()
    reactApplicationContext.removeActivityEventListener(mActivityEventListener)
    hbRecorder = null
  }

  @ReactMethod
  fun setup(readableMap: ReadableMap) {
    try {
      screenWidth = if (readableMap.hasKey("width")) ceil(readableMap.getDouble("width")).toInt() else 0
      screenHeight = if (readableMap.hasKey("height")) ceil(readableMap.getDouble("height")).toInt() else 0
      mic = if (readableMap.hasKey("mic")) readableMap.getBoolean("mic") else true

      hbRecorder = HBRecorder(reactApplicationContext, this)

      outputUri?.let { uri ->
        hbRecorder?.setOutputPath(uri.toString())
      }

      // For FPS and bitrate we need to enable custom settings
      if (readableMap.hasKey("fps") || readableMap.hasKey("bitrate")) {
        hbRecorder?.enableCustomSettings()

        if (readableMap.hasKey("fps")) {
          val fps = readableMap.getInt("fps")
          hbRecorder?.setVideoFrameRate(fps)
        }
        if (readableMap.hasKey("bitrate")) {
          val bitrate = readableMap.getInt("bitrate")
          hbRecorder?.setVideoBitrate(bitrate)
        }
      }

      if (doesSupportEncoder("h264")) {
        hbRecorder?.setVideoEncoder("H264")
      } else {
        hbRecorder?.setVideoEncoder("DEFAULT")
      }
      hbRecorder?.isAudioEnabled(mic)
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  private fun startRecordingScreen() {
    try {
      val mediaProjectionManager = reactApplicationContext.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
      val permissionIntent = mediaProjectionManager.createScreenCaptureIntent()

      val currentActivity = reactApplicationContext.currentActivity
      if (currentActivity != null) {
        if (activityResultLauncher != null && currentActivity is AppCompatActivity) {
          // Use modern ActivityResultLauncher for newer versions
          activityResultLauncher?.launch(permissionIntent)
        } else {
          // Fallback to deprecated method for compatibility
          @Suppress("DEPRECATION")
          currentActivity.startActivityForResult(permissionIntent, SCREEN_RECORD_REQUEST_CODE)
        }
      } else {
        startPromise?.reject("404", "No current activity available")
        startPromise = null
      }
    } catch (e: Exception) {
      startPromise?.reject("404", "Error starting screen recording: ${e.message}")
      startPromise = null
    }
  }

  @ReactMethod
  fun startRecording(promise: Promise) {
    if (startPromise != null) {
      promise.reject("409", "Recording already in progress")
      return
    }

    startPromise = promise
    stopPromise = null

    try {
     // Create a new HBRecorder instance with a fresh listener
        hbRecorder = HBRecorder(reactApplicationContext, object : HBRecorderListener {
            override fun HBRecorderOnStart() { }
            override fun HBRecorderOnPause() { }
            override fun HBRecorderOnResume() { }
            override fun HBRecorderOnComplete() {
                stopPromise?.let { p ->
                    val uri = hbRecorder?.filePath ?: ""
                    saveVideoToGallery(uri, p)
                }
                stopPromise = null
                startPromise = null
            }
            override fun HBRecorderOnError(errorCode: Int, reason: String?) {
                val msg = reason ?: "Unknown"
                startPromise?.reject("$errorCode", msg)
                stopPromise?.reject("$errorCode", msg)
                startPromise = null
                stopPromise = null
            }
        })

        outputUri?.let { uri -> hbRecorder?.setOutputPath(uri.toString()) }
        hbRecorder?.isAudioEnabled(mic)
        if (doesSupportEncoder("h264")) {
            hbRecorder?.setVideoEncoder("H264")
        } else {
            hbRecorder?.setVideoEncoder("DEFAULT")
        }
      startRecordingScreen()
    } catch (e: IllegalStateException) {
      startPromise?.reject("404", "IllegalStateException: ${e.message}")
      startPromise = null
    } catch (e: IOException) {
      e.printStackTrace()
      startPromise?.reject("404", "IOException: ${e.message}")
      startPromise = null
    } catch (e: Exception) {
      e.printStackTrace()
      startPromise?.reject("404", "Error: ${e.message}")
      startPromise = null
    }
  }

  @ReactMethod
  fun stopRecording(promise: Promise) {
    if (stopPromise != null) {
      promise.reject("409", "Stop recording already in progress")
      return
    }

     if (hbRecorder == null) {
        promise.reject("404", "Recorder not initialized")
        return
    }

    stopPromise = promise

    UiThreadUtil.runOnUiThread {
      try {
        hbRecorder?.stopScreenRecording()
      } catch (e: Exception) {
        stopPromise?.reject("404", "Error stopping recording: ${e.message}")
        stopPromise = null
      }
    }
  }

  private fun saveVideoToGallery(filePath: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists()) {
        promise.reject("404", "Recorded file not found: $filePath")
        return
      }

      val context = reactApplicationContext
      val contentResolver = context.contentResolver

      // Generate a unique filename with timestamp
      val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(Date())
      val displayName = "ScreenRecord_$timestamp.mp4"

      val contentValues = ContentValues().apply {
        put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          put(MediaStore.Video.Media.IS_PENDING, 1)
        }
      }

      val uri = contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)

      if (uri != null) {
        val outputStream: OutputStream? = contentResolver.openOutputStream(uri)
        val inputStream = FileInputStream(file)

        outputStream?.use { output ->
          inputStream.use { input ->
            input.copyTo(output)
          }
        }

        // Mark as not pending (Android Q+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          contentValues.clear()
          contentValues.put(MediaStore.Video.Media.IS_PENDING, 0)
          contentResolver.update(uri, contentValues, null, null)
        }

        // Optional: Delete the original file from app directory
        file.delete()

        val response = WritableNativeMap()
        val result = WritableNativeMap()
        result.putString("outputURL", uri.toString())
        result.putString("galleryPath", uri.toString())
        response.putString("status", "success")
        response.putMap("result", result)
        promise.resolve(response)

      } else {
        promise.reject("404", "Failed to create gallery entry")
      }

    } catch (e: Exception) {
      promise.reject("404", "Error saving to gallery: ${e.message}")
    }
  }

  @ReactMethod
  fun clean(promise: Promise) {
    try {
      outputUri?.let { uri ->
          if (uri.exists()) {
              uri.listFiles()?.forEach { file ->
                  file.delete()
              }
          }
      }
      promise.resolve("cleaned")
    } catch (e: Exception) {
      promise.reject("404", "Error cleaning: ${e.message}")
    }
  }

  override fun HBRecorderOnStart() {
    // Recording started successfully
  }

  override fun HBRecorderOnComplete() {
    try {
      stopPromise?.let { promise ->
        val uri = hbRecorder?.filePath
        if (uri != null) {
          saveVideoToGallery(uri, promise)
        } else {
          promise.reject("404", "File path is null")
        }
      }
    } catch (e: Exception) {
      stopPromise?.reject("404", "Error on complete: ${e.message}")
    } finally {
      stopPromise = null
      startPromise = null
    }
  }

  override fun HBRecorderOnError(errorCode: Int, reason: String?) {
    val errorMessage = "Error code: $errorCode, reason: ${reason ?: "Unknown"}"

    startPromise?.let {
      it.reject("$errorCode", errorMessage)
      startPromise = null
    }

    stopPromise?.let {
      it.reject("$errorCode", errorMessage)
      stopPromise = null
    }
  }

  override fun HBRecorderOnPause() {
    // Recording paused
  }

  override fun HBRecorderOnResume() {
    // Recording resumed
  }

  private fun doesSupportEncoder(encoder: String): Boolean {
    return try {
      val list = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
      list.any { codecInfo ->
        codecInfo.isEncoder && codecInfo.name.contains(encoder, ignoreCase = true)
      }
    } catch (e: Exception) {
      false
    }
  }

}
