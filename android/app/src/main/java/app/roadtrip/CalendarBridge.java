package app.roadtrip;

import android.Manifest;
import android.app.Activity;
import android.content.ContentUris;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CalendarContract;

import org.json.JSONArray;
import org.json.JSONObject;

/** The next few events from the device's calendars, for the Calendar widget. */
final class CalendarBridge {
    private CalendarBridge() {}

    static boolean granted(Context ctx) {
        return ctx.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED;
    }

    static boolean request(Context ctx) {
        if (!(ctx instanceof Activity)) return false;
        final Activity a = (Activity) ctx;
        a.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                a.requestPermissions(new String[] { Manifest.permission.READ_CALENDAR }, 7031);
            }
        });
        return true;
    }

    /** {permission, events: [{title, begin, end, allDay, location}]} for the next 48 hours */
    static JSONObject upcoming(Context ctx) throws Exception {
        JSONObject o = new JSONObject();
        boolean ok = granted(ctx);
        o.put("permission", ok);
        JSONArray events = new JSONArray();
        o.put("events", events);
        if (!ok) return o;

        long now = System.currentTimeMillis();
        Uri.Builder b = CalendarContract.Instances.CONTENT_URI.buildUpon();
        ContentUris.appendId(b, now - 12 * 3600_000L);
        ContentUris.appendId(b, now + 48 * 3600_000L);
        String[] cols = {
            CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.EVENT_LOCATION,
        };
        Cursor c = ctx.getContentResolver().query(b.build(), cols, null, null, CalendarContract.Instances.BEGIN + " ASC");
        if (c == null) return o;
        try {
            while (c.moveToNext() && events.length() < 3) {
                long end = c.getLong(2);
                if (end < now) continue; // already over
                JSONObject e = new JSONObject();
                e.put("title", c.getString(0) == null ? "" : c.getString(0));
                e.put("begin", c.getLong(1));
                e.put("end", end);
                e.put("allDay", c.getInt(3) == 1);
                e.put("location", c.getString(4) == null ? "" : c.getString(4));
                events.put(e);
            }
        } finally {
            c.close();
        }
        return o;
    }

    static boolean open(Context ctx, long at) {
        Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse("content://com.android.calendar/time/" + Math.max(0, at)));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            ctx.startActivity(i);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }
}
