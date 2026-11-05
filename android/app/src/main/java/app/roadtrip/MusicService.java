package app.roadtrip;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.drawable.Icon;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * Plays a queue of tracks from the user's Jellyfin server (music, audiobooks, podcasts) in
 * the background, with a media notification and session for the steering wheel. ExoPlayer
 * does the streaming and audio focus; everything runs on the main thread.
 */
public class MusicService extends Service {
    private static final String CHANNEL = "roadtrip_music";
    private static final int NOTE_ID = 7051;

    private static volatile MusicService running;
    private static volatile JSONArray queue = new JSONArray(); // [{url, title, artist, album, art?}]
    private static volatile int startAt = 0;
    private static volatile JSONObject last = null; // the last status, readable from any thread
    private static volatile String error = null;

    private final Handler main = new Handler(Looper.getMainLooper());
    private ExoPlayer player;
    private MediaSession session;

    // ------------------------------------------------------------------------------------
    // the bridge

    static boolean play(Context ctx, JSONArray tracks, int index) {
        queue = tracks == null ? new JSONArray() : tracks;
        startAt = Math.max(0, index);
        error = null;
        Intent i = new Intent(ctx, MusicService.class).setAction("load");
        try {
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i); else ctx.startService(i);
            return true;
        } catch (Throwable t) {
            error = String.valueOf(t.getMessage());
            return false;
        }
    }

    static boolean command(Context ctx, final String what, final long posMs) {
        final MusicService s = running;
        if (s == null) return false;
        s.main.post(new Runnable() { @Override public void run() { s.handle(what, posMs); } });
        return true;
    }

    static JSONObject status() throws Exception {
        JSONObject l = last;
        if (l != null) return new JSONObject(l.toString());
        JSONObject o = new JSONObject().put("state", "idle");
        if (error != null) o.put("error", error);
        return o;
    }

    // ------------------------------------------------------------------------------------

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        running = this;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Jellyfin", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        player = new ExoPlayer.Builder(this)
            .setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build();
        player.addListener(new Player.Listener() {
            @Override public void onIsPlayingChanged(boolean isPlaying) { update(); }
            @Override public void onPlaybackStateChanged(int state) { update(); }
            @Override public void onMediaItemTransition(MediaItem item, int reason) { update(); }
            @Override public void onPlayerError(PlaybackException e) {
                error = e.getMessage();
                update();
            }
        });
        session = new MediaSession(this, "RoadTripJellyfin");
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { handle("play", 0); }
            @Override public void onPause() { handle("pause", 0); }
            @Override public void onStop() { handle("stop", 0); }
            @Override public void onSkipToNext() { handle("next", 0); }
            @Override public void onSkipToPrevious() { handle("prev", 0); }
            @Override public void onSeekTo(long pos) { handle("seek", pos); }
        });
        session.setActive(true);
        main.post(tick);
    }

    // a status snapshot twice a second, so Lua can read it without touching the player
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            snapshot();
            main.postDelayed(this, 500);
        }
    };

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        goForeground();
        String a = intent == null ? null : intent.getAction();
        if ("load".equals(a)) load();
        else if (a != null) handle(a, 0);
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        main.removeCallbacks(tick);
        if (player != null) player.release();
        if (session != null) session.release();
        running = null;
        last = null;
        super.onDestroy();
    }

    private void load() {
        List<MediaItem> items = new ArrayList<>();
        JSONArray q = queue;
        for (int i = 0; i < q.length(); i++) {
            JSONObject t = q.optJSONObject(i);
            if (t == null) continue;
            items.add(new MediaItem.Builder().setUri(Uri.parse(t.optString("url")))
                .setMediaMetadata(new androidx.media3.common.MediaMetadata.Builder()
                    .setTitle(t.optString("title")).setArtist(t.optString("artist"))
                    .setAlbumTitle(t.optString("album")).build())
                .build());
        }
        if (items.isEmpty()) return;
        player.setMediaItems(items, Math.min(startAt, items.size() - 1), 0);
        player.prepare();
        player.play();
        update();
    }

    private void handle(String what, long pos) {
        if (player == null) return;
        switch (what) {
            case "play": player.play(); break;
            case "pause": player.pause(); break;
            case "toggle": if (player.isPlaying()) player.pause(); else player.play(); break;
            case "next": player.seekToNextMediaItem(); break;
            case "prev":
                if (player.getCurrentPosition() > 4000) player.seekTo(0); else player.seekToPreviousMediaItem();
                break;
            case "seek": player.seekTo(Math.max(0, pos)); break;
            case "stop":
                player.stop();
                last = null;
                stopForeground(true);
                stopSelf();
                return;
        }
        update();
    }

    private JSONObject current() {
        int i = player.getCurrentMediaItemIndex();
        JSONObject t = queue.optJSONObject(i);
        return t == null ? new JSONObject() : t;
    }

    private void snapshot() {
        if (player == null) return;
        try {
            JSONObject o = new JSONObject();
            int st = player.getPlaybackState();
            String state = player.isPlaying() ? "playing"
                : st == Player.STATE_BUFFERING ? "connecting"
                : st == Player.STATE_ENDED ? "ended"
                : player.getPlayerError() != null ? "error" : "paused";
            o.put("state", state);
            if (error != null) o.put("error", error);
            o.put("index", player.getCurrentMediaItemIndex());
            o.put("count", player.getMediaItemCount());
            long d = player.getDuration();
            o.put("durationMs", d == C.TIME_UNSET ? 0 : d);
            o.put("positionMs", Math.max(0, player.getCurrentPosition()));
            o.put("track", current());
            last = o;
        } catch (Throwable ignored) {}
    }

    // ------------------------------------------------------------------------------------
    // notification and session

    private Bitmap art() {
        String p = current().optString("art", "");
        if (p.isEmpty()) return null;
        try { return BitmapFactory.decodeFile(p); } catch (Throwable t) { return null; }
    }

    private void update() {
        snapshot();
        JSONObject t = current();
        String title = t.optString("title", "Jellyfin");
        String artist = t.optString("artist", "");
        Bitmap art = art();
        boolean on = player != null && player.isPlaying();
        if (session != null) {
            MediaMetadata.Builder md = new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, t.optString("album", ""));
            long d = player == null ? 0 : player.getDuration();
            if (d != C.TIME_UNSET && d > 0) md.putLong(MediaMetadata.METADATA_KEY_DURATION, d);
            if (art != null) md.putBitmap(MediaMetadata.METADATA_KEY_ART, art);
            session.setMetadata(md.build());
            session.setPlaybackState(new PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
                    | PlaybackState.ACTION_STOP | PlaybackState.ACTION_SKIP_TO_NEXT
                    | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO)
                .setState(on ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
                    player == null ? 0 : player.getCurrentPosition(), on ? 1f : 0f)
                .build());
        }
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            nm.notify(NOTE_ID, build(title, artist, art, on));
        } catch (Throwable ignored) {}
    }

    private PendingIntent action(String what, int code) {
        Intent i = new Intent(this, MusicService.class).setAction(what);
        return PendingIntent.getService(this, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private Notification.Action act(int icon, String label, PendingIntent pi) {
        return new Notification.Action.Builder(Icon.createWithResource(this, icon), label, pi).build();
    }

    private Notification build(String title, String text, Bitmap art, boolean on) {
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title).setContentText(text)
            .setOngoing(on).setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC);
        Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (open != null) b.setContentIntent(PendingIntent.getActivity(this, 1, open, PendingIntent.FLAG_IMMUTABLE));
        if (art != null) b.setLargeIcon(art);
        b.addAction(act(android.R.drawable.ic_media_previous, "Previous", action("prev", 2)));
        b.addAction(act(on ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play,
            on ? "Pause" : "Play", action(on ? "pause" : "play", 3)));
        b.addAction(act(android.R.drawable.ic_media_next, "Next", action("next", 4)));
        b.addAction(act(android.R.drawable.ic_menu_close_clear_cancel, "Stop", action("stop", 5)));
        Notification.MediaStyle style = new Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2);
        if (session != null) style.setMediaSession(session.getSessionToken());
        b.setStyle(style);
        return b.build();
    }

    private void goForeground() {
        Notification n = build("Jellyfin", "", null, false);
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            else startForeground(NOTE_ID, n);
        } catch (Throwable ignored) {}
    }
}
