package app.roadtrip;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.Keep;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.util.List;

/**
 * Everything Lua calls goes through call(context, method, argsJson) and gets back
 * {"ok":true,"data":...} or {"ok":false,"error":"..."} as an ASCII-only JSON string.
 * Lua reaches this class over JNI (see android.lua), using the activity's class loader.
 */
@Keep
public final class LauncherBridge {
    private static final String TAG = "RoadTrip";

    private LauncherBridge() {}

    @Keep
    public static String call(Context ctx, String method, String argsJson) {
        try {
            JSONObject a = (argsJson == null || argsJson.isEmpty()) ? new JSONObject() : new JSONObject(argsJson);
            Object data;
            switch (method) {
                case "getApps":
                    data = getAppsCached(ctx, a.optString("iconDir", null), a.optInt("iconSize", 192), a.optInt("known", -1));
                    break;
                case "launch":
                    data = launch(ctx, a.getString("pkg"), a.optString("activity", null));
                    break;
                case "isDefaultHome":
                    data = isDefaultHome(ctx);
                    break;
                case "openHomeSettings":
                    data = openHomeSettings(ctx);
                    break;
                case "openAppInfo": {
                    String pkg = a.getString("pkg");
                    data = openAppInfo(ctx, "self".equals(pkg) ? ctx.getPackageName() : pkg);
                    break;
                }
                case "voice":
                    data = voice(ctx);
                    break;
                case "guardStatus":
                    data = guardStatus(ctx);
                    break;
                case "setGuardEnabled":
                    ctx.getSharedPreferences(GuardService.PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean(GuardService.KEY_ENABLED, a.getBoolean("on"))
                        .putLong(GuardService.KEY_PAUSE_UNTIL, 0).apply();
                    data = true;
                    break;
                case "openStockLauncher":
                    data = openStockLauncher(ctx, a.optLong("pauseMs", 120_000));
                    break;
                case "mediaStatus":
                    data = MediaListener.status(ctx, a.optString("artDir", null));
                    break;
                case "mediaCommand":
                    data = MediaListener.command(ctx, a.getString("action"), a.optLong("posMs", 0));
                    break;
                case "fetch":
                    data = Net.get(a.getString("url"));
                    break;
                case "download":
                    data = Net.download(a.getString("url"), a.getString("path"));
                    break;
                case "locationStart":
                    data = LocationBridge.start(ctx);
                    break;
                case "location":
                    data = LocationBridge.status(ctx);
                    break;
                case "radioPlay":
                    data = RadioService.play(ctx, a.getJSONObject("station"));
                    break;
                case "radioCommand":
                    data = RadioService.command(ctx, a.getString("what"));
                    break;
                case "radioStatus":
                    data = RadioService.status();
                    break;
                case "radioList":
                    RadioService.setList(a.optJSONArray("list"));
                    data = true;
                    break;
                case "httpRequest":
                    data = Net.request(a.optString("method", "GET"), a.getString("url"), a.optJSONObject("headers"),
                        a.has("body") ? a.optString("body") : null);
                    break;
                case "musicPlay":
                    data = MusicService.play(ctx, a.optJSONArray("tracks"), a.optInt("index", 0));
                    break;
                case "musicCommand":
                    data = MusicService.command(ctx, a.getString("what"), a.optLong("posMs", 0));
                    break;
                case "musicStatus":
                    data = MusicService.status();
                    break;
                case "panelShow":
                    data = Panel.show((android.app.Activity) ctx, a.getString("kind"), a.getInt("x"), a.getInt("y"), a.getInt("w"), a.getInt("h"));
                    break;
                case "panelHide":
                    data = Panel.hide();
                    break;
                case "panelLabels":
                    Panel.setLabels(a.optJSONObject("labels"));
                    data = true;
                    break;
                case "webCommand":
                    data = Panel.webCommand(a.getString("what"), a.optString("url", ""));
                    break;
                case "webStatus":
                    data = Panel.webStatus();
                    break;
                case "videoPlay":
                    data = Panel.videoPlay((android.app.Activity) ctx, a.getString("url"), a.optLong("startMs", 0));
                    break;
                case "videoCommand":
                    data = Panel.videoCommand(a.getString("what"), a.optLong("posMs", 0));
                    break;
                case "videoStatus":
                    data = Panel.videoStatus();
                    break;
                case "voiceConfig":
                    data = Voice.configure(ctx, a);
                    break;
                case "voiceSpeak":
                    data = Voice.speak(a.optString("text"));
                    break;
                case "voicePrepare":
                    Voice.prepare(a.optJSONArray("texts"));
                    data = true;
                    break;
                case "voiceStatus":
                    data = Voice.status(ctx);
                    break;
                case "voiceDownload":
                    data = Voice.download(ctx, a.getString("id"), a.getString("url"));
                    break;
                case "voiceDelete":
                    data = Voice.delete(ctx, a.getString("id"));
                    break;
                case "overlayConfig":
                    Overlay.configure(ctx, a);
                    data = true;
                    break;
                case "overlayNav":
                    Overlay.setNav(a.optJSONObject("nav"));
                    data = true;
                    break;
                case "resumed":
                    data = Overlay.roadTripResumed;
                    break;
                case "overlayStatus":
                    data = Overlay.status(ctx);
                    break;
                case "overlayPermission":
                    data = Overlay.openOverlaySettings(ctx);
                    break;
                case "uptime":
                    data = android.os.SystemClock.elapsedRealtime();
                    break;
                case "language":
                    data = java.util.Locale.getDefault().getLanguage();
                    break;
                case "country":
                    data = java.util.Locale.getDefault().getCountry();
                    break;
                case "fetchResult":
                    data = Net.result(a.getInt("id"));
                    break;
                case "calendar":
                    data = CalendarBridge.upcoming(ctx);
                    break;
                case "calendarAllow":
                    data = CalendarBridge.request(ctx);
                    break;
                case "calendarOpen":
                    data = CalendarBridge.open(ctx, a.optLong("at", System.currentTimeMillis()));
                    break;
                case "diagnostics": {
                    JSONObject d = new JSONObject();
                    d.put("guard", GuardService.logJson());
                    d.put("nav", MediaListener.navLogJson());
                    Intent home = new Intent(Intent.ACTION_MAIN);
                    home.addCategory(Intent.CATEGORY_HOME);
                    ResolveInfo ri = ctx.getPackageManager().resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY);
                    d.put("defaultHome", ri == null || ri.activityInfo == null ? "none"
                        : ri.activityInfo.packageName + "/" + ri.activityInfo.name);
                    JSONArray watched = new JSONArray();
                    for (String s : GuardService.otherHomeActivities(ctx)) watched.put(s);
                    d.put("watched", watched);
                    d.put("location", LocationBridge.providers(ctx));
                    d.put("radio", RadioService.status());
                    d.put("overlay", Overlay.status(ctx));
                    data = d;
                    break;
                }
                case "navStatus":
                    data = MediaListener.navStatus(ctx, a.optString("dir", null));
                    break;
                case "openMediaAccess":
                    data = MediaListener.openAccess(ctx);
                    break;
                case "homePresses":
                    data = RoadTripActivity.homePresses;
                    break;
                case "updateStatus":
                    data = Updater.status(ctx);
                    break;
                case "updateCheck":
                    data = Updater.check(ctx, a.optBoolean("wifiOnly", true));
                    break;
                case "updateDownload":
                    data = Updater.download(ctx);
                    break;
                case "updateInstall":
                    data = Updater.install(ctx);
                    break;
                case "openAccessibilitySettings":
                    data = openSettings(ctx, Settings.ACTION_ACCESSIBILITY_SETTINGS);
                    break;
                default:
                    return fail("unknown method: " + method);
            }
            JSONObject out = new JSONObject();
            out.put("ok", true);
            out.put("data", data == null ? JSONObject.NULL : data);
            return ascii(out.toString());
        } catch (Throwable t) {
            Log.e(TAG, "bridge " + method, t);
            return fail(t.toString());
        }
    }

    // ---- apps -------------------------------------------------------------------------------

    // The app list is rebuilt only when Android says a package changed; otherwise Lua gets
    // "unchanged" back at once, so returning to Road Trip doesn't re-read every app.
    private static volatile int appsVersion = 1;
    private static int cachedVersion = 0;
    private static JSONArray cachedApps;
    private static boolean receiverOn = false;

    private static synchronized JSONObject getAppsCached(Context ctx, String iconDir, int iconSize, int known) throws Exception {
        watchPackages(ctx);
        if (cachedApps == null || cachedVersion != appsVersion) {
            int v = appsVersion;
            cachedApps = getApps(ctx, iconDir, iconSize);
            cachedVersion = v;
        }
        JSONObject out = new JSONObject();
        out.put("version", cachedVersion);
        if (known != cachedVersion) out.put("apps", cachedApps);
        return out;
    }

    private static void watchPackages(Context ctx) {
        if (receiverOn) return;
        receiverOn = true;
        android.content.IntentFilter f = new android.content.IntentFilter();
        f.addAction(Intent.ACTION_PACKAGE_ADDED);
        f.addAction(Intent.ACTION_PACKAGE_REMOVED);
        f.addAction(Intent.ACTION_PACKAGE_CHANGED);
        f.addAction(Intent.ACTION_PACKAGE_REPLACED);
        f.addDataScheme("package");
        android.content.BroadcastReceiver r = new android.content.BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                appsVersion++;
            }
        };
        Context app = ctx.getApplicationContext();
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED); // system broadcasts still arrive
        } else {
            app.registerReceiver(r, f);
        }
    }

    private static JSONArray getApps(Context ctx, String iconDir, int iconSize) throws Exception {
        PackageManager pm = ctx.getPackageManager();
        Intent q = new Intent(Intent.ACTION_MAIN);
        q.addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> list = pm.queryIntentActivities(q, 0);

        final String self = ctx.getPackageName();
        File dir = null;
        if (iconDir != null) {
            dir = new File(iconDir);
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
        }

        JSONArray apps = new JSONArray();
        for (ResolveInfo ri : list) {
            String pkg = ri.activityInfo.packageName;
            if (pkg.equals(self)) continue;
            String act = ri.activityInfo.name;
            CharSequence label = ri.loadLabel(pm);

            JSONObject app = new JSONObject();
            app.put("pkg", pkg);
            app.put("activity", act);
            app.put("label", label == null ? pkg : label.toString().trim());

            if (dir != null) {
                String name = Integer.toHexString((pkg + "/" + act).hashCode()) + ".png";
                File f = new File(dir, name);
                try {
                    if (needsIcon(pm, pkg, f)) writeIcon(ri.loadIcon(pm), iconSize, f);
                    app.put("icon", name);
                } catch (Throwable t) {
                    Log.w(TAG, "icon failed for " + pkg, t);
                }
            }
            apps.put(app);
        }
        return apps;
    }

    private static boolean needsIcon(PackageManager pm, String pkg, File f) {
        if (!f.exists()) return true;
        try {
            PackageInfo pi = pm.getPackageInfo(pkg, 0);
            return pi.lastUpdateTime > f.lastModified();
        } catch (PackageManager.NameNotFoundException e) {
            return true;
        }
    }

    private static void writeIcon(Drawable d, int size, File f) throws Exception {
        Bitmap bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        d.setBounds(0, 0, size, size);
        d.draw(c);
        File tmp = new File(f.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out);
        }
        bmp.recycle();
        if (!tmp.renameTo(f)) throw new Exception("rename failed: " + f);
    }

    private static boolean launch(Context ctx, String pkg, String activity) {
        Intent i;
        if (activity != null && !activity.isEmpty()) {
            i = new Intent(Intent.ACTION_MAIN);
            i.addCategory(Intent.CATEGORY_LAUNCHER);
            i.setComponent(new ComponentName(pkg, activity));
        } else {
            i = ctx.getPackageManager().getLaunchIntentForPackage(pkg);
            if (i == null) return false;
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        ctx.startActivity(i);
        return true;
    }

    // ---- home app ---------------------------------------------------------------------------

    private static boolean isDefaultHome(Context ctx) {
        Intent home = new Intent(Intent.ACTION_MAIN);
        home.addCategory(Intent.CATEGORY_HOME);
        ResolveInfo ri = ctx.getPackageManager().resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY);
        return ri != null && ri.activityInfo != null && ctx.getPackageName().equals(ri.activityInfo.packageName);
    }

    private static boolean openHomeSettings(Context ctx) {
        // Some head-unit firmwares strip the home settings screen; fall back to main settings.
        for (String action : new String[] { Settings.ACTION_HOME_SETTINGS, Settings.ACTION_SETTINGS }) {
            try {
                Intent i = new Intent(action);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                ctx.startActivity(i);
                return true;
            } catch (Throwable ignored) {
                // try the next one
            }
        }
        return false;
    }

    private static boolean openAppInfo(Context ctx, String pkg) {
        Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
        i.setData(android.net.Uri.fromParts("package", pkg, null));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(i);
        return true;
    }

    // ---- guard ------------------------------------------------------------------------------

    private static JSONObject guardStatus(Context ctx) throws Exception {
        JSONObject o = new JSONObject();
        String on = Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        String me = new ComponentName(ctx, GuardService.class).flattenToString();
        String meShort = new ComponentName(ctx, GuardService.class).flattenToShortString();
        boolean serviceOn = false;
        if (on != null) {
            for (String s : on.split(":")) {
                if (s.equalsIgnoreCase(me) || s.equalsIgnoreCase(meShort)) serviceOn = true;
            }
        }
        android.content.SharedPreferences sp = ctx.getSharedPreferences(GuardService.PREFS, Context.MODE_PRIVATE);
        // the settings string varies between vendors; also ask the accessibility manager
        if (!serviceOn) {
            android.view.accessibility.AccessibilityManager am =
                (android.view.accessibility.AccessibilityManager) ctx.getSystemService(Context.ACCESSIBILITY_SERVICE);
            if (am != null) {
                for (android.accessibilityservice.AccessibilityServiceInfo info :
                        am.getEnabledAccessibilityServiceList(android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_ALL_MASK)) {
                    if (info.getResolveInfo() != null && info.getResolveInfo().serviceInfo != null
                            && ctx.getPackageName().equals(info.getResolveInfo().serviceInfo.packageName)) {
                        serviceOn = true;
                    }
                }
            }
        }
        boolean offByUpdate = sp.getBoolean(GuardService.KEY_OFF_BY_UPDATE, false);
        if (serviceOn && offByUpdate) {
            sp.edit().putBoolean(GuardService.KEY_OFF_BY_UPDATE, false).apply();
            offByUpdate = false;
        } else if (!serviceOn && offByUpdate && GuardService.restore(ctx)) {
            serviceOn = true; // adb-granted permission: put it straight back
            offByUpdate = false;
        }
        o.put("serviceOn", serviceOn);
        o.put("offByUpdate", offByUpdate);
        o.put("canRestore", GuardService.canRestore(ctx));
        o.put("connected", sp.getBoolean(GuardService.KEY_CONNECTED, false)); // diagnostics only
        o.put("enabled", sp.getBoolean(GuardService.KEY_ENABLED, true));
        o.put("pausedUntil", sp.getLong(GuardService.KEY_PAUSE_UNTIL, 0));
        o.put("now", System.currentTimeMillis());
        o.put("sdk", android.os.Build.VERSION.SDK_INT); // 33+ puts sideloaded accessibility behind "restricted settings"
        JSONArray stock = new JSONArray();
        for (String p : GuardService.otherHomeApps(ctx)) stock.put(p);
        o.put("stock", stock);
        return o;
    }

    /** Opens the box's own launcher on purpose; the guard stands down for pauseMs. */
    private static boolean openStockLauncher(Context ctx, long pauseMs) {
        Intent home = new Intent(Intent.ACTION_MAIN);
        home.addCategory(Intent.CATEGORY_HOME);
        List<ResolveInfo> list = ctx.getPackageManager().queryIntentActivities(home, PackageManager.MATCH_ALL);
        for (ResolveInfo ri : list) {
            String p = ri.activityInfo.packageName;
            if (p.equals(ctx.getPackageName()) || p.equals("com.android.settings")) continue;
            GuardService.pause(ctx, pauseMs);
            Intent i = new Intent(Intent.ACTION_MAIN);
            i.addCategory(Intent.CATEGORY_HOME);
            i.setComponent(new ComponentName(p, ri.activityInfo.name));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return true;
        }
        return false;
    }

    private static boolean openSettings(Context ctx, String action) {
        try {
            Intent i = new Intent(action);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return true;
        } catch (Throwable t) {
            Intent i = new Intent(Settings.ACTION_SETTINGS);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return true;
        }
    }

    /** Hands off to whatever voice assistant the box has (Google Assistant, etc.). */
    private static boolean voice(Context ctx) {
        for (String action : new String[] { Intent.ACTION_VOICE_COMMAND, "android.intent.action.ASSIST" }) {
            try {
                Intent i = new Intent(action);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                ctx.startActivity(i);
                return true;
            } catch (Throwable ignored) {
                // try the next one
            }
        }
        return false;
    }

    // ---- helpers ----------------------------------------------------------------------------

    private static String fail(String msg) {
        try {
            JSONObject out = new JSONObject();
            out.put("ok", false);
            out.put("error", msg);
            return ascii(out.toString());
        } catch (Throwable t) {
            return "{\"ok\":false,\"error\":\"bridge failure\"}";
        }
    }

    /** JNI hands strings over as modified UTF-8; escaping everything non-ASCII avoids that entirely. */
    private static String ascii(String s) {
        StringBuilder b = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x80) b.append(c);
            else b.append(String.format("\\u%04x", (int) c));
        }
        return b.toString();
    }
}
