package app.roadtrip;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Looper;
import android.os.SystemClock;

import org.json.JSONObject;

/** The device's position for the map: GPS when there is one, network location otherwise. */
final class LocationBridge {
    private static volatile Location last;
    private static boolean started = false;

    private LocationBridge() {}

    static boolean permitted(Context ctx) {
        return ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            || ctx.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private static final LocationListener LISTENER = new LocationListener() {
        @Override
        public void onLocationChanged(Location l) {
            Location p = last;
            // prefer GPS: don't let a coarse network fix replace a recent precise one
            if (p != null && "gps".equals(p.getProvider()) && !"gps".equals(l.getProvider())
                    && SystemClock.elapsedRealtimeNanos() - p.getElapsedRealtimeNanos() < 10_000_000_000L) return;
            last = l;
        }

        // implemented explicitly: older Android versions call these and have no defaults
        @Override public void onStatusChanged(String provider, int status, Bundle extras) {}
        @Override public void onProviderEnabled(String provider) {}
        @Override public void onProviderDisabled(String provider) {}
    };

    /** Starts listening, asking for permission first if needed. */
    static synchronized boolean start(Context ctx) {
        if (!permitted(ctx)) {
            if (ctx instanceof Activity) {
                final Activity a = (Activity) ctx;
                a.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        a.requestPermissions(new String[] {
                            Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION }, 7032);
                    }
                });
            }
            return false;
        }
        if (started) return true;
        LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
        if (lm == null) return false;
        for (String p : new String[] { LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER }) {
            try {
                if (!lm.isProviderEnabled(p)) continue;
                //noinspection MissingPermission
                lm.requestLocationUpdates(p, 1000, 0, LISTENER, Looper.getMainLooper());
                //noinspection MissingPermission
                Location k = lm.getLastKnownLocation(p);
                if (k != null && (last == null || k.getTime() > last.getTime())) last = k;
            } catch (Throwable ignored) {
                // provider missing on this device
            }
        }
        started = true;
        return true;
    }

    /** {permission, fix?: {lat, lon, accuracy, speed, bearing, ageMs, provider}} */
    static JSONObject status(Context ctx) throws Exception {
        JSONObject o = new JSONObject();
        o.put("permission", permitted(ctx));
        Location l = last;
        if (l != null) {
            JSONObject f = new JSONObject();
            f.put("lat", l.getLatitude());
            f.put("lon", l.getLongitude());
            f.put("accuracy", l.hasAccuracy() ? l.getAccuracy() : -1);
            f.put("speed", l.hasSpeed() ? l.getSpeed() : -1);       // m/s
            f.put("bearing", l.hasBearing() ? l.getBearing() : -1); // degrees from north
            f.put("ageMs", (SystemClock.elapsedRealtimeNanos() - l.getElapsedRealtimeNanos()) / 1_000_000L);
            f.put("provider", l.getProvider());
            o.put("fix", f);
        }
        return o;
    }
}
