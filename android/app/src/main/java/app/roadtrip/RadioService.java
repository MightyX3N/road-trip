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
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.MediaPlayer;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Plays an internet radio stream in the background, with a media notification and a media
 * session so steering-wheel buttons and the system's media controls work.
 * Everything runs on the main thread; MediaPlayer prepares the stream asynchronously.
 */
public class RadioService extends Service {
    private static final String CHANNEL = "roadtrip_radio";
    private static final int NOTE_ID = 7041;

    // what's playing, read by the bridge from any thread
    private static volatile String state = "idle"; // idle | connecting | playing | paused | error
    private static volatile String error = null;
    private static volatile JSONObject station = null; // {uuid, name, url, art?, sub?}
    private static volatile JSONArray list = new JSONArray(); // favorites, for next / previous
    private static volatile RadioService running = null;
    private static boolean askedNotify = false;

    private final Handler main = new Handler(Looper.getMainLooper());
    private MediaPlayer player;
    private MediaSession session;
    private AudioManager audio;
    private AudioFocusRequest focusRequest;
    private boolean resumeOnFocus = false;
    private int retries = 0;
    private int generation = 0;

    // ------------------------------------------------------------------------------------
    // called by the bridge

    static JSONObject status() throws Exception {
        JSONObject o = new JSONObject();
        o.put("state", state);
        if (error != null) o.put("error", error);
        if (station != null) o.put("station", station);
        return o;
    }

    static boolean play(Context ctx, JSONObject st) {
        // Android 13+: the media notification needs permission (playing works without it)
        if (Build.VERSION.SDK_INT >= 33 && ctx instanceof android.app.Activity
                && ctx.checkSelfPermission("android.permission.POST_NOTIFICATIONS") != android.content.pm.PackageManager.PERMISSION_GRANTED
                && !askedNotify) {
            askedNotify = true;
            final android.app.Activity a = (android.app.Activity) ctx;
            a.runOnUiThread(new Runnable() {
                @Override public void run() { a.requestPermissions(new String[] { "android.permission.POST_NOTIFICATIONS" }, 7033); }
            });
        }
        station = st;
        state = "connecting";
        error = null;
        Intent i = new Intent(ctx, RadioService.class).setAction("play");
        try {
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i); else ctx.startService(i);
            return true;
        } catch (Throwable t) {
            state = "error";
            error = String.valueOf(t.getMessage());
            return false;
        }
    }

    static boolean command(Context ctx, String what) {
        RadioService s = running;
        if (s == null) {
            if ("play".equals(what) && station != null) return play(ctx, station);
            return false;
        }
        final String w = what;
        s.main.post(new Runnable() { @Override public void run() { s.handle(w); } });
        return true;
    }

    static void setList(JSONArray a) { if (a != null) list = a; }

    // ------------------------------------------------------------------------------------

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        running = this;
        audio = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        session = new MediaSession(this, "RoadTripRadio");
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { handle("play"); }
            @Override public void onPause() { handle("pause"); }
            @Override public void onStop() { handle("stop"); }
            @Override public void onSkipToNext() { handle("next"); }
            @Override public void onSkipToPrevious() { handle("prev"); }
        });
        session.setActive(true);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Radio", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // a foreground service must call startForeground quickly, every time it's started
        goForeground();
        if (intent != null && "play".equals(intent.getAction())) {
            retries = 0;
            start();
        } else if (intent != null && intent.getAction() != null) {
            handle(intent.getAction());
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        releasePlayer();
        abandonFocus();
        if (session != null) session.release();
        running = null;
        if (!"error".equals(state)) state = "idle";
        super.onDestroy();
    }

    private void handle(String what) {
        switch (what) {
            case "play":
                if (player != null && "paused".equals(state)) {
                    if (requestFocus()) { player.start(); state = "playing"; update(); }
                } else start();
                break;
            case "pause":
                // a live stream can't really pause: stop it, and start fresh on play
                releasePlayer();
                state = "paused";
                update();
                break;
            case "toggle":
                handle("playing".equals(state) || "connecting".equals(state) ? "pause" : "play");
                break;
            case "stop":
                releasePlayer();
                abandonFocus();
                state = "idle";
                stopForeground(true);
                stopSelf();
                break;
            case "next":
            case "prev":
                skip("next".equals(what) ? 1 : -1);
                break;
        }
    }

    private void skip(int dir) {
        JSONArray a = list;
        if (a == null || a.length() == 0) return;
        int at = -1;
        String cur = station == null ? "" : station.optString("uuid");
        for (int i = 0; i < a.length(); i++) {
            JSONObject o = a.optJSONObject(i);
            if (o != null && cur.equals(o.optString("uuid"))) { at = i; break; }
        }
        int n = a.length();
        int next = at < 0 ? 0 : ((at + dir) % n + n) % n;
        station = a.optJSONObject(next);
        retries = 0;
        start();
    }

    private void start() {
        final JSONObject st = station;
        if (st == null) return;
        releasePlayer();
        if (!requestFocus()) {
            state = "error";
            error = "Another app is using the audio";
            update();
            return;
        }
        state = "connecting";
        error = null;
        update();
        final int gen = ++generation;
        try {
            MediaPlayer mp = new MediaPlayer();
            player = mp;
            mp.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build());
            mp.setWakeMode(this, PowerManager.PARTIAL_WAKE_LOCK);
            mp.setDataSource(st.optString("url"));
            mp.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
                @Override public void onPrepared(MediaPlayer p) {
                    if (gen != generation) return;
                    p.start();
                    state = "playing";
                    retries = 0;
                    update();
                }
            });
            mp.setOnErrorListener(new MediaPlayer.OnErrorListener() {
                @Override public boolean onError(MediaPlayer p, int what, int extra) {
                    if (gen == generation) failed("The station isn't answering (" + what + "/" + extra + ")");
                    return true;
                }
            });
            mp.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
                @Override public void onCompletion(MediaPlayer p) {
                    // a live stream "ending" means the connection dropped
                    if (gen == generation) failed("The stream stopped");
                }
            });
            mp.prepareAsync();
        } catch (Throwable t) {
            failed("Can't play this station: " + t.getMessage());
        }
    }

    // reconnect a few times (tunnels, dead spots), then give up
    private void failed(String why) {
        releasePlayer();
        if (retries < 4) {
            retries++;
            state = "connecting";
            update();
            final int gen = generation;
            main.postDelayed(new Runnable() {
                @Override public void run() { if (gen == generation && "connecting".equals(state)) start(); }
            }, 2000L * retries);
        } else {
            state = "error";
            error = why;
            update();
        }
    }

    private void releasePlayer() {
        generation++;
        if (player != null) {
            try { player.reset(); } catch (Throwable ignored) {}
            try { player.release(); } catch (Throwable ignored) {}
            player = null;
        }
    }

    // ------------------------------------------------------------------------------------
    // audio focus: navigation prompts duck us, calls and other players pause us

    private final AudioManager.OnAudioFocusChangeListener focusListener = new AudioManager.OnAudioFocusChangeListener() {
        @Override
        public void onAudioFocusChange(int change) {
            switch (change) {
                case AudioManager.AUDIOFOCUS_LOSS:
                    resumeOnFocus = false;
                    handle("pause");
                    break;
                case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                    resumeOnFocus = "playing".equals(state) || "connecting".equals(state);
                    handle("pause");
                    break;
                case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                    if (player != null) player.setVolume(0.25f, 0.25f);
                    break;
                case AudioManager.AUDIOFOCUS_GAIN:
                    if (player != null) player.setVolume(1f, 1f);
                    if (resumeOnFocus) { resumeOnFocus = false; handle("play"); }
                    break;
            }
        }
    };

    private boolean requestFocus() {
        if (audio == null) return true;
        int r;
        if (Build.VERSION.SDK_INT >= 26) {
            if (focusRequest == null) {
                focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                    .setOnAudioFocusChangeListener(focusListener, main)
                    .setWillPauseWhenDucked(false)
                    .build();
            }
            r = audio.requestAudioFocus(focusRequest);
        } else {
            //noinspection deprecation
            r = audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
        }
        return r != AudioManager.AUDIOFOCUS_REQUEST_FAILED;
    }

    private void abandonFocus() {
        if (audio == null) return;
        if (Build.VERSION.SDK_INT >= 26) {
            if (focusRequest != null) audio.abandonAudioFocusRequest(focusRequest);
        } else {
            //noinspection deprecation
            audio.abandonAudioFocus(focusListener);
        }
    }

    // ------------------------------------------------------------------------------------
    // notification and media session

    private Bitmap art() {
        JSONObject st = station;
        String path = st == null ? null : st.optString("art", null);
        if (path == null || path.isEmpty()) return null;
        try { return BitmapFactory.decodeFile(path); } catch (Throwable t) { return null; }
    }

    private void update() {
        JSONObject st = station;
        String name = st == null ? "Radio" : st.optString("name", "Radio");
        String sub = st == null ? "" : st.optString("sub", "");
        String line;
        switch (state) {
            case "connecting": line = "Connecting…"; break;
            case "error": line = error == null ? "Can't play this station" : error; break;
            case "paused": line = "Paused"; break;
            default: line = sub.isEmpty() ? "Road Trip radio" : sub;
        }
        Bitmap art = art();
        if (session != null) {
            MediaMetadata.Builder md = new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, name)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, line)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, -1);
            if (art != null) md.putBitmap(MediaMetadata.METADATA_KEY_ART, art);
            session.setMetadata(md.build());
            int ps = "playing".equals(state) ? PlaybackState.STATE_PLAYING
                : "connecting".equals(state) ? PlaybackState.STATE_BUFFERING
                : "error".equals(state) ? PlaybackState.STATE_ERROR
                : "paused".equals(state) ? PlaybackState.STATE_PAUSED : PlaybackState.STATE_STOPPED;
            session.setPlaybackState(new PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
                    | PlaybackState.ACTION_STOP | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                .setState(ps, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
                .build());
        }
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            nm.notify(NOTE_ID, build(name, line, art));
        } catch (Throwable ignored) {}
    }

    private PendingIntent action(String what, int code) {
        Intent i = new Intent(this, RadioService.class).setAction(what);
        return PendingIntent.getService(this, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private Notification.Action act(int icon, String label, PendingIntent pi) {
        return new Notification.Action.Builder(Icon.createWithResource(this, icon), label, pi).build();
    }

    private Notification build(String title, String text, Bitmap art) {
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        boolean on = "playing".equals(state) || "connecting".equals(state);
        b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(on)
            .setShowWhen(false)
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
        JSONObject st = station;
        Notification n = build(st == null ? "Radio" : st.optString("name", "Radio"), "Connecting…", null);
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            else startForeground(NOTE_ID, n);
        } catch (Throwable t) {
            // not allowed right now (started from the background on a new Android): play anyway
        }
    }
}
