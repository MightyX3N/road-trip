package com.k2fsa.sherpa.onnx;

/*
 * Java versions of sherpa-onnx 1.13.8's Kotlin TTS classes (Apache-2.0, k2-fsa/sherpa-onnx).
 * libsherpa-onnx-jni.so reads these fields by name, so names and types must match that
 * release exactly; strings must never be null.
 */
public class OfflineTts {
    static { System.loadLibrary("sherpa-onnx-jni"); }

    private long ptr;

    public OfflineTts(OfflineTtsConfig config) {
        ptr = newFromFile(config);
        if (ptr == 0) throw new IllegalStateException("sherpa-onnx: couldn't load the voice");
    }

    public int sampleRate() { return getSampleRate(ptr); }

    public GeneratedAudio generate(String text, int sid, float speed) { return generateImpl(ptr, text, sid, speed); }

    public synchronized void release() {
        if (ptr != 0) { delete(ptr); ptr = 0; }
    }

    private native long newFromFile(OfflineTtsConfig config);
    private native void delete(long ptr);
    private native int getSampleRate(long ptr);
    private native GeneratedAudio generateImpl(long ptr, String text, int sid, float speed);
}
