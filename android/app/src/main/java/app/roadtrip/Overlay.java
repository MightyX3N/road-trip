package app.roadtrip;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.Location;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONObject;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/**
 * Road Trip's windows over other apps, drawn with plain Android views because Road Trip's own
 * screen (LÖVE) only exists inside its activity:
 *  - the video cover: while the car moves and a video app is in front, the video is hidden
 *    behind the next turn and what's playing (the sound keeps going);
 *  - the turn banner: while Road Trip is guiding you and you're in another app.
 * They're shown through the Keep in front accessibility service when it's on (no extra
 * permission), otherwise through "Display over other apps" if that's allowed.
 */
final class Overlay {
    private static final String TAG = "RoadTrip";
    private static final String K_VIDEO = "overlay_video", K_NOSPEED = "overlay_nospeed", K_BANNER = "overlay_banner";

    // settings (mirrored in prefs so they work before Lua has started)
    private static boolean video = true, banner = true;
    private static String noSpeed = "block"; // block | allow
    private static JSONObject labels = new JSONObject();
    private static int accent = 0xFFF2A23A, onAccent = 0xFF1A1306;

    // what's going on
    private static volatile String fgPkg = "";
    private static volatile JSONObject nav;        // Road Trip's guidance, from Lua
    private static volatile long navAt = 0;
    static volatile boolean roadTripResumed = false;
    private static boolean moving = false;
    static volatile boolean speedUnknown = true; // no GPS speed: "moving" comes from the setting
    private static long stillSince = 0;
    private static String lastReason = "";

    private static Context app;
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static boolean started = false;

    private static WindowManager wm;
    private static Context host;     // the context the windows belong to
    private static View coverView, bannerView;
    private static CoverHolder cover;
    private static BannerHolder bannerH;

    private Overlay() {}

    // ------------------------------------------------------------------------------------
    // from Lua (LauncherBridge) and the services

    static synchronized void start(Context ctx) {
        if (started) return;
        started = true;
        app = ctx.getApplicationContext();
        SharedPreferences sp = app.getSharedPreferences(GuardService.PREFS, Context.MODE_PRIVATE);
        video = sp.getBoolean(K_VIDEO, true);
        banner = sp.getBoolean(K_BANNER, true);
        noSpeed = sp.getString(K_NOSPEED, "block");
        LocationBridge.start(app); // speed; quietly does nothing without permission
        main.post(TICK);
    }

    static void configure(Context ctx, JSONObject c) {
        start(ctx);
        if (c.has("video")) video = c.optBoolean("video", true);
        if (c.has("banner")) banner = c.optBoolean("banner", true);
        if (c.has("noSpeed")) noSpeed = c.optString("noSpeed", "block");
        if (c.has("labels")) labels = c.optJSONObject("labels");
        if (c.has("accent")) {
            try { accent = Color.parseColor(c.optString("accent")); } catch (Throwable ignored) {}
        }
        app.getSharedPreferences(GuardService.PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(K_VIDEO, video).putBoolean(K_BANNER, banner).putString(K_NOSPEED, noSpeed).apply();
        main.post(new Runnable() { @Override public void run() { if (cover != null) cover.restyle(); if (bannerH != null) bannerH.restyle(); } });
    }

    static void setNav(JSONObject g) {
        nav = g;
        navAt = SystemClock.elapsedRealtime();
    }

    /** The guard saw a new screen. Road Trip's own overlay windows don't count. */
    static void onWindow(Context ctx, String pkg, String cls) {
        start(ctx);
        if (pkg.equals(ctx.getPackageName()) && !cls.contains("RoadTripActivity")) return;
        fgPkg = pkg;
        main.post(TICK);
    }

    /** Moving now (or no speed and "hide video" chosen), and hiding video while driving is on. */
    static boolean drivingNow() {
        if (!video) return false;
        if (app == null) return "block".equals(noSpeed);
        return moving;
    }

    static boolean canDrawOverlays(Context ctx) {
        return Build.VERSION.SDK_INT < 23 || android.provider.Settings.canDrawOverlays(ctx);
    }

    static boolean openOverlaySettings(Context ctx) {
        try {
            Intent i = new Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                android.net.Uri.parse("package:" + ctx.getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    static JSONObject status(Context ctx) throws Exception {
        JSONObject o = new JSONObject();
        o.put("front", fgPkg);
        o.put("video", video);
        o.put("banner", banner);
        o.put("noSpeed", noSpeed);
        o.put("moving", moving);
        o.put("why", lastReason);
        o.put("canDraw", canDrawOverlays(ctx));
        o.put("guard", GuardService.instance != null);
        o.put("covering", coverView != null);
        o.put("bannerShown", bannerView != null);
        o.put("navAgeS", nav == null ? -1 : (SystemClock.elapsedRealtime() - navAt) / 1000);
        return o;
    }

    // ------------------------------------------------------------------------------------
    // deciding

    private static final Set<String> VIDEO_APPS = new HashSet<>(Arrays.asList(
        "com.google.android.youtube", "com.google.android.apps.youtube.kids", "com.google.android.youtube.tv",
        "app.revanced.android.youtube", "com.vanced.android.youtube", "com.google.android.videos",
        "com.netflix.mediaclient", "com.disney.disneyplus", "com.amazon.avod.thirdpartyclient", "com.amazon.avod",
        "com.hbo.hbonow", "com.wbd.stream", "com.hulu.plus", "com.peacocktv.peacockandroid", "com.cbs.app",
        "tv.pluto.android", "com.apple.atve.android.appletv", "com.crunchyroll.crunchyroid",
        "tv.twitch.android.app", "com.zhiliaoapp.musically", "com.ss.android.ugc.trill",
        "org.videolan.vlc", "com.mxtech.videoplayer.ad", "com.mxtech.videoplayer.pro", "org.xbmc.kodi",
        "com.plexapp.android", "org.jellyfin.mobile", "com.dailymotion.dailymotion", "com.vimeo.android.videoapp",
        "com.viaplay.android", "dk.dr.tvplayer", "dk.tv2.tv2play", "com.skyshowtime.skyshowtime.google",
        "com.bilibili.app.in", "com.facebook.lite.video"));

    private static boolean isVideoApp(Context ctx, String pkg) {
        if (pkg == null || pkg.isEmpty() || pkg.equals(ctx.getPackageName())) return false;
        if (VIDEO_APPS.contains(pkg)) return true;
        if (Build.VERSION.SDK_INT >= 26) {
            try {
                ApplicationInfo ai = ctx.getPackageManager().getApplicationInfo(pkg, 0);
                return ai.category == ApplicationInfo.CATEGORY_VIDEO;
            } catch (Throwable ignored) {}
        }
        return false;
    }

    // moving: over 10 km/h starts it; under 5 km/h for 8 seconds ends it
    private static boolean updateMoving() {
        Location l = LocationBridge.lastFix();
        boolean known = l != null && l.hasSpeed()
            && SystemClock.elapsedRealtimeNanos() - l.getElapsedRealtimeNanos() < 8_000_000_000L;
        long now = SystemClock.elapsedRealtime();
        speedUnknown = !known;
        if (!known) {
            stillSince = 0;
            moving = "block".equals(noSpeed);
            lastReason = "no speed: " + (moving ? "treated as driving" : "treated as stopped");
            return moving;
        }
        float v = l.getSpeed();
        if (v >= 2.8f) { moving = true; stillSince = 0; }
        else if (v < 1.4f) {
            if (stillSince == 0) stillSince = now;
            if (now - stillSince > 8000) moving = false;
        }
        lastReason = String.format(java.util.Locale.ROOT, "%.0f km/h", v * 3.6f);
        return moving;
    }

    private static final Runnable TICK = new Runnable() {
        @Override
        public void run() {
            main.removeCallbacks(this);
            try { tick(); } catch (Throwable t) { Log.w(TAG, "overlay: " + t); }
            main.postDelayed(this, 1000);
        }
    };

    private static void tick() {
        if (app == null) return;
        boolean drive = updateMoving();
        boolean ours = roadTripResumed;
        boolean guard = GuardService.instance != null;
        boolean wantCover = video && guard && !ours && drive && isVideoApp(app, fgPkg);
        JSONObject g = nav;
        boolean navFresh = g != null && SystemClock.elapsedRealtime() - navAt < 15_000;
        boolean wantBanner = banner && !ours && navFresh && !wantCover;

        // where the windows live: the accessibility service if it's on, else "draw over apps"
        Context want = guard ? GuardService.instance : (canDrawOverlays(app) ? app : null);
        if (want != host) {
            removeAll();
            host = want;
            wm = host == null ? null : (WindowManager) host.getSystemService(Context.WINDOW_SERVICE);
        }
        if (host == null) return;

        if (wantCover) {
            if (coverView == null) addCover();
            if (cover != null) cover.update(g);
        } else if (coverView != null) {
            remove(coverView);
            coverView = null;
            cover = null;
        }
        if (wantBanner) {
            if (bannerView == null) addBanner();
            if (bannerH != null) bannerH.update(g);
        } else if (bannerView != null) {
            remove(bannerView);
            bannerView = null;
            bannerH = null;
        }
    }

    // ------------------------------------------------------------------------------------
    // windows

    private static int type() {
        if (host instanceof GuardService && Build.VERSION.SDK_INT >= 22)
            return WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY;
        if (Build.VERSION.SDK_INT >= 26) return WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
        //noinspection deprecation
        return WindowManager.LayoutParams.TYPE_PHONE;
    }

    private static void addCover() {
        cover = new CoverHolder(host);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT, type(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                | WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.TRANSLUCENT);
        try {
            wm.addView(cover.root, lp);
            coverView = cover.root;
        } catch (Throwable t) {
            Log.w(TAG, "overlay: cover failed", t);
            cover = null;
        }
    }

    private static void addBanner() {
        bannerH = new BannerHolder(host);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, type(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        lp.y = dp(host, 10);
        try {
            wm.addView(bannerH.root, lp);
            bannerView = bannerH.root;
        } catch (Throwable t) {
            Log.w(TAG, "overlay: banner failed", t);
            bannerH = null;
        }
    }

    private static void remove(View v) {
        try { if (wm != null) wm.removeView(v); } catch (Throwable ignored) {}
    }

    private static void removeAll() {
        if (coverView != null) remove(coverView);
        if (bannerView != null) remove(bannerView);
        coverView = bannerView = null;
        cover = null;
        bannerH = null;
    }

    /** The accessibility service is going away: its windows go with it. */
    static void hostGone(Context ctx) {
        main.post(new Runnable() {
            @Override public void run() {
                if (host == ctx) { removeAll(); host = null; wm = null; }
            }
        });
    }

    // ------------------------------------------------------------------------------------
    // drawing helpers

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    private static Typeface bold, semi;

    private static Typeface font(Context c, boolean b) {
        if (bold == null) {
            try {
                bold = Typeface.createFromAsset(c.getAssets(), "fonts/Manrope-Bold.ttf");
                semi = Typeface.createFromAsset(c.getAssets(), "fonts/Manrope-SemiBold.ttf");
            } catch (Throwable t) {
                bold = Typeface.DEFAULT_BOLD;
                semi = Typeface.DEFAULT;
            }
        }
        return b ? bold : semi;
    }

    private static TextView text(Context c, float sp, int color, boolean b) {
        TextView t = new TextView(c);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(font(c, b));
        t.setSingleLine(false);
        t.setIncludeFontPadding(false);
        return t;
    }

    private static GradientDrawable round(int color, float radiusDp, Context c) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(c, radiusDp));
        return d;
    }

    private static String label(String key, String fallback) {
        String v = labels == null ? null : labels.optString(key, null);
        return v == null || v.isEmpty() ? fallback : v;
    }

    private static void openRoadTrip(Context c) {
        try {
            Intent i = new Intent(c, RoadTripActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
            c.startActivity(i);
        } catch (Throwable t) {
            Log.w(TAG, "overlay: open failed", t);
        }
    }

    /** Road Trip's line icons, the same shapes as in ui.lua (a 24-unit box). */
    static final class IconView extends View {
        String name = "straight";
        int color = Color.WHITE;
        private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();

        IconView(Context c) { super(c); }

        void set(String n, int col) {
            if (n == null) n = "straight";
            if (!n.equals(name) || col != color) { name = n; color = col; invalidate(); }
        }

        private void line(float... xy) {
            path.reset();
            path.moveTo(xy[0], xy[1]);
            for (int i = 2; i < xy.length; i += 2) path.lineTo(xy[i], xy[i + 1]);
        }

        @Override
        protected void onDraw(Canvas cv) {
            float s = Math.min(getWidth(), getHeight()) / 24f;
            cv.save();
            cv.translate((getWidth() - 24 * s) / 2, (getHeight() - 24 * s) / 2);
            cv.scale(s, s);
            p.setColor(color);
            p.setStrokeWidth(2.4f);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);
            boolean mirror = name.equals("turnLeft") || name.equals("slightLeft");
            if (mirror) { cv.translate(24, 0); cv.scale(-1, 1); }
            p.setStyle(Paint.Style.STROKE);
            switch (name) {
                case "turn": case "turnLeft":
                    line(8, 20, 8, 10, 17, 10); cv.drawPath(path, p);
                    line(14, 6, 18, 10, 14, 14); cv.drawPath(path, p);
                    break;
                case "slightRight": case "slightLeft":
                    line(9, 20, 9, 13, 16, 6); cv.drawPath(path, p);
                    line(11, 6, 16, 6, 16, 11); cv.drawPath(path, p);
                    break;
                case "uturn":
                    line(8, 20, 8, 10); cv.drawPath(path, p);
                    cv.drawArc(new RectF(8, 6, 16, 14), 180, 180, false, p);
                    line(16, 10, 16, 16); cv.drawPath(path, p);
                    line(13, 13, 16, 16, 19, 13); cv.drawPath(path, p);
                    break;
                case "roundabout":
                    cv.drawCircle(12, 10, 4, p);
                    line(12, 14, 12, 21); cv.drawPath(path, p);
                    line(15, 7, 19, 3); cv.drawPath(path, p);
                    line(15, 3, 19, 3, 19, 7); cv.drawPath(path, p);
                    break;
                case "pin":
                    cv.drawCircle(12, 10, 6.5f, p);
                    line(7.5f, 14.5f, 12, 21, 16.5f, 14.5f); cv.drawPath(path, p);
                    cv.drawCircle(12, 10, 2.5f, p);
                    break;
                case "play":
                    p.setStyle(Paint.Style.FILL);
                    line(7, 4.5f, 20, 12, 7, 19.5f); path.close(); cv.drawPath(path, p);
                    break;
                case "pause":
                    p.setStyle(Paint.Style.FILL);
                    cv.drawRoundRect(new RectF(6, 5, 10, 19), 1, 1, p);
                    cv.drawRoundRect(new RectF(14, 5, 18, 19), 1, 1, p);
                    break;
                case "prev":
                    p.setStyle(Paint.Style.FILL);
                    line(19, 5, 19, 19, 9, 12); path.close(); cv.drawPath(path, p);
                    cv.drawRoundRect(new RectF(5, 5, 7.6f, 19), 1, 1, p);
                    break;
                case "next":
                    p.setStyle(Paint.Style.FILL);
                    line(5, 5, 5, 19, 15, 12); path.close(); cv.drawPath(path, p);
                    cv.drawRoundRect(new RectF(16.4f, 5, 19, 19), 1, 1, p);
                    break;
                default: // straight
                    line(12, 20, 12, 5); cv.drawPath(path, p);
                    line(7, 10, 12, 5, 17, 10); cv.drawPath(path, p);
            }
            cv.restore();
        }
    }

    // the next turn, from Road Trip or from the nav app's notification
    private static JSONObject currentTurn() {
        JSONObject g = nav;
        if (g != null && SystemClock.elapsedRealtime() - navAt < 15_000) return g;
        JSONObject n = MediaListener.navNow();
        return n;
    }

    // ------------------------------------------------------------------------------------
    // the video cover

    static final class CoverHolder {
        final FrameLayout root;
        final Context c;
        final LinearLayout turnCard;
        final View turnSquare;
        final IconView turnIcon;
        final ImageView turnImg;
        final TextView turnTitle, turnText, title, sub, open;
        final LinearLayout mediaCard;
        final ImageView art;
        final TextView mTitle, mArtist;
        final IconView playIcon;
        final View[] buttons = new View[3];
        String artKey = "";

        CoverHolder(Context ctx) {
            c = ctx;
            root = new FrameLayout(c);
            root.setBackgroundColor(0xF70E0F11);
            root.setClickable(true); // the video underneath can't be touched
            root.setFocusable(false);

            LinearLayout row = new LinearLayout(c);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            int pad = dp(c, 32);
            row.setPadding(pad, pad, pad, pad);
            root.addView(row, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

            // left: why, the next turn, back to Road Trip
            LinearLayout left = new LinearLayout(c);
            left.setOrientation(LinearLayout.VERTICAL);
            row.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            title = text(c, 28, 0xFFF3F1EC, true);
            left.addView(title);
            sub = text(c, 16, 0xFF9A9890, false);
            LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            sp.topMargin = dp(c, 10);
            left.addView(sub, sp);

            turnCard = new LinearLayout(c);
            turnCard.setOrientation(LinearLayout.HORIZONTAL);
            turnCard.setGravity(Gravity.CENTER_VERTICAL);
            turnCard.setBackground(round(0xFF17191D, 24, c));
            int tp = dp(c, 16);
            turnCard.setPadding(tp, tp, dp(c, 24), tp);
            FrameLayout sq = new FrameLayout(c);
            turnSquare = sq;
            int sqs = dp(c, 84);
            turnIcon = new IconView(c);
            turnImg = new ImageView(c);
            turnImg.setScaleType(ImageView.ScaleType.FIT_CENTER);
            int ip = dp(c, 14);
            FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            ilp.setMargins(ip, ip, ip, ip);
            sq.addView(turnIcon, ilp);
            sq.addView(turnImg, new FrameLayout.LayoutParams(ilp));
            turnCard.addView(sq, new LinearLayout.LayoutParams(sqs, sqs));
            LinearLayout tt = new LinearLayout(c);
            tt.setOrientation(LinearLayout.VERTICAL);
            LinearLayout.LayoutParams ttl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            ttl.leftMargin = dp(c, 18);
            turnCard.addView(tt, ttl);
            turnTitle = text(c, 34, 0xFFF3F1EC, true);
            turnTitle.setSingleLine(true);
            tt.addView(turnTitle);
            turnText = text(c, 17, 0xFFC9C6BE, false);
            turnText.setMaxLines(2);
            LinearLayout.LayoutParams txl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            txl.topMargin = dp(c, 6);
            tt.addView(turnText, txl);
            LinearLayout.LayoutParams tcl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            tcl.topMargin = dp(c, 24);
            left.addView(turnCard, tcl);

            open = text(c, 18, onAccent, true);
            open.setGravity(Gravity.CENTER);
            int op = dp(c, 16);
            open.setPadding(dp(c, 32), op, dp(c, 32), op);
            open.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { openRoadTrip(c); } });
            LinearLayout.LayoutParams olp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            olp.topMargin = dp(c, 24);
            left.addView(open, olp);

            // right: what's playing, with controls (the sound keeps going under the cover)
            mediaCard = new LinearLayout(c);
            mediaCard.setOrientation(LinearLayout.VERTICAL);
            mediaCard.setBackground(round(0xFF17191D, 28, c));
            int mp = dp(c, 24);
            mediaCard.setPadding(mp, mp, mp, mp);
            LinearLayout.LayoutParams mcl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            mcl.leftMargin = dp(c, 32);
            row.addView(mediaCard, mcl);
            LinearLayout top = new LinearLayout(c);
            top.setOrientation(LinearLayout.HORIZONTAL);
            top.setGravity(Gravity.CENTER_VERTICAL);
            mediaCard.addView(top);
            art = new ImageView(c);
            art.setScaleType(ImageView.ScaleType.CENTER_CROP);
            art.setBackground(round(0xFF2A2620, 18, c));
            art.setClipToOutline(true);
            int as = dp(c, 110);
            top.addView(art, new LinearLayout.LayoutParams(as, as));
            LinearLayout mt = new LinearLayout(c);
            mt.setOrientation(LinearLayout.VERTICAL);
            LinearLayout.LayoutParams mtl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            mtl.leftMargin = dp(c, 20);
            top.addView(mt, mtl);
            mTitle = text(c, 22, 0xFFF3F1EC, true);
            mTitle.setMaxLines(2);
            mt.addView(mTitle);
            mArtist = text(c, 16, 0xFFB8B5AD, false);
            mArtist.setSingleLine(true);
            LinearLayout.LayoutParams mal = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            mal.topMargin = dp(c, 6);
            mt.addView(mArtist, mal);

            LinearLayout ctl = new LinearLayout(c);
            ctl.setOrientation(LinearLayout.HORIZONTAL);
            LinearLayout.LayoutParams cl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(c, 64));
            cl.topMargin = dp(c, 22);
            mediaCard.addView(ctl, cl);
            String[] acts = { "prev", "toggle", "next" };
            IconView play = null;
            for (int i = 0; i < 3; i++) {
                FrameLayout b = new FrameLayout(c);
                b.setBackground(round(i == 1 ? accent : 0xFF22252A, 18, c));
                IconView iv = new IconView(c);
                iv.set(i == 0 ? "prev" : i == 1 ? "pause" : "next", i == 1 ? onAccent : 0xFFE8E5DD);
                int ipad = dp(c, 18);
                FrameLayout.LayoutParams bl = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
                bl.setMargins(ipad, ipad, ipad, ipad);
                b.addView(iv, bl);
                if (i == 1) play = iv;
                final String a = acts[i];
                b.setOnClickListener(new View.OnClickListener() {
                    @Override public void onClick(View v) {
                        if (!MediaListener.command(c, a, 0)) RadioService.command(c, a);
                        main.postDelayed(TICK, 300);
                    }
                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f);
                if (i > 0) lp.leftMargin = dp(c, 12);
                ctl.addView(b, lp);
                buttons[i] = b;
            }
            playIcon = play;
            restyle();
        }

        void restyle() {
            title.setText(label("coverTitle", "Video hidden while driving"));
            sub.setText(label("coverSub", "The sound keeps playing. The video comes back when you stop."));
            open.setText(label("open", "Open Road Trip"));
            open.setTextColor(onAccent);
            open.setBackground(round(accent, 28, c));
            turnSquare.setBackground(round(accent, 20, c));
            buttons[1].setBackground(round(accent, 18, c));
        }

        void update(JSONObject g) {
            JSONObject t = currentTurn();
            if (t == null) {
                turnCard.setVisibility(View.GONE);
            } else {
                turnCard.setVisibility(View.VISIBLE);
                turnTitle.setText(t.optString("title", ""));
                turnText.setText(t.optString("text", ""));
                Bitmap ic = t.has("bitmap") ? (Bitmap) t.opt("bitmap") : null;
                if (ic != null) {
                    turnImg.setImageBitmap(ic);
                    turnImg.setColorFilter(onAccent);
                    turnImg.setVisibility(View.VISIBLE);
                    turnIcon.setVisibility(View.GONE);
                } else {
                    turnImg.setVisibility(View.GONE);
                    turnIcon.setVisibility(View.VISIBLE);
                    turnIcon.set(t.optString("icon", "straight"), onAccent);
                }
            }
            MediaListener.Now m = MediaListener.now(c);
            if (m == null) {
                mediaCard.setVisibility(View.GONE);
            } else {
                mediaCard.setVisibility(View.VISIBLE);
                mTitle.setText(m.title.isEmpty() ? m.app : m.title);
                mArtist.setText(m.artist.isEmpty() ? m.app : m.artist);
                String key = m.pkg + "|" + m.title + "|" + m.artist;
                if (!key.equals(artKey)) {
                    artKey = key;
                    if (m.art != null) art.setImageBitmap(m.art); else art.setImageDrawable(null);
                }
                playIcon.set(m.playing ? "pause" : "play", onAccent);
            }
        }
    }

    // ------------------------------------------------------------------------------------
    // the turn banner

    static final class BannerHolder {
        final LinearLayout root;
        final Context c;
        final View square;
        final IconView icon;
        final TextView title, line;

        BannerHolder(Context ctx) {
            c = ctx;
            root = new LinearLayout(c);
            root.setOrientation(LinearLayout.HORIZONTAL);
            root.setGravity(Gravity.CENTER_VERTICAL);
            root.setBackground(round(0xF20E0F11, 26, c));
            int p = dp(c, 12);
            root.setPadding(p, p, dp(c, 26), p);
            root.setElevation(dp(c, 6));
            root.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { openRoadTrip(c); } });
            FrameLayout sq = new FrameLayout(c);
            square = sq;
            icon = new IconView(c);
            int ip = dp(c, 10);
            FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            ilp.setMargins(ip, ip, ip, ip);
            sq.addView(icon, ilp);
            int s = dp(c, 58);
            root.addView(sq, new LinearLayout.LayoutParams(s, s));
            LinearLayout t = new LinearLayout(c);
            t.setOrientation(LinearLayout.VERTICAL);
            LinearLayout.LayoutParams tl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            tl.leftMargin = dp(c, 16);
            root.addView(t, tl);
            title = text(c, 24, 0xFFF3F1EC, true);
            title.setSingleLine(true);
            t.addView(title);
            line = text(c, 15, 0xFFC9C6BE, false);
            line.setSingleLine(true);
            line.setMaxWidth(dp(c, 420));
            line.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams ll = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            ll.topMargin = dp(c, 4);
            t.addView(line, ll);
            restyle();
        }

        void restyle() { square.setBackground(round(accent, 18, c)); }

        void update(JSONObject g) {
            if (g == null) return;
            title.setText(g.optString("title", ""));
            String s = g.optString("text", "");
            String arr = g.optString("arrival", "");
            line.setText(arr.isEmpty() ? s : s + "  ·  " + arr);
            icon.set(g.optString("icon", "straight"), onAccent);
        }
    }
}
