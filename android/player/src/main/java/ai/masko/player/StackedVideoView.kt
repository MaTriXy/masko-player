package ai.masko.player

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import android.view.TextureView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger

/**
 * Draws stacked video (colour above, transparency below) as transparent
 * pixels. A TextureView, so it honours alpha, transforms and z-order, with its
 * own GL thread that turns each decoded frame into colour times alpha.
 *
 * A decoder draws into an [Output]. Each load gets a fresh output, so a frame
 * drawn from an output can only belong to the clip loaded into it.
 */
internal class StackedVideoView(context: Context) : TextureView(context), TextureView.SurfaceTextureListener {

    interface Listener {
        /** The view can draw: [createOutput] works now. */
        fun onHostReady()

        /** The view's surface is going away. Detach decoders from its outputs now. */
        fun onHostLost()

        /** A frame from the output with this id is drawn and on its way to the screen. */
        fun onFrameDrawn(output: Int)
    }

    /** Where a decoder draws. */
    class Output internal constructor(val id: Int, val surface: Surface, internal val texture: SurfaceTexture, internal val textureId: Int) {
        internal val transform = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
        internal var hasFrame = false
        @Volatile internal var released = false
    }

    /** Main thread. */
    var listener: Listener? = null

    /** Whether the view can draw (main thread). */
    var hasHost = false
        private set

    private val main = Handler(Looper.getMainLooper())
    private val ids = AtomicInteger()

    // GL thread state. One thread per surface lifetime.
    private var thread: HandlerThread? = null
    private var gl: Handler? = null
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var width = 1
    private var height = 1
    private var current: Output? = null
    private val outputs = ArrayList<Output>()
    @Volatile private var videoAspect = 1f
    /** Half a texel of the decoded frame's height, in texture coordinates. */
    @Volatile private var halfTexel = 0f
    private val quad = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
        put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
        position(0)
    }

    init {
        isOpaque = false
        surfaceTextureListener = this
    }

    private val ready get() = eglSurface != EGL14.EGL_NO_SURFACE

    /**
     * Makes a fresh output and hands it over on the main thread; it becomes the
     * one this view draws. Dropped when the view has no surface.
     */
    fun createOutput(done: (Output) -> Unit) {
        val handler = gl ?: return
        handler.post {
            if (!ready) return@post
            val names = IntArray(1)
            GLES20.glGenTextures(1, names, 0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, names[0])
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            val texture = SurfaceTexture(names[0])
            val output = Output(ids.incrementAndGet(), Surface(texture), texture, names[0])
            texture.setOnFrameAvailableListener({ onFrame(output) }, handler)
            outputs += output
            current = output
            main.post {
                if (hasHost && !output.released) done(output) else release(output)
            }
        }
    }

    /** Frees an output no decoder draws into any more. */
    fun release(output: Output) {
        val handler = gl
        if (handler == null) {
            output.released = true
            return
        }
        handler.post { free(output) }
    }

    /** The decoded frame size: the stacked picture, twice as tall as the mascot. */
    fun setVideoSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        videoAspect = width.toFloat() / (height * 0.5f)
        halfTexel = 0.5f / height
        gl?.post { current?.takeIf { it.hasFrame }?.let(::present) }
    }

    // ------------------------------------------------------------------ GL thread

    private fun onFrame(output: Output) {
        if (!ready || output.released) return
        output.texture.updateTexImage()
        output.texture.getTransformMatrix(output.transform)
        output.hasFrame = true
        if (output === current) present(output)
    }

    private fun present(output: Output) {
        draw(output)
        if (EGL14.eglSwapBuffers(display, eglSurface)) {
            val id = output.id
            main.post { listener?.onFrameDrawn(id) }
        }
    }

    private fun draw(output: Output) {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        // Fit the mascot inside the view, centred.
        val ratio = videoAspect / (width.toFloat() / height.toFloat())
        GLES20.glUniform2f(GLES20.glGetUniformLocation(program, "scale"), minOf(1f, ratio), minOf(1f, 1f / ratio))
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "transform"), 1, false, output.transform, 0)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "halfTexel"), halfTexel)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, output.textureId)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "video"), 0)
        val pos = GLES20.glGetAttribLocation(program, "pos")
        GLES20.glEnableVertexAttribArray(pos)
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun free(output: Output) {
        if (output.released) return
        output.released = true
        outputs -= output
        if (current === output) current = null
        output.texture.setOnFrameAvailableListener(null)
        output.surface.release()
        output.texture.release()
        if (ready) GLES20.glDeleteTextures(1, intArrayOf(output.textureId), 0)
    }

    private fun setup(texture: SurfaceTexture): Boolean {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) return false
        val config = configs[0] ?: return false
        eglContext = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        if (eglContext == EGL14.EGL_NO_CONTEXT) return false
        eglSurface = EGL14.eglCreateWindowSurface(display, config, texture, intArrayOf(EGL14.EGL_NONE), 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) return false
        if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, eglContext)) return false
        program = buildProgram()
        return program != 0
    }

    private fun teardown() {
        outputs.toList().forEach(::free)
        if (display == EGL14.EGL_NO_DISPLAY) return
        if (program != 0 && ready) GLES20.glDeleteProgram(program)
        program = 0
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
        if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, eglContext)
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
    }

    // ------------------------------------------------------------------ the view's surface (main thread)

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        val t = HandlerThread("MaskoStackedVideo").also { it.start() }
        val handler = Handler(t.looper)
        thread = t
        gl = handler
        handler.post {
            this.width = width.coerceAtLeast(1)
            this.height = height.coerceAtLeast(1)
            if (!setup(texture)) {
                teardown()
                return@post
            }
            main.post {
                if (gl !== handler) return@post
                hasHost = true
                listener?.onHostReady()
            }
        }
    }

    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {
        gl?.post {
            this.width = width.coerceAtLeast(1)
            this.height = height.coerceAtLeast(1)
            if (ready) current?.takeIf { it.hasFrame }?.let(::present)
        }
    }

    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        hasHost = false
        // Decoders let go of the outputs before they are freed.
        listener?.onHostLost()
        val handler = gl
        val t = thread
        gl = null
        thread = null
        if (handler == null) {
            texture.release()
        } else {
            handler.post {
                teardown()
                texture.release()
                t?.quitSafely()
            }
        }
        return false
    }

    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {}

    private companion object {
        const val VERTEX = """
            attribute vec2 pos;
            uniform vec2 scale;
            varying vec2 uv;
            void main() {
              gl_Position = vec4(pos * scale, 0.0, 1.0);
              uv = (pos + 1.0) * 0.5;
            }
        """

        // Colour comes from the top half, transparency (grey) from the bottom
        // half; the output is premultiplied, as the compositor expects. Each
        // half is sampled half a texel inside its edge, so filtering never
        // mixes a row of one half into the other.
        const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
            uniform samplerExternalOES video;
            uniform mat4 transform;
            uniform float halfTexel;
            varying vec2 uv;
            void main() {
              float colourY = clamp(0.5 + uv.y * 0.5, 0.5 + halfTexel, 1.0 - halfTexel);
              float alphaY = clamp(uv.y * 0.5, halfTexel, 0.5 - halfTexel);
              vec2 colourAt = (transform * vec4(uv.x, colourY, 0.0, 1.0)).xy;
              vec2 alphaAt = (transform * vec4(uv.x, alphaY, 0.0, 1.0)).xy;
              float alpha = texture2D(video, alphaAt).r;
              vec3 colour = texture2D(video, colourAt).rgb;
              gl_FragColor = vec4(colour * alpha, alpha);
            }
        """

        fun buildProgram(): Int {
            fun shader(type: Int, code: String): Int {
                val s = GLES20.glCreateShader(type)
                GLES20.glShaderSource(s, code.trimIndent())
                GLES20.glCompileShader(s)
                val ok = IntArray(1)
                GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
                if (ok[0] == 0) {
                    GLES20.glDeleteShader(s)
                    return 0
                }
                return s
            }
            val vs = shader(GLES20.GL_VERTEX_SHADER, VERTEX)
            val fs = shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT)
            if (vs == 0 || fs == 0) return 0
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, vs)
            GLES20.glAttachShader(p, fs)
            GLES20.glLinkProgram(p)
            GLES20.glDeleteShader(vs)
            GLES20.glDeleteShader(fs)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
            if (ok[0] == 0) {
                GLES20.glDeleteProgram(p)
                return 0
            }
            return p
        }
    }
}
