package app.roadtrip;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import org.json.JSONArray;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.Date;
import java.util.Locale;

/**
 * Notices when Android's main thread (touches, the keyboard, the browser and video views)
 * is stuck, and notes where it was stuck, for Settings → Diagnostics. It only watches.
 */
final class Watchdog {
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static final ArrayDeque<String> log = new ArrayDeque<>();
    private static volatile long lastBeat = SystemClock.uptimeMillis();
    private static boolean started = false;

    private Watchdog() {}

    static synchronized void start() {
        if (started) return;
        started = true;
        final Runnable beat = new Runnable() {
            @Override public void run() { lastBeat = SystemClock.uptimeMillis(); }
        };
        Thread t = new Thread(new Runnable() {
            @Override public void run() {
                boolean stuck = false;
                long stuckSince = 0;
                while (true) {
                    main.post(beat);
                    try { Thread.sleep(500); } catch (InterruptedException e) { return; }
                    long late = SystemClock.uptimeMillis() - lastBeat;
                    if (late > 1500 && !stuck) {
                        stuck = true;
                        stuckSince = lastBeat;
                        add("main thread stuck: " + where());
                    } else if (late < 600 && stuck) {
                        stuck = false;
                        add(String.format(Locale.US, "main thread free again after %.1fs",
                            (SystemClock.uptimeMillis() - stuckSince) / 1000.0));
                    }
                }
            }
        }, "RoadTripWatchdog");
        t.setDaemon(true);
        t.start();
    }

    // the main thread's top frames, skipping Android's own message loop
    private static String where() {
        StackTraceElement[] st = Looper.getMainLooper().getThread().getStackTrace();
        StringBuilder b = new StringBuilder();
        int n = 0;
        for (StackTraceElement e : st) {
            if (n >= 4) break;
            String c = e.getClassName();
            if (c.startsWith("android.os.MessageQueue") || c.startsWith("android.os.Looper")) continue;
            if (b.length() > 0) b.append(" < ");
            b.append(c.substring(c.lastIndexOf('.') + 1)).append('.').append(e.getMethodName())
                .append(':').append(e.getLineNumber());
            n++;
        }
        return b.length() == 0 ? "?" : b.toString();
    }

    static synchronized void add(String s) {
        log.addFirst(new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date()) + "  " + s);
        while (log.size() > 30) log.removeLast();
    }

    static synchronized JSONArray json() {
        JSONArray a = new JSONArray();
        for (String s : log) a.put(s);
        return a;
    }
}
