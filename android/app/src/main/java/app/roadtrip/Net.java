package app.roadtrip;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Background HTTPS GETs for Lua: get() returns an id at once, result(id) says whether it's
 * done and hands back the body. Keeps network waits off LÖVE's render thread.
 */
final class Net {
    private static final Map<Integer, JSONObject> RESULTS = new ConcurrentHashMap<>();
    private static final AtomicInteger NEXT = new AtomicInteger(1);

    private Net() {}

    static int get(final String url) throws Exception {
        if (!url.startsWith("https://")) throw new Exception("https only");
        final int id = NEXT.getAndIncrement();
        RESULTS.put(id, new JSONObject().put("done", false));
        new Thread(new Runnable() {
            @Override
            public void run() {
                JSONObject r = new JSONObject();
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(20000);
                    c.setRequestProperty("User-Agent", UA);
                    int code = c.getResponseCode();
                    InputStream in = code < 400 ? c.getInputStream() : c.getErrorStream();
                    ByteArrayOutputStream b = new ByteArrayOutputStream();
                    if (in != null) {
                        byte[] buf = new byte[16 * 1024];
                        int n;
                        while ((n = in.read(buf)) > 0 && b.size() < 2_000_000) b.write(buf, 0, n);
                        in.close();
                    }
                    c.disconnect();
                    r.put("done", true);
                    r.put("ok", code < 400);
                    r.put("status", code);
                    r.put("body", b.toString("UTF-8"));
                } catch (Throwable t) {
                    try {
                        r.put("done", true);
                        r.put("ok", false);
                        r.put("error", t.getClass().getSimpleName());
                    } catch (Throwable ignored) {
                        // nothing more to say
                    }
                }
                RESULTS.put(id, r);
            }
        }, "roadtrip-net").start();
        return id;
    }

    // FOSSGIS, Photon and OpenFreeMap ask for an app name that says who's calling
    static final String UA = "RoadTrip/0.1 (+https://mightyx3n.github.io/road-trip/)";

    /** Downloads url to an absolute file path (written via a temp file); result(id) reports it. */
    static int download(final String url, final String path) throws Exception {
        if (!url.startsWith("https://")) throw new Exception("https only");
        final int id = NEXT.getAndIncrement();
        RESULTS.put(id, new JSONObject().put("done", false));
        new Thread(new Runnable() {
            @Override
            public void run() {
                JSONObject r = new JSONObject();
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(30000);
                    c.setRequestProperty("User-Agent", UA);
                    int code = c.getResponseCode();
                    if (code >= 400) throw new Exception("HTTP " + code);
                    java.io.File out = new java.io.File(path);
                    java.io.File dir = out.getParentFile();
                    //noinspection ResultOfMethodCallIgnored
                    if (dir != null) dir.mkdirs();
                    java.io.File tmp = new java.io.File(path + ".part");
                    try (InputStream in = c.getInputStream(); java.io.FileOutputStream fo = new java.io.FileOutputStream(tmp)) {
                        byte[] buf = new byte[32 * 1024];
                        int n;
                        while ((n = in.read(buf)) > 0) fo.write(buf, 0, n);
                    } finally {
                        c.disconnect();
                    }
                    if (!tmp.renameTo(out)) throw new Exception("rename failed");
                    r.put("done", true).put("ok", true).put("status", code);
                } catch (Throwable t) {
                    try {
                        r.put("done", true).put("ok", false).put("error", t.getMessage() == null ? t.getClass().getSimpleName() : t.getMessage());
                    } catch (Throwable ignored) {
                        // nothing more to say
                    }
                }
                RESULTS.put(id, r);
            }
        }, "roadtrip-dl").start();
        return id;
    }

    static JSONObject result(int id) throws Exception {
        JSONObject r = RESULTS.get(id);
        if (r == null) return new JSONObject().put("done", true).put("ok", false).put("error", "unknown request");
        if (r.optBoolean("done")) RESULTS.remove(id);
        return r;
    }
}
