package com.example.easy_video_editor.handler

import android.content.Context
import androidx.media3.common.util.UnstableApi
import com.example.easy_video_editor.command.Command
import com.example.easy_video_editor.utils.VideoUtils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class CompressVideoCommand(private val context: Context) : Command {
    @UnstableApi
    override fun execute(call: MethodCall, result: MethodChannel.Result) {
        val videoPath = call.argument<String>("videoPath")
        val targetHeight = call.argument<Number>("targetHeight")?.toInt() ?: 720 // Default to 720p

        if (videoPath == null) {
            result.error(
                "INVALID_ARGUMENTS",
                "Missing required argument: videoPath",
                null
            )
            return
        }

        // Create a new scope that's tied only to this method call
        val methodScope = CoroutineScope(Dispatchers.Main + Job())
        
        methodScope.launch {
            try {
                val outputPath = VideoUtils.compressVideo(
                    context = context,
                    videoPath = videoPath,
                    targetHeight = targetHeight
                )
                result.success(outputPath)
            } catch (e: Exception) {
                result.error("COMPRESS_ERROR", e.message, null)
            } finally {
                methodScope.cancel()
            }
        }
    }
}
