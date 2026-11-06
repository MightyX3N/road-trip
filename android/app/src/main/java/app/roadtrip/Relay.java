package app.roadtrip;

import android.util.Base64;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.EnumMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Typing from your phone. The box and the phone are usually on different networks (the box on
 * its own SIM), so text goes through ntfy.sh, a free public message relay. Road Trip makes a
 * long random channel and a random key, both only in the QR code; the phone's page (on Road
 * Trip's website) encrypts with AES-GCM before sending, so the relay only sees scrambled text,
 * and anything not encrypted with the key is ignored. The channel is dropped when the field
 * closes.
 */
final class Relay {
    private static final String SERVER = "https://ntfy.sh/";
    private static final String PAGE = "https://mightyx3n.github.io/road-trip/type.html#";
    private static final SecureRandom rnd = new SecureRandom();

    private static volatile String topic = null;
    private static volatile byte[] key = null;
    private static volatile int session = 0;
    private static volatile String status = "off"; // off | connecting | ready | error
    private static volatile String error = null;
    private static volatile HttpURLConnection conn = null;
    private static final ArrayDeque<JSONObject> inbox = new ArrayDeque<>();

    private Relay() {}

    private static String b64(byte[] b) {
        return Base64.encodeToString(b, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static String randomTopic() {
        String abc = "abcdefghijkmnpqrstuvwxyz23456789";
        StringBuilder s = new StringBuilder("roadtrip-");
        for (int i = 0; i < 24; i++) s.append(abc.charAt(rnd.nextInt(abc.length())));
        return s.toString();
    }

    /** Starts a channel; returns the page address and its QR code (rows of 0 and 1). */
    static synchronized JSONObject start(final String label) throws Exception {
        stop();
        final String t = randomTopic();
        byte[] k = new byte[32];
        rnd.nextBytes(k);
        topic = t;
        key = k;
        final int my = ++session;
        status = "connecting";
        error = null;
        synchronized (inbox) { inbox.clear(); }
        final String url = PAGE + t + "." + b64(k);
        final long since = System.currentTimeMillis() / 1000 - 5;
        Thread th = new Thread(new Runnable() {
            @Override public void run() { listen(my, t, since, label); }
        }, "roadtrip-relay");
        th.setDaemon(true);
        th.start();
        return new JSONObject().put("url", url).put("qr", qr(url));
    }

    static synchronized boolean stop() {
        session++;
        topic = null;
        key = null;
        status = "off";
        HttpURLConnection c = conn;
        conn = null;
        if (c != null) {
            final HttpURLConnection cc = c;
            new Thread(new Runnable() { @Override public void run() { try { cc.disconnect(); } catch (Throwable ignored) {} } }).start();
        }
        return true;
    }

    /** What arrived since the last call: [{t: text|enter|backspace, v}] */
    static JSONObject poll() throws Exception {
        JSONArray a = new JSONArray();
        synchronized (inbox) {
            while (!inbox.isEmpty()) a.put(inbox.pollFirst());
        }
        JSONObject o = new JSONObject().put("status", status).put("msgs", a);
        if (error != null) o.put("error", error);
        return o;
    }

    // ------------------------------------------------------------------------------------

    private static void listen(int my, String t, long since, String label) {
        Set<String> seen = new HashSet<>();
        boolean announced = false;
        while (session == my) {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(SERVER + t + "/json?since=" + since).openConnection();
                c.setConnectTimeout(15000);
                c.setReadTimeout(90000); // the relay sends a keepalive about every 45 s
                c.setRequestProperty("User-Agent", Net.UA);
                conn = c;
                if (c.getResponseCode() >= 400) throw new Exception("HTTP " + c.getResponseCode());
                status = "ready";
                error = null;
                if (!announced) {
                    // tell the page which field it's typing into
                    announced = true;
                    publish(t, new JSONObject().put("t", "field").put("v", label));
                }
                BufferedReader in = new BufferedReader(new InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8));
                String line;
                while (session == my && (line = in.readLine()) != null) {
                    JSONObject ev;
                    try { ev = new JSONObject(line); } catch (Throwable bad) { continue; }
                    if (!"message".equals(ev.optString("event"))) continue;
                    String id = ev.optString("id");
                    if (seen.contains(id)) continue;
                    seen.add(id);
                    since = Math.max(since, ev.optLong("time", since));
                    JSONObject m = open(ev.optString("message"));
                    if (m == null) continue; // not from the page with our key
                    synchronized (inbox) { inbox.addLast(m); }
                    publish(t, new JSONObject().put("t", "ack").put("n", m.optInt("n")));
                }
            } catch (Throwable e) {
                if (session != my) return;
                status = "error";
                error = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                try { Thread.sleep(3000); } catch (InterruptedException ie) { return; }
            } finally {
                if (c != null) try { c.disconnect(); } catch (Throwable ignored) {}
            }
        }
    }

    // AES-GCM: "iv.ciphertext", both base64url
    private static JSONObject open(String body) {
        byte[] k = key;
        if (k == null || body == null) return null;
        int dot = body.indexOf('.');
        if (dot < 1) return null;
        try {
            byte[] iv = Base64.decode(body.substring(0, dot), Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            byte[] ct = Base64.decode(body.substring(dot + 1), Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(k, "AES"), new GCMParameterSpec(128, iv));
            JSONObject m = new JSONObject(new String(c.doFinal(ct), StandardCharsets.UTF_8));
            if (m.optString("from").equals("box")) return null; // our own messages on the way back
            return m;
        } catch (Throwable t) {
            return null;
        }
    }

    private static void publish(String t, JSONObject m) {
        byte[] k = key;
        if (k == null) return;
        try {
            m.put("from", "box");
            byte[] iv = new byte[12];
            rnd.nextBytes(iv);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(k, "AES"), new GCMParameterSpec(128, iv));
            String body = b64(iv) + "." + b64(c.doFinal(m.toString().getBytes(StandardCharsets.UTF_8)));
            HttpURLConnection h = (HttpURLConnection) new URL(SERVER + t).openConnection();
            h.setConnectTimeout(15000);
            h.setReadTimeout(15000);
            h.setDoOutput(true);
            h.setRequestMethod("POST");
            h.setRequestProperty("User-Agent", Net.UA);
            try (OutputStream o = h.getOutputStream()) { o.write(body.getBytes(StandardCharsets.UTF_8)); }
            h.getResponseCode();
            h.disconnect();
        } catch (Throwable ignored) {}
    }

    private static JSONArray qr(String text) throws Exception {
        Map<EncodeHintType, Object> hints = new EnumMap<>(EncodeHintType.class);
        hints.put(EncodeHintType.MARGIN, 0);
        hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M);
        BitMatrix m = new QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, hints);
        JSONArray rows = new JSONArray();
        for (int y = 0; y < m.getHeight(); y++) {
            StringBuilder r = new StringBuilder(m.getWidth());
            for (int x = 0; x < m.getWidth(); x++) r.append(m.get(x, y) ? '1' : '0');
            rows.put(r.toString());
        }
        return rows;
    }
}
