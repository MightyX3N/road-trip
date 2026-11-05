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
                    data = getApps(ctx, a.optString("iconDir", null), a.optInt("iconSize", 192));
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
                case "openAppInfo":
                    data = openAppInfo(ctx, a.getString("pkg"));
                    break;
                case "voice":
                    data = voice(ctx);
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
