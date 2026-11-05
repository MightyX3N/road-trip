package app.roadtrip;

import android.app.Notification;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.provider.Settings;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.Log;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.util.List;

/**
 * Notification access is Android's gate for seeing other apps' media sessions; this service
 * only exists so the user can grant it. It reads no notifications. The static methods are
 * what LauncherBridge calls: status() for what's playing, command() to control it.
 */
public class MediaListener extends NotificationListenerService {
    private static final String TAG = "RoadTrip";
    private static MediaController current;

    @Override
    public void onListenerConnected() {
        Log.i(TAG, "media: notification access connected");
        try {
            StatusBarNotification[] all = getActiveNotifications();
            if (all != null) for (StatusBarNotification s : all) considerNav(this, s);
        } catch (Throwable t) {
            Log.w(TAG, "nav: initial scan failed", t);
        }
    }

    // ---- navigation: the nav app's ongoing turn-by-turn notification ----------------------

    private static final java.util.Set<String> NAV_APPS = new java.util.HashSet<>(java.util.Arrays.asList(
        "com.google.android.apps.maps", "com.waze", "net.osmand", "net.osmand.plus",
        "com.here.app.maps", "com.sygic.aura", "cz.seznam.mapy", "com.mapfactor.navigator"));

    private static String navKey, navPkg, navTitle, navText, navSub;
    private static Bitmap navIcon;
    private static int navIconGen = 0;     // bumps when the turn arrow changes
    private static int navIconWritten = -1;

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        considerNav(this, sbn);
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        synchronized (MediaListener.class) {
            if (sbn != null && sbn.getKey().equals(navKey)) navKey = null;
        }
    }

    private static void considerNav(Context ctx, StatusBarNotification sbn) {
        if (sbn == null) return;
        Notification n = sbn.getNotification();
        if (n == null) return;
        String pkg = sbn.getPackageName();
        boolean ongoing = (n.flags & Notification.FLAG_ONGOING_EVENT) != 0;
        boolean isNav = Notification.CATEGORY_NAVIGATION.equals(n.category) || (NAV_APPS.contains(pkg) && ongoing);
        if (!isNav) return;
        Bundle e = n.extras;
        String title = text(e, Notification.EXTRA_TITLE);
        String body = text(e, Notification.EXTRA_TEXT);
        if (body.isEmpty()) body = text(e, Notification.EXTRA_BIG_TEXT);
        String sub = text(e, Notification.EXTRA_SUB_TEXT);
        if (sub.isEmpty()) sub = text(e, Notification.EXTRA_INFO_TEXT);
        if (title.isEmpty() && n.tickerText != null) title = n.tickerText.toString().trim();
        logNav(pkg + "  cat=" + n.category + (ongoing ? " ongoing" : "")
            + "  title=\"" + title + "\"  text=\"" + body + "\"  sub=\"" + sub + "\""
            + "  icon=" + (n.getLargeIcon() != null) + "  custom=" + (n.contentView != null || n.bigContentView != null));
        // Google Maps often draws its own layout and leaves the text fields empty; still show
        // that navigation is running (Lua words it from the app name)
        Bitmap icon = null;
        try {
            if (n.getLargeIcon() != null) {
                android.graphics.drawable.Drawable d = n.getLargeIcon().loadDrawable(ctx);
                if (d != null) {
                    int w = Math.max(1, Math.min(256, d.getIntrinsicWidth() > 0 ? d.getIntrinsicWidth() : 128));
                    int h = Math.max(1, Math.min(256, d.getIntrinsicHeight() > 0 ? d.getIntrinsicHeight() : 128));
                    icon = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                    android.graphics.Canvas c = new android.graphics.Canvas(icon);
                    d.setBounds(0, 0, w, h);
                    d.draw(c);
                }
            }
        } catch (Throwable ignored) {
            // no arrow; the text still shows
        }
        synchronized (MediaListener.class) {
            navKey = sbn.getKey();
            navPkg = pkg;
            navTitle = title;
            navText = body;
            navSub = sub;
            if (icon != null || navIcon != null) {
                navIcon = icon;
                navIconGen++;
            }
        }
    }

    private static final java.util.ArrayDeque<String> NAV_LOG = new java.util.ArrayDeque<>();

    private static synchronized void logNav(String line) {
        String t = new java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.ROOT).format(new java.util.Date());
        if (!NAV_LOG.isEmpty() && NAV_LOG.peekFirst().endsWith(line)) return; // same update repeated
        NAV_LOG.addFirst(t + "  " + line);
        while (NAV_LOG.size() > 12) NAV_LOG.removeLast();
    }

    static synchronized org.json.JSONArray navLogJson() {
        org.json.JSONArray a = new org.json.JSONArray();
        for (String s : NAV_LOG) a.put(s);
        return a;
    }

    private static String text(Bundle e, String key) {
        if (e == null) return "";
        CharSequence v = e.getCharSequence(key);
        return v == null ? "" : v.toString().trim();
    }

    /** {active, pkg?, app?, title?, text?, sub?, icon?} */
    static synchronized JSONObject navStatus(Context ctx, String dir) throws Exception {
        JSONObject o = new JSONObject();
        boolean active = navKey != null && hasAccess(ctx);
        o.put("active", active);
        if (!active) return o;
        o.put("pkg", navPkg);
        try {
            PackageManager pm = ctx.getPackageManager();
            o.put("app", pm.getApplicationLabel(pm.getApplicationInfo(navPkg, 0)).toString());
        } catch (Throwable t) {
            o.put("app", navPkg);
        }
        o.put("title", navTitle);
        o.put("text", navText);
        o.put("sub", navSub);
        if (navIcon != null && dir != null) {
            String name = "turn" + navIconGen + ".png";
            if (navIconWritten == navIconGen || writeArt(navIcon, new File(dir), name)) {
                navIconWritten = navIconGen;
                o.put("icon", name);
            }
        }
        return o;
    }

    static boolean hasAccess(Context ctx) {
        String on = Settings.Secure.getString(ctx.getContentResolver(), "enabled_notification_listeners");
        if (on == null) return false;
        ComponentName me = new ComponentName(ctx, MediaListener.class);
        for (String s : on.split(":")) {
            ComponentName c = ComponentName.unflattenFromString(s);
            if (me.equals(c)) return true;
        }
        return false;
    }

    static boolean openAccess(Context ctx) {
        ComponentName me = new ComponentName(ctx, MediaListener.class);
        Intent i;
        if (Build.VERSION.SDK_INT >= 30) {
            i = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS);
            i.putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, me.flattenToString());
        } else {
            i = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            ctx.startActivity(i);
        } catch (Throwable t) {
            Intent all = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
            all.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(all);
        }
        return true;
    }

    private static MediaController pick(Context ctx) {
        MediaSessionManager msm = (MediaSessionManager) ctx.getSystemService(Context.MEDIA_SESSION_SERVICE);
        if (msm == null) return null;
        List<MediaController> list = msm.getActiveSessions(new ComponentName(ctx, MediaListener.class));
        for (MediaController c : list) {
            PlaybackState s = c.getPlaybackState();
            if (s != null && s.getState() == PlaybackState.STATE_PLAYING) return c;
        }
        return list.isEmpty() ? null : list.get(0);
    }

    /** {access, current?: {pkg, app, title, artist, album, durationMs, positionMs, playing, speed, canPrev, canNext, art?}} */
    static synchronized JSONObject status(Context ctx, String artDir) throws Exception {
        JSONObject o = new JSONObject();
        boolean access = hasAccess(ctx);
        o.put("access", access);
        if (!access) {
            current = null;
            return o;
        }
        MediaController c = pick(ctx);
        current = c;
        if (c == null) return o;

        JSONObject m = new JSONObject();
        String pkg = c.getPackageName();
        m.put("pkg", pkg);
        try {
            PackageManager pm = ctx.getPackageManager();
            m.put("app", pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString());
        } catch (Throwable t) {
            m.put("app", pkg);
        }

        MediaMetadata md = c.getMetadata();
        String title = "", artist = "", album = "";
        long duration = 0;
        Bitmap art = null;
        if (md != null) {
            title = first(md, MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_DISPLAY_TITLE);
            artist = first(md, MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM_ARTIST,
                MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE);
            album = first(md, MediaMetadata.METADATA_KEY_ALBUM);
            duration = md.getLong(MediaMetadata.METADATA_KEY_DURATION);
            art = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART);
            if (art == null) art = md.getBitmap(MediaMetadata.METADATA_KEY_ART);
            if (art == null) art = md.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON);
        }
        m.put("title", title);
        m.put("artist", artist);
        m.put("album", album);
        m.put("durationMs", Math.max(0, duration));

        PlaybackState st = c.getPlaybackState();
        boolean playing = st != null && st.getState() == PlaybackState.STATE_PLAYING;
        long pos = 0;
        float speed = 1f;
        long actions = 0;
        if (st != null) {
            speed = st.getPlaybackSpeed() == 0 ? 1f : st.getPlaybackSpeed();
            pos = st.getPosition();
            if (playing && st.getLastPositionUpdateTime() > 0) {
                pos += (long) ((SystemClock.elapsedRealtime() - st.getLastPositionUpdateTime()) * speed);
            }
            actions = st.getActions();
        }
        if (duration > 0) pos = Math.min(pos, duration);
        m.put("positionMs", Math.max(0, pos));
        m.put("playing", playing);
        m.put("speed", speed);
        // apps that leave actions unset usually still handle them, so only hide when clearly absent
        m.put("canPrev", actions == 0 || (actions & PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0);
        m.put("canNext", actions == 0 || (actions & PlaybackState.ACTION_SKIP_TO_NEXT) != 0);
        m.put("canSeek", (actions & PlaybackState.ACTION_SEEK_TO) != 0);

        if (art != null && artDir != null) {
            String name = Integer.toHexString((pkg + "|" + title + "|" + artist + "|" + album).hashCode()) + ".png";
            if (writeArt(art, new File(artDir), name)) m.put("art", name);
        }
        o.put("current", m);
        return o;
    }

    static synchronized boolean command(Context ctx, String action, long posMs) {
        MediaController c = current != null ? current : pick(ctx);
        if (c == null) return false;
        MediaController.TransportControls t = c.getTransportControls();
        switch (action) {
            case "play": t.play(); break;
            case "pause": t.pause(); break;
            case "toggle": {
                PlaybackState s = c.getPlaybackState();
                if (s != null && s.getState() == PlaybackState.STATE_PLAYING) t.pause(); else t.play();
                break;
            }
            case "next": t.skipToNext(); break;
            case "prev": t.skipToPrevious(); break;
            case "seek": t.seekTo(Math.max(0, posMs)); break;
            default: return false;
        }
        return true;
    }

    private static String first(MediaMetadata md, String... keys) {
        for (String k : keys) {
            CharSequence v = md.getText(k);
            if (v != null && v.length() > 0) return v.toString();
        }
        return "";
    }

    // Writes the art once per track; keeps only the current file so the folder never grows.
    private static boolean writeArt(Bitmap art, File dir, String name) {
        try {
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
            File f = new File(dir, name);
            if (f.exists()) return true;
            int max = 512;
            Bitmap b = art;
            if (art.getWidth() > max || art.getHeight() > max) {
                float s = Math.min(max / (float) art.getWidth(), max / (float) art.getHeight());
                b = Bitmap.createScaledBitmap(art, Math.round(art.getWidth() * s), Math.round(art.getHeight() * s), true);
            }
            File tmp = new File(dir, name + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                b.compress(Bitmap.CompressFormat.PNG, 100, out);
            }
            if (!tmp.renameTo(f)) return false;
            File[] old = dir.listFiles();
            if (old != null) {
                for (File x : old) {
                    if (!x.getName().equals(name)) //noinspection ResultOfMethodCallIgnored
                        x.delete();
                }
            }
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "media: art write failed", t);
            return false;
        }
    }
}
