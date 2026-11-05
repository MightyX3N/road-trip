package app.roadtrip;

import android.content.Intent;

import org.love2d.android.GameActivity;

/**
 * LÖVE's activity, plus one thing a launcher needs: knowing when the Home button is pressed
 * while Road Trip is already running. Android delivers that as a new HOME intent, which LÖVE
 * ignores; this counts them and Lua polls the count (LauncherBridge "homePresses").
 */
public class RoadTripActivity extends GameActivity {
    static volatile int homePresses = 0;

    @Override
    protected void onResume() {
        super.onResume();
        Overlay.roadTripResumed = true;
    }

    @Override
    protected void onPause() {
        Overlay.roadTripResumed = false;
        super.onPause();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent != null && Intent.ACTION_MAIN.equals(intent.getAction())
                && intent.hasCategory(Intent.CATEGORY_HOME)) {
            homePresses++;
        }
    }
}
