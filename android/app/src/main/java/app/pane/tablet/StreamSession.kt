package app.pane.tablet

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/** A cursor image with its hotspot and size as fractions of the Mac display. */
internal class CursorImage(val bitmap: Bitmap, val hotX: Float, val hotY: Float, val width: Float, val height: Float)

/**
 * Two sockets through the USB tunnel: video on [port], pointer on [port] + 1.
 * Every write goes through one sender thread. Android does not allow socket writes
 * on the main thread, and touch events arrive there.
 */
internal class StreamSession(
    private val port: Int,
    private val deviceName: String,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val refreshHz: Int,
    private val capabilities: Int,
    private val densityDpi: Int,
    private val onState: (String) -> Unit,
    private val onVideoSize: (width: Int, height: Int, fps: Int) -> Unit,
    private val onFirstFrame: () -> Unit,
    private val onClosed: (String?) -> Unit,
    private val onRemoteCursor: (Float, Float, Boolean) -> Unit,
    private val onCursorImage: (CursorImage) -> Unit,
    private val connectTimeoutMs: Int = 4000
) {
    @Volatile private var socket: Socket? = null
    @Volatile private var cursorSocket: Socket? = null
    @Volatile private var audioSocket: Socket? = null
    @Volatile private var running = false
    private var output: OutputStream? = null
    private var cursorOutput: OutputStream? = null
    private var askedForKeyframe = false

    private val senderThread = HandlerThread("pane-send").also { it.start() }
    private val sender = Handler(senderThread.looper)

    val decoder = H264Decoder(
        onFirstFrame = onFirstFrame,
        onError = { message -> onState(message) },
        onNeedKeyframe = { post(Protocol.keyframeRequest(), control = false) }
    )

    fun start() {
        running = true
        thread(name = "pane-socket") {
            try {
                onState("Connecting over the USB cable…")
                val video = Socket()
                video.tcpNoDelay = true
                video.keepAlive = true
                video.receiveBufferSize = 2 * 1024 * 1024
                video.trafficClass = 0x10
                socket = video
                video.connect(loopback(port), connectTimeoutMs)
                val pointer = Socket()
                cursorSocket = pointer
                pointer.tcpNoDelay = true
                pointer.connect(loopback(port + 1), connectTimeoutMs)
                if (!running) {
                    closeQuietly(video)
                    closeQuietly(pointer)
                    return@thread
                }
                sender.post {
                    output = video.getOutputStream()
                    cursorOutput = pointer.getOutputStream()
                }
                post(helloPacket(), control = false)
                startCursorReader(pointer)
                startAudio()
                onState("Connected. Waiting for the picture…")
                val input = java.io.DataInputStream(java.io.BufferedInputStream(video.getInputStream(), 512 * 1024))
                while (running) {
                    val message = FrameParser.read(input) ?: break
                    handle(message)
                }
                if (running) onClosed("The Mac closed the connection.")
            } catch (error: Exception) {
                if (running) onClosed(error.message ?: "Could not connect.")
            }
        }
    }

    fun attachSurface(surface: Surface?) {
        decoder.setSurface(surface)
    }

    fun sendPointer(phase: Int, tool: Int, pointerId: Int, x: Float, y: Float, pressure: Float) {
        post(Protocol.pointer(phase, tool, pointerId, x, y, pressure), control = true)
    }

    fun sendScroll(dx: Float, dy: Float, phase: Int) {
        post(Protocol.scroll(dx, dy, phase), control = true)
    }

    fun sendPinch(phase: Int, magnification: Float, x: Float, y: Float) {
        post(Protocol.pinch(phase, magnification, x, y), control = true)
    }

    fun close() {
        running = false
        val video = socket
        val pointer = cursorSocket
        socket = null
        cursorSocket = null
        closeQuietly(audioSocket)
        audioSocket = null
        sender.post {
            write(output, Protocol.goodbye())
            closeQuietly(video)
            closeQuietly(pointer)
            output = null
            cursorOutput = null
        }
        senderThread.quitSafely()
        decoder.release()
    }

    private fun startCursorReader(pointer: Socket) {
        thread(name = "pane-cursor") {
            try {
                val parser = FrameParser()
                val input = pointer.getInputStream()
                val chunk = ByteArray(64 * 1024)
                while (running) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    if (read == 0) continue
                    // Same delayed-ACK stall as audio: cursor packets are small, so answer each read.
                    post(Protocol.ack(), control = true)
                    for (message in parser.append(chunk.copyOf(read))) {
                        when (message) {
                            is Inbound.CursorPosition -> onRemoteCursor(message.x, message.y, message.visible)
                            is Inbound.CursorShape -> {
                                val bitmap = BitmapFactory.decodeByteArray(message.png, 0, message.png.size) ?: continue
                                onCursorImage(CursorImage(bitmap, message.hotX, message.hotY, message.width, message.height))
                            }
                            else -> Unit
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    /** Sound on its own socket, port + 2. Missing audio never stops the picture, so failures are ignored. */
    private fun startAudio() {
        thread(name = "pane-audio") {
            val player = AudioPlayer()
            try {
                val audio = Socket()
                audioSocket = audio
                audio.tcpNoDelay = true
                audio.connect(loopback(port + 2), connectTimeoutMs)
                if (!running) return@thread
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
                val input = java.io.DataInputStream(java.io.BufferedInputStream(audio.getInputStream(), 64 * 1024))
                val reply = audio.getOutputStream()
                while (running) {
                    when (val message = FrameParser.read(input) ?: break) {
                        is Inbound.AudioFormat -> player.configure(message.sampleRate, message.channels)
                        is Inbound.Audio -> {
                            player.write(message.pcm)
                            // adbd forwards to this socket with Nagle on. Without traffic back, the ACK waits for
                            // the 40 ms delayed-ACK timer and holds the next packet that long. A reply carries it at once.
                            reply.write(ACK_BYTE)
                        }
                        else -> Unit
                    }
                }
            } catch (_: Exception) {
            } finally {
                player.release()
            }
        }
    }

    private fun handle(message: Inbound) {
        when (message) {
            is Inbound.HelloAck -> {
                decoder.setDimensions(message.width, message.height)
                onVideoSize(message.width, message.height, message.fps)
                if (!askedForKeyframe) {
                    askedForKeyframe = true
                    post(Protocol.keyframeRequest(), control = false)
                }
            }
            is Inbound.Video -> {
                TabletStats.arrived(message.annexB.size)
                decoder.submit(message.annexB, message.keyframe)
            }
            else -> Unit
        }
    }

    /** Pointer and scroll go on the pointer socket so they never wait behind video. */
    private fun post(packet: ByteArray, control: Boolean) {
        sender.post {
            val target = if (control) cursorOutput ?: output else output
            write(target, packet)
        }
    }

    private fun write(target: OutputStream?, packet: ByteArray) {
        if (target == null) return
        try {
            target.write(packet)
            target.flush()
        } catch (_: Exception) {
        }
    }

    private fun closeQuietly(socket: Socket?) {
        try {
            socket?.close()
        } catch (_: Exception) {
        }
    }

    private fun loopback(port: Int): InetSocketAddress {
        return InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port)
    }

    private companion object {
        const val ACK_BYTE = 0
    }

    private fun helloPacket(): ByteArray {
        return Protocol.hello(deviceName, screenWidth, screenHeight, refreshHz, capabilities, densityDpi)
    }
}
