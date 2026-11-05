package app.roadtrip;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Build;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.util.Log;

import com.k2fsa.sherpa.onnx.GeneratedAudio;
import com.k2fsa.sherpa.onnx.OfflineTts;
import com.k2fsa.sherpa.onnx.OfflineTtsConfig;

import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream;
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Spoken directions. Two engines:
 *  - "piper": natural voices (Piper models through sherpa-onnx), downloaded once and run on
 *    the device; Road Trip prepares the next sentence ahead so it plays on time.
 *  - "system": Android's own text-to-speech.
 * Speech ducks other audio (Road Trip's radio and other apps) while it plays.
 */
final class Voice {
    private static final String TAG = "RoadTrip";

    private static Context app;
    private static String engine = "off"; // off | system | piper
    private static String piperId = "";
    private static String systemVoice = "";
    private static String lang = "en";
    private static float rate = 1f;

    // one thread for synthesis and playback, in order
    private static final ExecutorService worker = Executors.newSingleThreadExecutor();
    private static final ExecutorService downloader = Executors.newSingleThreadExecutor();

    private static OfflineTts piper;
    private static String piperLoaded = "";
    private static String piperError = null;
    private static volatile boolean speaking = false;
    private static volatile long speakGen = 0;

    // a few prepared sentences, so a turn instruction plays right away
    private static final Map<String, GeneratedAudio> ready = new LinkedHashMap<String, GeneratedAudio>(8, 0.75f, true) {
        @Override protected boolean removeEldestEntry(Map.Entry<String, GeneratedAudio> e) { return size() > 6; }
    };

    private static TextToSpeech tts;
    private static boolean ttsReady = false;
    private static String ttsError = null;

    // downloads: voice id -> {state: downloading|extracting|error, progress, error?}
    private static final Map<String, JSONObject> downloads = new LinkedHashMap<>();

    private Voice() {}

    static File voicesDir(Context ctx) {
        File d = new File(ctx.getFilesDir(), "voices");
        //noinspection ResultOfMethodCallIgnored
        d.mkdirs();
        return d;
    }

    private static File voiceDir(String id) { return new File(voicesDir(app), id); }

    private static boolean installed(String id) {
        File d = voiceDir(id);
        return new File(d, "tokens.txt").exists() && findModel(d) != null && new File(d, "espeak-ng-data").isDirectory();
    }

    private static File findModel(File dir) {
        File[] fs = dir.listFiles();
        if (fs == null) return null;
        for (File f : fs) if (f.getName().endsWith(".onnx")) return f;
        return null;
    }

    // ------------------------------------------------------------------------------------
    // settings

    static synchronized boolean configure(Context ctx, JSONObject c) {
        app = ctx.getApplicationContext();
        engine = c.optString("engine", engine);
        piperId = c.optString("voice", piperId);
        systemVoice = c.optString("systemVoice", systemVoice);
        lang = c.optString("lang", lang);
        rate = (float) c.optDouble("rate", rate);
        if ("system".equals(engine)) startSystem();
        if ("piper".equals(engine) && !piperId.equals(piperLoaded)) {
            worker.execute(new Runnable() { @Override public void run() { loadPiper(); } });
        }
        if ("system".equals(engine) && tts != null && ttsReady) applySystemVoice();
        return true;
    }

    private static void loadPiper() {
        String id = piperId;
        if (id.isEmpty() || id.equals(piperLoaded)) return;
        if (piper != null) { piper.release(); piper = null; piperLoaded = ""; }
        synchronized (ready) { ready.clear(); }
        if (!installed(id)) { piperError = "not downloaded"; return; }
        try {
            File d = voiceDir(id);
            OfflineTtsConfig cfg = new OfflineTtsConfig();
            cfg.model.vits.model = findModel(d).getAbsolutePath();
            cfg.model.vits.tokens = new File(d, "tokens.txt").getAbsolutePath();
            cfg.model.vits.dataDir = new File(d, "espeak-ng-data").getAbsolutePath();
            cfg.model.numThreads = Math.max(1, Math.min(4, Runtime.getRuntime().availableProcessors() / 2));
            piper = new OfflineTts(cfg);
            piperLoaded = id;
            piperError = null;
            Log.i(TAG, "voice: loaded " + id);
        } catch (Throwable t) {
            piperError = String.valueOf(t.getMessage());
            Log.w(TAG, "voice: load failed", t);
        }
    }

    private static final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    private static boolean ttsStarting = false;

    // TextToSpeech is created on the main thread; its onInit arrives there too
    private static void startSystem() {
        if (tts != null || ttsStarting) return;
        ttsStarting = true;
        main.post(new Runnable() { @Override public void run() { createSystem(); } });
    }

    private static void createSystem() {
        ttsError = null;
        tts = new TextToSpeech(app, new TextToSpeech.OnInitListener() {
            @Override public void onInit(int status) {
                ttsReady = status == TextToSpeech.SUCCESS;
                if (!ttsReady) { ttsError = "Android's voice isn't available"; return; }
                tts.setAudioAttributes(attrs());
                tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                    @Override public void onStart(String id) { speaking = true; }
                    @Override public void onDone(String id) { speaking = false; abandonFocus(); }
                    @Override public void onError(String id) { speaking = false; abandonFocus(); }
                });
                applySystemVoice();
            }
        });
    }

    private static void applySystemVoice() {
        try {
            Locale loc = Locale.forLanguageTag(lang);
            int r = tts.setLanguage(loc);
            if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
                ttsError = "Android has no voice for this language";
            } else ttsError = null;
            if (!systemVoice.isEmpty() && tts.getVoices() != null) {
                for (android.speech.tts.Voice v : tts.getVoices()) {
                    if (v.getName().equals(systemVoice)) { tts.setVoice(v); break; }
                }
            }
            tts.setSpeechRate(rate);
        } catch (Throwable t) {
            ttsError = String.valueOf(t.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------
    // speaking

    private static AudioAttributes attrs() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
    }

    private static AudioFocusRequest focusReq;

    private static void requestFocus() {
        AudioManager am = (AudioManager) app.getSystemService(Context.AUDIO_SERVICE);
        if (am == null) return;
        if (Build.VERSION.SDK_INT >= 26) {
            focusReq = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attrs()).build();
            am.requestAudioFocus(focusReq);
        } else {
            //noinspection deprecation
            am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK);
        }
    }

    private static void abandonFocus() {
        AudioManager am = (AudioManager) app.getSystemService(Context.AUDIO_SERVICE);
        if (am == null) return;
        if (Build.VERSION.SDK_INT >= 26) { if (focusReq != null) am.abandonAudioFocusRequest(focusReq); }
        else {
            //noinspection deprecation
            am.abandonAudioFocus(null);
        }
    }

    static boolean speak(final String text) {
        if (app == null || text == null || text.isEmpty() || "off".equals(engine)) return false;
        if ("system".equals(engine)) {
            if (tts == null || !ttsReady) return false;
            requestFocus();
            Bundle b = new Bundle();
            tts.speak(text, TextToSpeech.QUEUE_FLUSH, b, "rt" + System.nanoTime());
            return true;
        }
        final long gen = ++speakGen; // a newer sentence replaces one that hasn't started
        worker.execute(new Runnable() {
            @Override public void run() {
                if (gen != speakGen) return;
                if (!piperId.equals(piperLoaded)) loadPiper();
                GeneratedAudio a = synth(text);
                if (a == null || gen != speakGen) return;
                play(a);
            }
        });
        return true;
    }

    /** Synthesizes sentences ahead of time (Piper only). */
    static void prepare(final JSONArray texts) {
        if (!"piper".equals(engine) || texts == null) return;
        worker.execute(new Runnable() {
            @Override public void run() {
                if (!piperId.equals(piperLoaded)) loadPiper();
                for (int i = 0; i < texts.length(); i++) synth(texts.optString(i));
            }
        });
    }

    private static GeneratedAudio synth(String text) {
        synchronized (ready) {
            GeneratedAudio a = ready.get(text);
            if (a != null) return a;
        }
        if (piper == null || text == null || text.isEmpty()) return null;
        try {
            GeneratedAudio a = piper.generate(text, 0, rate);
            if (a != null && a.samples != null) synchronized (ready) { ready.put(text, a); }
            return a;
        } catch (Throwable t) {
            piperError = String.valueOf(t.getMessage());
            return null;
        }
    }

    private static void play(GeneratedAudio a) {
        speaking = true;
        requestFocus();
        try {
            int n = a.samples.length;
            AudioTrack tr = new AudioTrack.Builder()
                .setAudioAttributes(attrs())
                .setAudioFormat(new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(a.sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(Math.max(4, n * 4))
                .build();
            tr.write(a.samples, 0, n, AudioTrack.WRITE_BLOCKING);
            tr.play();
            long ms = (long) (n * 1000L / Math.max(1, a.sampleRate)) + 150;
            Thread.sleep(ms);
            tr.stop();
            tr.release();
        } catch (Throwable t) {
            Log.w(TAG, "voice: play failed", t);
        } finally {
            speaking = false;
            abandonFocus();
        }
    }

    // ------------------------------------------------------------------------------------
    // downloading Piper voices (tar.bz2 from sherpa-onnx's model releases)

    static synchronized boolean download(Context ctx, final String id, final String url) {
        app = ctx.getApplicationContext();
        JSONObject cur = downloads.get(id);
        if (cur != null && !"error".equals(cur.optString("state"))) return true;
        final JSONObject st = new JSONObject();
        try { st.put("state", "downloading"); st.put("progress", 0); } catch (Exception ignored) {}
        downloads.put(id, st);
        downloader.execute(new Runnable() {
            @Override public void run() {
                File tmp = new File(voicesDir(app), id + ".part");
                File dest = voiceDir(id);
                File work = new File(voicesDir(app), id + ".new");
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                    c.setRequestProperty("User-Agent", Net.UA);
                    c.setConnectTimeout(20000);
                    c.setReadTimeout(30000);
                    c.setInstanceFollowRedirects(true);
                    int code = c.getResponseCode();
                    if (code / 100 != 2) throw new Exception("HTTP " + code);
                    long total = c.getContentLengthLong();
                    try (InputStream in = new BufferedInputStream(c.getInputStream()); OutputStream out = new FileOutputStream(tmp)) {
                        byte[] buf = new byte[1 << 16];
                        long got = 0;
                        int r;
                        while ((r = in.read(buf)) > 0) {
                            out.write(buf, 0, r);
                            got += r;
                            if (total > 0) set(st, "progress", (int) (got * 100 / total));
                        }
                    }
                    set(st, "state", "extracting");
                    deleteTree(work);
                    //noinspection ResultOfMethodCallIgnored
                    work.mkdirs();
                    try (InputStream fin = new BufferedInputStream(new FileInputStream(tmp));
                         TarArchiveInputStream tar = new TarArchiveInputStream(new BZip2CompressorInputStream(fin))) {
                        TarArchiveEntry e;
                        byte[] buf = new byte[1 << 16];
                        while ((e = tar.getNextTarEntry()) != null) {
                            // drop the archive's top folder; refuse paths that climb out
                            String name = e.getName();
                            int slash = name.indexOf('/');
                            name = slash >= 0 ? name.substring(slash + 1) : name;
                            if (name.isEmpty() || name.contains("..")) continue;
                            File f = new File(work, name);
                            if (e.isDirectory()) { //noinspection ResultOfMethodCallIgnored
                                f.mkdirs(); continue; }
                            //noinspection ResultOfMethodCallIgnored
                            f.getParentFile().mkdirs();
                            try (OutputStream out = new FileOutputStream(f)) {
                                int r;
                                while ((r = tar.read(buf)) > 0) out.write(buf, 0, r);
                            }
                        }
                    }
                    //noinspection ResultOfMethodCallIgnored
                    tmp.delete();
                    deleteTree(dest);
                    if (!work.renameTo(dest)) throw new Exception("couldn't move the voice into place");
                    synchronized (Voice.class) { downloads.remove(id); }
                    if ("piper".equals(engine) && id.equals(piperId)) { piperLoaded = ""; worker.execute(new Runnable() { @Override public void run() { loadPiper(); } }); }
                } catch (Throwable t) {
                    Log.w(TAG, "voice: download failed", t);
                    //noinspection ResultOfMethodCallIgnored
                    tmp.delete();
                    deleteTree(work);
                    set(st, "state", "error");
                    set(st, "error", String.valueOf(t.getMessage()));
                }
            }
        });
        return true;
    }

    private static void set(JSONObject o, String k, Object v) {
        try { synchronized (o) { o.put(k, v); } } catch (Exception ignored) {}
    }

    private static void deleteTree(File f) {
        if (f == null || !f.exists()) return;
        File[] fs = f.listFiles();
        if (fs != null) for (File c : fs) deleteTree(c);
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }

    static synchronized boolean delete(Context ctx, final String id) {
        app = ctx.getApplicationContext();
        worker.execute(new Runnable() {
            @Override public void run() {
                if (id.equals(piperLoaded) && piper != null) { piper.release(); piper = null; piperLoaded = ""; }
                deleteTree(voiceDir(id));
            }
        });
        return true;
    }

    // ------------------------------------------------------------------------------------

    static synchronized JSONObject status(Context ctx) throws Exception {
        app = ctx.getApplicationContext();
        JSONObject o = new JSONObject();
        o.put("engine", engine);
        o.put("speaking", speaking);
        o.put("loaded", piperLoaded);
        if (piperError != null) o.put("piperError", piperError);
        if (ttsError != null) o.put("systemError", ttsError);
        JSONArray inst = new JSONArray();
        File[] fs = voicesDir(app).listFiles();
        if (fs != null) for (File f : fs) if (f.isDirectory() && !f.getName().endsWith(".new") && installed(f.getName())) inst.put(f.getName());
        o.put("installed", inst);
        JSONObject dl = new JSONObject();
        for (Map.Entry<String, JSONObject> e : downloads.entrySet()) {
            synchronized (e.getValue()) { dl.put(e.getKey(), new JSONObject(e.getValue().toString())); }
        }
        o.put("downloads", dl);
        // Android's own voices for the app's language (some are online-only)
        JSONArray sys = new JSONArray();
        if (tts == null && app != null) startSystem();
        if (tts != null && ttsReady) {
            try {
                String want = Locale.forLanguageTag(lang).getLanguage();
                for (android.speech.tts.Voice v : tts.getVoices()) {
                    if (v.getLocale() == null || !want.equals(v.getLocale().getLanguage())) continue;
                    if (v.getFeatures() != null && v.getFeatures().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) continue;
                    JSONObject j = new JSONObject();
                    j.put("name", v.getName());
                    j.put("country", v.getLocale().getDisplayCountry());
                    j.put("network", v.isNetworkConnectionRequired());
                    sys.put(j);
                }
            } catch (Throwable ignored) {}
        }
        o.put("systemVoices", sys);
        o.put("systemReady", ttsReady);
        return o;
    }
}
