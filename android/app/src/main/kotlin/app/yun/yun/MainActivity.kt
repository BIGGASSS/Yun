package app.yun.yun

import com.ryanheise.audioservice.AudioServiceActivity

// Reuse audio_service's engine when opening the app from media controls.
class MainActivity : AudioServiceActivity()
