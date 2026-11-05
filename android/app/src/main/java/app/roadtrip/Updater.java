package app.roadtrip;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import androidx.core.content.FileProvider;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Checks this repo's GitHub releases for a newer Road Trip, downloads it in the background,
 * and hands it to Android's installer. Every build is release v0.1.N with versionCode N
 * (see .github/workflows/build.yml), so N is what gets compared.
 *
 * Lua starts things with check()/download()/install() and polls status(); nothing blocks
 * the render thread.
 */
final class Updater {
    private static final String TAG = "RoadTrip";
    private static final String LATEST = "https://api.github.com/repos/MightyX3N/road-trip/releases/latest";
    private static final String ASSET = "road-trip.apk";

    // idle | checking | none | available | downloading | ready | permission | error | offline
    private static volatile String state = "idle";
    private static volatile String error = "";
    private static volatile long latestCode = 0;
    private static volatile String latestName = "";
    private static volatile String latestNotes = "";
    private static volatile String apkUrl = "";
    private static volatile int progress = 0;

    private Updater() {}

    static JSONObject status(Context ctx) throws Exception {
        JSONObject o = new JSONObject();
        PackageInfo pi = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
        long current = Build.VERSION.SDK_INT >= 28 ? pi.getLongVersionCode() : pi.versionCode;
        o.put("state", state);
        o.put("error", error);
        o.put("current", current);
        o.put("currentName", pi.versionName == null ? "" : pi.versionName);
        o.put("latest", latestCode);
        o.put("latestName", latestName);
        o.put("notes", latestNotes);
        o.put("progress", progress);
        return o;
    }

    static synchronized boolean check(final Context ctx, boolean wifiOnly) {
        if (state.equals("checking") || state.equals("downloading")) return false;
        if (wifiOnly && !onWifi(ctx)) {
            state = "offline";
            return false;
        }
        state = "checking";
        final Context app = ctx.getApplicationContext();
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject rel = new JSONObject(get(LATEST));
                    String tag = rel.optString("tag_name", "");
                    Matcher m = Pattern.compile("(\\d+)$").matcher(tag);
                    long code = m.find() ? Long.parseLong(m.group(1)) : 0;
                    String url = "";
                    JSONArray assets = rel.optJSONArray("assets");
                    if (assets != null) {
                        for (int i = 0; i < assets.length(); i++) {
                            JSONObject as = assets.getJSONObject(i);
                            if (ASSET.equals(as.optString("name"))) url = as.optString("browser_download_url");
                        }
                    }
                    PackageInfo pi = app.getPackageManager().getPackageInfo(app.getPackageName(), 0);
                    long current = Build.VERSION.SDK_INT >= 28 ? pi.getLongVersionCode() : pi.versionCode;
                    latestCode = code;
                    latestName = tag.startsWith("v") ? tag.substring(1) : tag;
                    latestNotes = firstLine(rel.optString("body", ""));
                    apkUrl = url;
                    state = (code > current && !url.isEmpty()) ? "available" : "none";
                } catch (Throwable t) {
                    Log.w(TAG, "update check failed", t);
                    error = t.getClass().getSimpleName();
                    state = "error";
                }
            }
        }, "roadtrip-update-check").start();
        return true;
    }

    static synchronized boolean download(final Context ctx) {
        if (!state.equals("available") && !state.equals("error")) return false;
        if (apkUrl.isEmpty()) return false;
        state = "downloading";
        progress = 0;
        final Context app = ctx.getApplicationContext();
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    File dir = new File(app.getCacheDir(), "updates");
                    //noinspection ResultOfMethodCallIgnored
                    dir.mkdirs();
                    File tmp = new File(dir, ASSET + ".part");
                    File out = new File(dir, ASSET);
                    HttpURLConnection c = open(apkUrl);
                    long total = c.getContentLengthLong();
                    try (InputStream in = c.getInputStream(); FileOutputStream fo = new FileOutputStream(tmp)) {
                        byte[] buf = new byte[64 * 1024];
                        long done = 0;
                        int n;
                        while ((n = in.read(buf)) > 0) {
                            fo.write(buf, 0, n);
                            done += n;
                            if (total > 0) progress = (int) (done * 100 / total);
                        }
                    } finally {
                        c.disconnect();
                    }
                    //noinspection ResultOfMethodCallIgnored
                    out.delete();
                    if (!tmp.renameTo(out)) throw new Exception("rename failed");
                    progress = 100;
                    state = "ready";
                    install(app);
                } catch (Throwable t) {
                    Log.w(TAG, "update download failed", t);
                    error = t.getClass().getSimpleName();
                    state = "error";
                }
            }
        }, "roadtrip-update-download").start();
        return true;
    }

    /** Opens Android's installer for the downloaded APK, or the "install unknown apps" switch first. */
    static boolean install(Context ctx) {
        File apk = new File(new File(ctx.getCacheDir(), "updates"), ASSET);
        if (!apk.exists()) return false;
        if (Build.VERSION.SDK_INT >= 26 && !ctx.getPackageManager().canRequestPackageInstalls()) {
            state = "permission";
            Intent s = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + ctx.getPackageName()));
            s.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(s);
            return false;
        }
        state = "ready";
        Uri uri = FileProvider.getUriForFile(ctx, ctx.getPackageName() + ".updates", apk);
        Intent i = new Intent(Intent.ACTION_VIEW);
        i.setDataAndType(uri, "application/vnd.android.package-archive");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(i);
        return true;
    }

    // ---- helpers ----------------------------------------------------------------------------

    private static boolean onWifi(Context ctx) {
        ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) return false;
        NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
        return nc != null && (nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            || nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET));
    }

    private static HttpURLConnection open(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(30000);
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("User-Agent", "RoadTrip-updater"); // GitHub's API requires one
        if (url.startsWith("https://api.github.com/")) c.setRequestProperty("Accept", "application/vnd.github+json");
        int code = c.getResponseCode();
        if (code >= 300) throw new Exception("HTTP " + code);
        return c;
    }

    private static String get(String url) throws Exception {
        HttpURLConnection c = open(url);
        try (InputStream in = c.getInputStream()) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[16 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
            return b.toString("UTF-8");
        } finally {
            c.disconnect();
        }
    }

    private static String firstLine(String s) {
        s = s.trim();
        int nl = s.indexOf('\n');
        return nl < 0 ? s : s.substring(0, nl).trim();
    }
}
