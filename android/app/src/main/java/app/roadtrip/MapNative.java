package app.roadtrip;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.RelativeLayout;

import org.json.JSONArray;
import org.json.JSONObject;
import org.maplibre.android.MapLibre;
import org.maplibre.android.camera.CameraPosition;
import org.maplibre.android.camera.CameraUpdateFactory;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.maps.MapLibreMap;
import org.maplibre.android.maps.MapLibreMapOptions;
import org.maplibre.android.maps.MapView;
import org.maplibre.android.maps.OnMapReadyCallback;
import org.maplibre.android.maps.Style;
import org.maplibre.android.module.http.HttpRequestUtil;
import org.maplibre.android.style.expressions.Expression;
import org.maplibre.android.style.layers.CircleLayer;
import org.maplibre.android.style.layers.LineLayer;
import org.maplibre.android.style.layers.Property;
import org.maplibre.android.style.layers.PropertyFactory;
import org.maplibre.android.style.layers.SymbolLayer;
import org.maplibre.android.style.sources.GeoJsonSource;
import org.maplibre.android.style.sources.Source;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

/**
 * The map, drawn by MapLibre (Android's native vector-map engine) underneath LÖVE. LÖVE's
 * surface sits on top and is see-through where Lua leaves a hole, so Road Trip's own buttons
 * and turn card stay drawn by Lua over the map. Touches all go to LÖVE; Lua moves the camera.
 *
 * Styles: OpenFreeMap's (Liberty, Bright, Positron, Dark, Fiord) and Waypoint's 38 game-inspired
 * worlds (github.com/the-geeky-couldron/waypoint, MIT licence), bundled in assets/waypoint.
 * Tiles come from OpenFreeMap; downloaded offline areas are served from Road Trip's files.
 */
final class MapNative {
    private static final String PREFS = "roadtrip_map";
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static final String EMPTY = "{\"type\":\"FeatureCollection\",\"features\":[]}";

    private static Activity act;
    private static MapView view;
    private static MapLibreMap map;
    private static volatile boolean ready = false, failed = false, styleLoaded = false, shown = false;
    private static volatile String error = null, styleId = null, loadingId = null;
    private static volatile String saveDir = null;
    private static float luaScale = 1f; // Lua's virtual units -> pixels
    private static String accent = "#F2A23A";

    // what's on the map, kept so it can go back on after a style change
    private static String routeJson = EMPTY, altJson = EMPTY, posJson = EMPTY, destJson = EMPTY;
    private static float routeWidth = 8f;

    private MapNative() {}

    // problems go to Settings → Diagnostics too
    private static void err(String msg) {
        error = msg;
        Watchdog.add("map: " + msg);
    }

    // ------------------------------------------------------------------------------------
    // which engine (read before LÖVE's surface is made, so it's a saved preference)

    private static SharedPreferences prefs(Context c) { return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE); }

    static boolean wanted(Context c) { return !"classic".equals(prefs(c).getString("engine", "maplibre")); }

    static String engine(Context c) { return wanted(c) ? "maplibre" : "classic"; }

    /** Saves the choice and starts Road Trip again with it. */
    static boolean setEngine(Context c, String e) {
        prefs(c).edit().putString("engine", "classic".equals(e) ? "classic" : "maplibre").commit();
        try {
            Intent i = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
            if (i != null) {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
                PendingIntent pi = PendingIntent.getActivity(c, 7702, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_CANCEL_CURRENT);
                AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
                am.set(AlarmManager.RTC, System.currentTimeMillis() + 400, pi);
            }
        } catch (Throwable ignored) {}
        main.postDelayed(new Runnable() { @Override public void run() { Runtime.getRuntime().exit(0); } }, 150);
        return true;
    }

    // ------------------------------------------------------------------------------------
    // set-up, from RoadTripActivity.onCreate

    static void attach(Activity a, ViewGroup layout) {
        act = a;
        try {
            MapLibre.getInstance(a);
            HttpRequestUtil.setOkHttpClient(new OkHttpClient.Builder().addInterceptor(new Local(a)).build());
            MapLibreMapOptions o = MapLibreMapOptions.createFromAttributes(a)
                .textureMode(false).logoEnabled(false).attributionEnabled(false).compassEnabled(false)
                .pixelRatio(ratio()); // a bit bigger than the phone default: read at a glance, at arm's length
            view = new MapView(a, o);
            view.onCreate(null);
            view.addOnDidFailLoadingMapListener(new MapView.OnDidFailLoadingMapListener() {
                @Override public void onDidFailLoadingMap(String msg) { err(msg); }
            });
            // first in the layout, so LÖVE's surface (added after) gets every touch
            layout.addView(view, 0, new RelativeLayout.LayoutParams(1, 1));
            view.getMapAsync(new OnMapReadyCallback() {
                @Override public void onMapReady(MapLibreMap m) {
                    map = m;
                    m.getUiSettings().setAllGesturesEnabled(false);
                    ready = true;
                    String want = loadingId != null ? loadingId : "ofm:liberty";
                    loadingId = null;
                    loadStyle(want);
                }
            });
        } catch (Throwable t) {
            failed = true;
            err(String.valueOf(t));
            view = null;
        }
    }

    static void onStart() { if (view != null) view.onStart(); }
    static void onResume() { if (view != null) view.onResume(); }
    static void onPause() { if (view != null) view.onPause(); }
    static void onStop() { if (view != null) view.onStop(); }
    static void onDestroy() { if (view != null) view.onDestroy(); }
    static void onLowMemory() { if (view != null) view.onLowMemory(); }

    private static void ui(Runnable r) { main.post(r); }

    // ------------------------------------------------------------------------------------
    // the bridge

    static boolean init(JSONObject a) {
        saveDir = a.optString("saveDir", saveDir);
        luaScale = (float) a.optDouble("scale", luaScale);
        accent = a.optString("accent", accent);
        return view != null;
    }

    static JSONObject status() throws Exception {
        return new JSONObject().put("engine", act == null ? "classic" : engine(act)).put("attached", view != null)
            .put("ready", ready).put("failed", failed).put("styleLoaded", styleLoaded)
            .put("style", styleId == null ? "" : styleId).put("error", error == null ? "" : error);
    }

    /** Where the map shows, in real pixels; Lua leaves that part of its screen see-through. */
    static boolean show(final int x, final int y, final int w, final int h) {
        if (view == null) return false;
        ui(new Runnable() {
            @Override public void run() {
                RelativeLayout.LayoutParams lp = new RelativeLayout.LayoutParams(Math.max(1, w), Math.max(1, h));
                lp.leftMargin = x;
                lp.topMargin = y;
                view.setLayoutParams(lp);
                shown = true;
            }
        });
        return true;
    }

    static boolean hide() {
        if (view == null) return false;
        ui(new Runnable() {
            @Override public void run() {
                view.setLayoutParams(new RelativeLayout.LayoutParams(1, 1));
                shown = false;
            }
        });
        return true;
    }

    /** Lua's view: its zoom (512-unit tiles in its units), heading, tilt, where the car sits. */
    static boolean camera(final JSONObject a) {
        if (view == null) return false;
        ui(new Runnable() {
            @Override public void run() {
                if (map == null) return;
                try {
                    double zoom = a.getDouble("zoom") + Math.log(luaScale / ratio()) / Math.log(2);
                    zoom = Math.max(0, Math.min(21, zoom));
                    double ahead = a.optDouble("ahead", 0.5); // where the target sits, 0.5 = middle
                    int h = view.getHeight();
                    double top = ahead > 0.5 ? (2 * ahead - 1) * h : 0;
                    double bottom = ahead < 0.5 ? (1 - 2 * ahead) * h : 0;
                    CameraPosition p = new CameraPosition.Builder()
                        .target(new LatLng(a.getDouble("lat"), a.getDouble("lon")))
                        .zoom(zoom).bearing(a.optDouble("bearing", 0)).tilt(Math.max(0, Math.min(60, a.optDouble("tilt", 0))))
                        .padding(0, top, 0, bottom).build();
                    int ms = a.optInt("ms", 0);
                    if (ms > 0) map.easeCamera(CameraUpdateFactory.newCameraPosition(p), ms, false);
                    else map.moveCamera(CameraUpdateFactory.newCameraPosition(p));
                } catch (Throwable t) {
                    err(String.valueOf(t));
                }
            }
        });
        return true;
    }

    static boolean setStyle(final String id) {
        if (view == null) return false;
        ui(new Runnable() { @Override public void run() { loadStyle(id); } });
        return true;
    }

    /** The route: { route: [{c: [[lon,lat]...], color}], alt: [[[lon,lat]...]], width (Lua units) } */
    static boolean route(JSONObject a) throws Exception {
        routeWidth = (float) a.optDouble("width", 16) * luaScale / ratio();
        routeJson = lines(a.optJSONArray("route"), null);
        altJson = lines(a.optJSONArray("alt"), "#8A8D93");
        ui(new Runnable() { @Override public void run() { pushOverlays(); } });
        return true;
    }

    /** You and where you're going: { pos: {lat, lon, bearing, acc}, dest: {lat, lon} } */
    static boolean markers(JSONObject a) throws Exception {
        JSONObject p = a.optJSONObject("pos");
        if (p != null) {
            double lat = p.getDouble("lat"), lon = p.getDouble("lon");
            double acc = p.optDouble("acc", 0);
            double bearing = p.optDouble("bearing", -1);
            // accuracy in pixels at zoom 0, so the circle can grow with the zoom
            double r0 = acc / (40075016.686 * Math.cos(Math.toRadians(lat)) / 512.0);
            posJson = String.format(Locale.US,
                "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[%.7f,%.7f]},"
                    + "\"properties\":{\"bearing\":%.1f,\"moving\":%s,\"r0\":%.9f}}",
                lon, lat, Math.max(0, bearing), bearing >= 0 ? "true" : "false", r0);
        } else {
            posJson = EMPTY;
        }
        JSONObject d = a.optJSONObject("dest");
        destJson = d == null ? EMPTY : String.format(Locale.US,
            "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[%.7f,%.7f]},\"properties\":{}}",
            d.getDouble("lon"), d.getDouble("lat"));
        ui(new Runnable() { @Override public void run() { pushMarkers(); } });
        return true;
    }

    private static float density() { return act == null ? 1f : act.getResources().getDisplayMetrics().density; }
    /** MapLibre's pixels per point: labels and lines 35% larger than Android's default, so a
     *  low-resolution car screen still shows street names you can read. */
    static final float MAP_TEXT = 1.35f;
    private static float ratio() { return density() * MAP_TEXT; }

    private static String lines(JSONArray list, String color) throws Exception {
        if (list == null || list.length() == 0) return EMPTY;
        StringBuilder b = new StringBuilder("{\"type\":\"FeatureCollection\",\"features\":[");
        for (int i = 0; i < list.length(); i++) {
            Object o = list.get(i);
            JSONArray c;
            String col = color;
            if (o instanceof JSONObject) {
                c = ((JSONObject) o).getJSONArray("c");
                col = ((JSONObject) o).optString("color", color == null ? accent : color);
            } else {
                c = (JSONArray) o;
            }
            if (col == null) col = accent;
            if (i > 0) b.append(',');
            b.append("{\"type\":\"Feature\",\"properties\":{\"color\":").append(JSONObject.quote(col))
                .append("},\"geometry\":{\"type\":\"LineString\",\"coordinates\":").append(c.toString()).append("}}");
        }
        return b.append("]}").toString();
    }

    // ------------------------------------------------------------------------------------
    // styles

    private static void loadStyle(final String id) {
        if (map == null) { loadingId = id; return; }
        if (id.equals(styleId) && styleLoaded) return;
        styleId = id;
        styleLoaded = false;
        error = null;
        Style.Builder b;
        try {
            if (id.startsWith("wp:")) {
                String file = id.substring(3).replaceAll("[^a-z0-9_]", "");
                b = new Style.Builder().fromJson(readAsset("waypoint/styles/" + file + ".json"));
            } else {
                String name = id.startsWith("ofm:") ? id.substring(4).replaceAll("[^a-z]", "") : "liberty";
                b = new Style.Builder().fromUri("https://tiles.openfreemap.org/styles/" + name);
            }
        } catch (Throwable t) {
            err("style " + id + ": " + t);
            b = new Style.Builder().fromUri("https://tiles.openfreemap.org/styles/liberty");
        }
        map.setStyle(b, new Style.OnStyleLoaded() {
            @Override public void onStyleLoaded(Style s) {
                if (!id.equals(styleId)) return;
                try {
                    for (String img : new String[] { "pixel_grass", "pixel_stone", "pixel_water", "paper_fibre" }) {
                        Bitmap bm = BitmapFactory.decodeStream(act.getAssets().open("waypoint/images/" + img + ".png"));
                        if (bm != null) s.addImage(img.replace('_', '-'), bm);
                    }
                } catch (Throwable ignored) {}
                addOverlays(s);
                styleLoaded = true;
            }
        });
    }

    private static String readAsset(String path) throws IOException {
        try (InputStream in = act.getAssets().open(path)) {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) o.write(buf, 0, n);
            return o.toString("UTF-8");
        }
    }

    // Road Trip's own layers over any style: route, you, your destination
    private static void addOverlays(Style s) {
        try {
            s.addImage("rt-arrow", arrow());
            s.addImage("rt-pin", pin());
            s.addSource(new GeoJsonSource("rt-alt", altJson));
            s.addSource(new GeoJsonSource("rt-route", routeJson));
            s.addSource(new GeoJsonSource("rt-dest", destJson));
            s.addSource(new GeoJsonSource("rt-pos", posJson));
            s.addLayer(new LineLayer("rt-alt-line", "rt-alt").withProperties(
                PropertyFactory.lineColor(Expression.get("color")), PropertyFactory.lineWidth(routeWidth * 0.6f),
                PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND), PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                PropertyFactory.lineOpacity(0.8f)));
            s.addLayer(new LineLayer("rt-route-casing", "rt-route").withProperties(
                PropertyFactory.lineColor("#0E0F11"), PropertyFactory.lineWidth(routeWidth + 5f),
                PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND), PropertyFactory.lineCap(Property.LINE_CAP_ROUND)));
            s.addLayer(new LineLayer("rt-route-line", "rt-route").withProperties(
                PropertyFactory.lineColor(Expression.get("color")), PropertyFactory.lineWidth(routeWidth),
                PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND), PropertyFactory.lineCap(Property.LINE_CAP_ROUND)));
            s.addLayer(new SymbolLayer("rt-dest-pin", "rt-dest").withProperties(
                PropertyFactory.iconImage("rt-pin"), PropertyFactory.iconAnchor(Property.ICON_ANCHOR_BOTTOM),
                PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true)));
            Expression r0 = Expression.get("r0");
            s.addLayer(new CircleLayer("rt-pos-acc", "rt-pos").withProperties(
                PropertyFactory.circleRadius(Expression.interpolate(Expression.exponential(2), Expression.zoom(),
                    Expression.literal(0), r0, Expression.literal(22), Expression.product(r0, Expression.literal(4194304)))),
                PropertyFactory.circleColor(accent), PropertyFactory.circleOpacity(0.14f),
                PropertyFactory.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP)));
            s.addLayer(new CircleLayer("rt-pos-puck", "rt-pos").withProperties(
                PropertyFactory.circleRadius(11f), PropertyFactory.circleColor("#E8E5DD"),
                PropertyFactory.circleStrokeColor("#0E0F11"), PropertyFactory.circleStrokeWidth(1.5f),
                PropertyFactory.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP)));
            s.addLayer(new CircleLayer("rt-pos-dot", "rt-pos").withProperties(
                PropertyFactory.circleRadius(5.5f), PropertyFactory.circleColor(accent),
                PropertyFactory.circleOpacity(Expression.switchCase(Expression.get("moving"), Expression.literal(0), Expression.literal(1))),
                PropertyFactory.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP)));
            s.addLayer(new SymbolLayer("rt-pos-arrow", "rt-pos").withProperties(
                PropertyFactory.iconImage("rt-arrow"), PropertyFactory.iconRotate(Expression.get("bearing")),
                PropertyFactory.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
                PropertyFactory.iconPitchAlignment(Property.ICON_PITCH_ALIGNMENT_MAP),
                PropertyFactory.iconOpacity(Expression.switchCase(Expression.get("moving"), Expression.literal(1), Expression.literal(0))),
                PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true)));
        } catch (Throwable t) {
            err("overlay: " + t);
        }
    }

    private static void setJson(Style s, String id, String json) {
        Source src = s.getSource(id);
        if (src instanceof GeoJsonSource) ((GeoJsonSource) src).setGeoJson(json);
    }

    private static void pushOverlays() {
        if (map == null || !styleLoaded) return;
        Style s = map.getStyle();
        if (s == null) return;
        setJson(s, "rt-route", routeJson);
        setJson(s, "rt-alt", altJson);
        try {
            if (s.getLayer("rt-route-line") != null) {
                s.getLayer("rt-route-line").setProperties(PropertyFactory.lineWidth(routeWidth));
                s.getLayer("rt-route-casing").setProperties(PropertyFactory.lineWidth(routeWidth + 5f));
                s.getLayer("rt-alt-line").setProperties(PropertyFactory.lineWidth(routeWidth * 0.6f));
            }
        } catch (Throwable ignored) {}
    }

    private static void pushMarkers() {
        if (map == null || !styleLoaded) return;
        Style s = map.getStyle();
        if (s == null) return;
        setJson(s, "rt-pos", posJson);
        setJson(s, "rt-dest", destJson);
    }

    private static Bitmap arrow() {
        float d = density();
        int n = Math.round(22 * d);
        Bitmap b = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setColor(Color.parseColor("#0E0F11"));
        Path path = new Path();
        float k = n / 22f;
        path.moveTo(11 * k, 2 * k);
        path.lineTo(19 * k, 19 * k);
        path.lineTo(11 * k, 15 * k);
        path.lineTo(3 * k, 19 * k);
        path.close();
        c.drawPath(path, p);
        return b;
    }

    private static Bitmap pin() {
        float d = density();
        int w = Math.round(32 * d), h = Math.round(44 * d);
        Bitmap b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setColor(Color.parseColor("#0E0F11"));
        c.drawCircle(w / 2f, w / 2f, w / 2f, p);
        Path path = new Path();
        path.moveTo(w * 0.2f, w * 0.75f);
        path.lineTo(w * 0.8f, w * 0.75f);
        path.lineTo(w / 2f, h);
        path.close();
        c.drawPath(path, p);
        p.setColor(Color.parseColor("#E8E5DD"));
        c.drawCircle(w / 2f, w / 2f, w / 2f - 3 * d, p);
        Path tip = new Path();
        tip.moveTo(w * 0.27f, w * 0.75f);
        tip.lineTo(w * 0.73f, w * 0.75f);
        tip.lineTo(w / 2f, h - 4 * d);
        tip.close();
        c.drawPath(tip, p);
        try { p.setColor(Color.parseColor(accent)); } catch (Throwable t) { p.setColor(Color.rgb(242, 162, 58)); }
        c.drawCircle(w / 2f, w / 2f, w * 0.2f, p);
        return b;
    }

    // ------------------------------------------------------------------------------------
    // what MapLibre downloads goes through here: Waypoint's fonts come from the app, offline
    // areas from Road Trip's files, and styles and the tile index are kept for when there's
    // no connection

    private static final class Local implements Interceptor {
        private static final Pattern TILE = Pattern.compile("^/planet/[^/]+/(\\d+)/(\\d+)/(\\d+)\\.pbf$");
        private static final MediaType PBF = MediaType.parse("application/x-protobuf");
        private static final MediaType JSON = MediaType.parse("application/json");
        private final Context ctx;
        private List<File> areas = new ArrayList<>();
        private long areasAt = 0;

        Local(Context c) { ctx = c.getApplicationContext(); }

        @Override public Response intercept(Chain chain) throws IOException {
            Request req = chain.request();
            if (!"tiles.openfreemap.org".equals(req.url().host())) return chain.proceed(req);
            String path = req.url().encodedPath();
            List<String> seg = req.url().pathSegments();
            // Waypoint's map fonts
            if (seg.size() == 3 && "fonts".equals(seg.get(0)) && seg.get(1).startsWith("Waypoint ")) {
                String range = seg.get(2);
                if (range.matches("[0-9]+-[0-9]+\\.pbf")) {
                    byte[] bytes = asset("waypoint/glyphs/" + seg.get(1) + "/" + range);
                    if (bytes != null) return ok(req, bytes, PBF, 200);
                    // not bundled (another script, or a font Waypoint doesn't ship): a standard one
                    return chain.proceed(req.newBuilder().url(req.url().newBuilder().setPathSegment(1, "Noto Sans Regular").build()).build());
                }
            }
            // a tile in a downloaded offline area
            Matcher m = TILE.matcher(path);
            if (m.matches()) {
                File f = offline(m.group(1), m.group(2), m.group(3));
                if (f != null) {
                    byte[] bytes = read(f);
                    if (bytes != null) return ok(req, bytes, PBF, bytes.length == 0 ? 204 : 200);
                }
                return chain.proceed(req);
            }
            // styles and the tile index: remember the last good copy, use it when offline
            if (path.equals("/planet") || path.startsWith("/styles/")) {
                File keep = new File(ctx.getFilesDir(), "mapcache/" + path.replaceAll("[^a-zA-Z0-9]", "_") + ".json");
                try {
                    Response r = chain.proceed(req);
                    if (r.isSuccessful() && r.body() != null) {
                        byte[] bytes = r.body().bytes();
                        try {
                            //noinspection ResultOfMethodCallIgnored
                            keep.getParentFile().mkdirs();
                            try (FileOutputStream o = new FileOutputStream(keep)) { o.write(bytes); }
                        } catch (Throwable ignored) {}
                        return r.newBuilder().body(ResponseBody.create(bytes, JSON)).build();
                    }
                    return r;
                } catch (IOException e) {
                    byte[] bytes = keep.exists() ? read(keep) : null;
                    if (bytes != null) return ok(req, bytes, JSON, 200);
                    throw e;
                }
            }
            return chain.proceed(req);
        }

        private synchronized File offline(String z, String x, String y) {
            String dir = saveDir;
            if (dir == null) return null;
            long now = System.currentTimeMillis();
            if (now - areasAt > 10000) {
                areasAt = now;
                List<File> list = new ArrayList<>();
                File[] a = new File(dir, "tiles/off").listFiles();
                if (a != null) for (File f : a) if (f.isDirectory()) list.add(f);
                areas = list;
            }
            String rest = z + "/" + x + "/" + y + ".pbf";
            for (File a : areas) {
                File f = new File(a, rest);
                if (f.exists()) return f;
            }
            return null;
        }

        private byte[] asset(String path) {
            try (InputStream in = ctx.getAssets().open(path)) { return readAll(in); } catch (Throwable t) { return null; }
        }

        private static byte[] read(File f) {
            try (InputStream in = new FileInputStream(f)) { return readAll(in); } catch (Throwable t) { return null; }
        }

        private static byte[] readAll(InputStream in) throws IOException {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) o.write(buf, 0, n);
            return o.toByteArray();
        }

        private static Response ok(Request req, byte[] bytes, MediaType type, int code) {
            return new Response.Builder().request(req).protocol(Protocol.HTTP_1_1).code(code)
                .message(code == 204 ? "No Content" : "OK")
                .header("Cache-Control", "public, max-age=86400")
                .body(ResponseBody.create(bytes, type)).build();
        }
    }
}
