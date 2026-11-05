package app.roadtrip;

import android.content.Context;
import android.os.StatFs;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Downloads one offline map area: a list of tiles ("z/x/y") into dir/z/x/y.pbf. OpenFreeMap
 * allows offline areas of at most 3,000 tiles or 50 MB each, with at most 4 requests at once
 * and an app name in the User-Agent; this keeps to that. Files already there are skipped, so
 * running it again finishes what's missing.
 */
final class MapDownload {
    static final int MAX_TILES = 3000;
    static final long MAX_BYTES = 50L * 1024 * 1024;
    private static final int THREADS = 4;

    private static volatile String state = "idle"; // idle | running | done | cancelled | limit | error
    private static volatile String id = "", error = null;
    private static volatile boolean cancel = false;
    private static final AtomicInteger done = new AtomicInteger(), failed = new AtomicInteger();
    private static final AtomicLong bytes = new AtomicLong();
    private static volatile int total = 0;

    private MapDownload() {}

    static synchronized boolean start(final String areaId, final String template, final JSONArray tiles, final String dir) {
        if ("running".equals(state)) return false;
        if (tiles.length() > MAX_TILES) { state = "error"; error = "too many tiles"; return false; }
        id = areaId;
        state = "running";
        error = null;
        cancel = false;
        done.set(0);
        failed.set(0);
        bytes.set(0);
        total = tiles.length();
        final AtomicInteger next = new AtomicInteger(0);
        final AtomicInteger running = new AtomicInteger(THREADS);
        for (int t = 0; t < THREADS; t++) {
            new Thread(new Runnable() {
                @Override public void run() {
                    try {
                        int i;
                        while (!cancel && (i = next.getAndIncrement()) < tiles.length()) {
                            String zxy = tiles.optString(i);
                            File out = new File(dir, zxy + ".pbf");
                            if (out.exists() && out.length() > 0) {
                                bytes.addAndGet(out.length());
                            } else if (!fetch(template, zxy, out)) {
                                failed.incrementAndGet();
                            }
                            done.incrementAndGet();
                            if (bytes.get() > MAX_BYTES) { state = "limit"; cancel = true; }
                        }
                    } finally {
                        if (running.decrementAndGet() == 0 && "running".equals(state)) {
                            state = cancel ? "cancelled" : "done";
                        }
                    }
                }
            }, "roadtrip-map-dl").start();
        }
        return true;
    }

    // one tile, two tries
    private static boolean fetch(String template, String zxy, File out) {
        String[] p = zxy.split("/");
        if (p.length != 3) return false;
        String url = template.replace("{z}", p[0]).replace("{x}", p[1]).replace("{y}", p[2]);
        for (int attempt = 0; attempt < 2 && !cancel; attempt++) {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(15000);
                c.setReadTimeout(30000);
                c.setRequestProperty("User-Agent", Net.UA);
                int code = c.getResponseCode();
                if (code == 204 || code == 404) { // nothing there (open sea): an empty tile
                    write(out, new byte[0], 0);
                    return true;
                }
                if (code >= 400) throw new Exception("HTTP " + code);
                byte[] buf = new byte[32 * 1024];
                java.io.ByteArrayOutputStream b = new java.io.ByteArrayOutputStream();
                try (InputStream in = c.getInputStream()) {
                    int n;
                    while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
                }
                write(out, b.toByteArray(), b.size());
                bytes.addAndGet(b.size());
                return true;
            } catch (Throwable t) {
                error = t.getMessage() == null ? t.getClass().getSimpleName() : t.getMessage();
                try { Thread.sleep(1500); } catch (InterruptedException ignored) { return false; }
            } finally {
                if (c != null) c.disconnect();
            }
        }
        return false;
    }

    private static void write(File out, byte[] data, int n) throws Exception {
        File parent = out.getParentFile();
        //noinspection ResultOfMethodCallIgnored
        if (parent != null) parent.mkdirs();
        File tmp = new File(out.getPath() + ".part");
        try (FileOutputStream fo = new FileOutputStream(tmp)) { fo.write(data, 0, n); }
        if (!tmp.renameTo(out)) throw new Exception("rename failed");
    }

    static boolean cancel() { cancel = true; return true; }

    static JSONObject status() throws Exception {
        JSONObject o = new JSONObject().put("state", state).put("id", id).put("done", done.get())
            .put("total", total).put("failed", failed.get()).put("bytes", bytes.get());
        if (error != null) o.put("error", error);
        return o;
    }

    /** Bytes free where Road Trip keeps its files. */
    static long free(Context ctx) {
        try { return new StatFs(ctx.getFilesDir().getPath()).getAvailableBytes(); } catch (Throwable t) { return -1; }
    }

    /** Size of a folder, in bytes (a downloaded area). */
    static long size(File f) {
        if (f == null || !f.exists()) return 0;
        if (f.isFile()) return f.length();
        long n = 0;
        File[] list = f.listFiles();
        if (list != null) for (File c : list) n += size(c);
        return n;
    }

    /** Deletes a folder inside Road Trip's own storage (nowhere else). */
    static boolean deleteTree(Context ctx, String path) {
        try {
            File f = new File(path).getCanonicalFile();
            String home = new File(ctx.getApplicationInfo().dataDir).getCanonicalPath();
            if (!f.getPath().startsWith(home + File.separator)) return false;
            final File target = f;
            new Thread(new Runnable() { @Override public void run() { delete(target); } }, "roadtrip-rm").start();
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private static void delete(File f) {
        File[] list = f.listFiles();
        if (list != null) for (File c : list) delete(c);
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }
}
