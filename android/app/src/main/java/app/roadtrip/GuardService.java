package app.roadtrip;

import android.accessibilityservice.AccessibilityService;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;

import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Keeps Road Trip in front. Some head units (Ottocast included) drop back to their own
 * launcher now and then even when Road Trip is the default home app; when that launcher
 * comes to the front, this brings Road Trip back.
 *
 * Only reacts to other home apps, never to apps the user opened. Settings live in the
 * "roadtrip" shared preferences, written by LauncherBridge.
 */
public class GuardService extends AccessibilityService {
    private static final String TAG = "RoadTrip";
    static final String PREFS = "roadtrip";
    static final String KEY_ENABLED = "guard_enabled";
    static final String KEY_PAUSE_UNTIL = "guard_pause_until"; // wall-clock ms; survives reboots sanely

    private static final long DELAY_MS = 300;
    private static final long STOCK_REFRESH_MS = 60_000;
    private static final int MAX_RETURNS = 5;          // in RETURN_WINDOW_MS
    private static final long RETURN_WINDOW_MS = 10_000;
    private static final long COOL_OFF_MS = 60_000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private Set<String> stock = new HashSet<>();
    private long stockAt = 0;
    private String front = "";
    private final long[] returns = new long[MAX_RETURNS];
    private int returnIdx = 0;

    private final Runnable bringBack = new Runnable() {
        @Override
        public void run() {
            if (!stock.contains(front) || !active(GuardService.this)) return;
            long now = SystemClock.elapsedRealtime();
            // five returns in ten seconds means something is fighting us: back off
            if (returns[returnIdx] != 0 && now - returns[returnIdx] < RETURN_WINDOW_MS) {
                Log.w(TAG, "guard: too many returns, pausing " + (COOL_OFF_MS / 1000) + "s");
                pause(GuardService.this, COOL_OFF_MS);
                return;
            }
            returns[returnIdx] = now;
            returnIdx = (returnIdx + 1) % MAX_RETURNS;
            try {
                startActivity(homeIntent(GuardService.this));
                Log.i(TAG, "guard: returned from " + front);
            } catch (Throwable t) {
                Log.e(TAG, "guard: couldn't return", t);
            }
        }
    };

    @Override
    protected void onServiceConnected() {
        refreshStock(true);
        Log.i(TAG, "guard: connected, watching " + stock);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return;
        CharSequence pkg = event.getPackageName();
        if (pkg == null) return;
        String p = pkg.toString();
        // the keyboard, system UI and our own overlays don't change what app is in front
        if (p.equals("com.android.systemui") || p.contains("inputmethod")) return;
        front = p;
        handler.removeCallbacks(bringBack);
        refreshStock(false);
        if (stock.contains(p) && active(this)) handler.postDelayed(bringBack, DELAY_MS);
    }

    @Override
    public void onInterrupt() {
        handler.removeCallbacks(bringBack);
    }

    private void refreshStock(boolean force) {
        long now = SystemClock.elapsedRealtime();
        if (!force && now - stockAt < STOCK_REFRESH_MS) return;
        stockAt = now;
        stock = otherHomeApps(this);
    }

    // ---- shared with LauncherBridge ---------------------------------------------------------

    static Set<String> otherHomeApps(Context ctx) {
        Set<String> out = new HashSet<>();
        Intent home = new Intent(Intent.ACTION_MAIN);
        home.addCategory(Intent.CATEGORY_HOME);
        List<ResolveInfo> list = ctx.getPackageManager().queryIntentActivities(home, PackageManager.MATCH_ALL);
        for (ResolveInfo ri : list) {
            String p = ri.activityInfo.packageName;
            // Settings registers a fallback "home" on some builds; never treat it as a launcher
            if (!p.equals(ctx.getPackageName()) && !p.equals("com.android.settings")) out.add(p);
        }
        return out;
    }

    static Intent homeIntent(Context ctx) {
        Intent i = new Intent(Intent.ACTION_MAIN);
        i.addCategory(Intent.CATEGORY_HOME);
        i.setPackage(ctx.getPackageName());
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        return i;
    }

    static boolean active(Context ctx) {
        SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (!sp.getBoolean(KEY_ENABLED, true)) return false;
        return System.currentTimeMillis() >= sp.getLong(KEY_PAUSE_UNTIL, 0);
    }

    static void pause(Context ctx, long ms) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(KEY_PAUSE_UNTIL, System.currentTimeMillis() + ms).apply();
    }
}
