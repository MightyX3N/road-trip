package app.roadtrip;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.TextView;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.common.VideoSize;

import org.json.JSONObject;

/**
 * Android views inside Road Trip's own screen, in a rectangle Lua chooses: the web browser
 * (Android's Chromium WebView) and the Jellyfin video player. LÖVE can't draw either itself.
 * While the car moves (the same rule as the video cover) the picture is covered; video sound
 * keeps going.
 */
final class Panel {
    private static final Handler main = new Handler(Looper.getMainLooper());

    private static Activity act;
    private static FrameLayout root;     // over the whole activity, lets touches through
    private static FrameLayout box;      // the rectangle
    private static TextView cover;
    private static String kind = "";     // "" | web | video
    private static boolean shown = false;
    private static JSONObject labels = new JSONObject();

    private static WebView web;
    private static volatile String webUrl = "", webTitle = "";
    private static volatile int webProgress = 100;
    private static volatile boolean webBack = false, webFwd = false;

    private static ExoPlayer video;
    // a TextureView, not a SurfaceView: it draws inside the window, over LÖVE's own surface.
    // (A second SurfaceView can end up behind LÖVE's and never be seen.) It stretches to its
    // size, so Lua sizes it to the video's shape; the controls are drawn by Lua.
    private static TextureView videoView;
    private static volatile int videoW = 0, videoH = 0;
    private static volatile JSONObject videoStatus = new JSONObject();

    private Panel() {}

    private static void ui(Runnable r) { main.post(r); }

    private static void ensureRoot(Activity a) {
        if (root != null && act == a) return;
        act = a;
        root = new FrameLayout(a);
        root.setClickable(false);
        root.setFocusable(false);
        box = new FrameLayout(a);
        box.setBackgroundColor(Color.BLACK);
        box.setVisibility(View.GONE);
        root.addView(box, new FrameLayout.LayoutParams(1, 1));
        a.addContentView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        cover = new TextView(a);
        cover.setBackgroundColor(0xF70E0F11);
        cover.setTextColor(0xFFE8E5DD);
        cover.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        cover.setGravity(Gravity.CENTER);
        cover.setPadding(40, 40, 40, 40);
        cover.setClickable(true); // the page underneath can't be used either
        cover.setVisibility(View.GONE);
        main.post(TICK);
    }

    /** Shows `k` (web | video) in the rectangle, in real pixels. */
    static boolean show(final Activity a, final String k, final int x, final int y, final int w, final int h) {
        ui(new Runnable() {
            @Override public void run() {
                ensureRoot(a);
                if (!k.equals(kind)) {
                    box.removeAllViews();
                    if ("web".equals(k)) box.addView(webView(a), match());
                    else if ("video".equals(k)) box.addView(videoView(a), match());
                    box.addView(cover, match());
                    kind = k;
                }
                FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Math.max(1, w), Math.max(1, h));
                lp.leftMargin = x;
                lp.topMargin = y;
                box.setLayoutParams(lp);
                box.setVisibility(View.VISIBLE);
                shown = true;
                if (web != null && "web".equals(k)) web.onResume();
                tick();
            }
        });
        return true;
    }

    static boolean hide() {
        ui(new Runnable() {
            @Override public void run() {
                if (box != null) box.setVisibility(View.GONE);
                shown = false;
                if (web != null) web.onPause();
                if (video != null && "video".equals(kind)) video.pause();
            }
        });
        return true;
    }

    static void setLabels(JSONObject l) { if (l != null) labels = l; }

    private static FrameLayout.LayoutParams match() {
        return new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
    }

    // ------------------------------------------------------------------------------------
    // the browser

    private static WebView webView(Activity a) {
        if (web != null) {
            if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
            return web;
        }
        web = new WebView(a);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(true);
        s.setDisplayZoomControls(false);
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                String sc = r.getUrl().getScheme();
                return !("http".equals(sc) || "https".equals(sc)); // other schemes (intent:, tel:) stay out
            }
            @Override public void onPageStarted(WebView v, String url, Bitmap fav) { webUrl = url; nav(); }
            @Override public void onPageFinished(WebView v, String url) { webUrl = url; nav(); }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onProgressChanged(WebView v, int p) { webProgress = p; }
            @Override public void onReceivedTitle(WebView v, String t) { webTitle = t == null ? "" : t; }
        });
        return web;
    }

    private static void nav() {
        if (web == null) return;
        webBack = web.canGoBack();
        webFwd = web.canGoForward();
    }

    static boolean webCommand(final String what, final String url) {
        ui(new Runnable() {
            @Override public void run() {
                if (web == null) return;
                switch (what) {
                    case "load": web.loadUrl(url); break;
                    case "back": if (web.canGoBack()) web.goBack(); break;
                    case "forward": if (web.canGoForward()) web.goForward(); break;
                    case "reload": web.reload(); break;
                    case "stop": web.stopLoading(); break;
                }
                nav();
            }
        });
        return true;
    }

    static JSONObject webStatus() throws Exception {
        return new JSONObject().put("url", webUrl).put("title", webTitle).put("progress", webProgress)
            .put("canBack", webBack).put("canForward", webFwd).put("open", web != null);
    }

    // ------------------------------------------------------------------------------------
    // video

    private static View videoView(Activity a) {
        if (videoView != null) {
            if (videoView.getParent() instanceof ViewGroup) ((ViewGroup) videoView.getParent()).removeView(videoView);
            return videoView;
        }
        video = new ExoPlayer.Builder(a)
            .setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build();
        video.addListener(new Player.Listener() {
            @Override public void onPlayerError(PlaybackException e) {
                try { videoStatus = new JSONObject(videoStatus.toString()).put("error", describe(e)); } catch (Exception ignored) {}
            }
            @Override public void onVideoSizeChanged(VideoSize vs) {
                videoW = Math.round(vs.width * (vs.pixelWidthHeightRatio > 0 ? vs.pixelWidthHeightRatio : 1f));
                videoH = vs.height;
            }
        });
        videoView = new TextureView(a);
        videoView.setKeepScreenOn(true);
        video.setVideoTextureView(videoView);
        return videoView;
    }

    static boolean videoPlay(final Activity a, final String url, final long startMs) {
        ui(new Runnable() {
            @Override public void run() {
                ensureRoot(a);
                if (video == null) videoView(a);
                MusicService.command(a, "pause", 0);
                videoW = 0;
                videoH = 0;
                video.setMediaItem(MediaItem.fromUri(Uri.parse(url).toString()), Math.max(0, startMs));
                video.prepare();
                video.play();
            }
        });
        return true;
    }

    static boolean videoCommand(final String what, final long pos) {
        ui(new Runnable() {
            @Override public void run() {
                if (video == null) return;
                switch (what) {
                    case "toggle": if (video.isPlaying()) video.pause(); else video.play(); break;
                    case "play": video.play(); break;
                    case "pause": video.pause(); break;
                    case "seek": video.seekTo(Math.max(0, pos)); break;
                    case "stop": video.stop(); video.clearMediaItems(); break;
                }
            }
        });
        return true;
    }

    static JSONObject videoStatus() throws Exception { return new JSONObject(videoStatus.toString()); }

    // ------------------------------------------------------------------------------------

    private static final Runnable TICK = new Runnable() {
        @Override public void run() {
            main.removeCallbacks(this);
            tick();
            main.postDelayed(this, 500);
        }
    };

    private static void tick() {
        // covered while the car moves; video sound carries on
        boolean drive = Overlay.drivingNow();
        if (cover != null) {
            String t = label(kind.equals("web") ? "web" : "video",
                kind.equals("web") ? "The browser is hidden while you drive" : "Video hidden while driving. The sound keeps playing.");
            // no speed at all (a box without GPS): say why, and where to change it
            if (Overlay.speedUnknown) t = t + "\n\n" + label("noSpeed", "This box can't tell your speed, so it counts as driving. Change it in Settings under \"When the speed isn't known\".");
            cover.setText(t);
            cover.setVisibility(shown && drive ? View.VISIBLE : View.GONE);
        }
        // leaving Road Trip pauses the video (it lives in Road Trip's own screen)
        if (video != null && !Overlay.roadTripResumed && video.isPlaying()) video.pause();
        if (video != null) {
            try {
                JSONObject o = new JSONObject();
                long d = video.getDuration();
                o.put("state", video.isPlaying() ? "playing"
                    : video.getPlaybackState() == Player.STATE_BUFFERING ? "connecting"
                    : video.getPlaybackState() == Player.STATE_ENDED ? "ended"
                    : video.getPlaybackState() == Player.STATE_IDLE ? "idle" : "paused");
                o.put("positionMs", Math.max(0, video.getCurrentPosition()));
                o.put("durationMs", d == C.TIME_UNSET ? 0 : d);
                o.put("width", videoW).put("height", videoH);
                o.put("url", video.getCurrentMediaItem() == null || video.getCurrentMediaItem().localConfiguration == null
                    ? "" : String.valueOf(video.getCurrentMediaItem().localConfiguration.uri));
                PlaybackException e = video.getPlayerError();
                if (e != null) o.put("error", describe(e));
                videoStatus = o;
            } catch (Throwable ignored) {}
        }
    }

    // the error code name says more than the message ("ERROR_CODE_IO_BAD_HTTP_STATUS")
    private static String describe(PlaybackException e) {
        String m = e.getErrorCodeName();
        Throwable c = e.getCause();
        if (c != null && c.getMessage() != null) m += ": " + c.getMessage();
        else if (e.getMessage() != null) m += ": " + e.getMessage();
        return m;
    }

    private static String label(String k, String fallback) {
        String v = labels.optString(k, "");
        return v.isEmpty() ? fallback : v;
    }
}
