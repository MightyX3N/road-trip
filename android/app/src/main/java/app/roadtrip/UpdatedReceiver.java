package app.roadtrip;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Runs right after Road Trip is updated. Android may switch off a sideloaded app's
 * accessibility service on update; this puts Keep in front back if it can, or leaves a note
 * for Road Trip to show, then tries to reopen Road Trip.
 */
public class UpdatedReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (!Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction())) return;
        GuardService.afterUpdate(ctx);
        try {
            ctx.startActivity(GuardService.homeIntent(ctx)); // may be blocked from the background; harmless
        } catch (Throwable t) {
            Log.i("RoadTrip", "couldn't reopen after update: " + t);
        }
    }
}
