package com.example.autorender;

import java.io.File;
import java.io.FileInputStream;
import java.util.Properties;

/**
 * config/autorender.properties padhta hai jo render.sh ne likhi hai.
 * Saari render-time settings yahin se aati hain.
 */
public class RenderConfig {
    public String replay;       // replay_recordings/ ke andar ki filename
    public String timeline;     // timeline id ("" = pehla available)
    public int width = 1920;
    public int height = 1080;
    public int fps = 60;
    public File outputDir;
    public File doneMarker;
    public boolean quitWhenDone = true;
    public boolean valid = false;

    public static RenderConfig load(File gameDir) {
        RenderConfig c = new RenderConfig();
        File f = new File(gameDir, "config/autorender.properties");
        if (!f.isFile()) {
            AutoRenderMod.LOG.warn("[AutoRender] config nahi mila: {} — idle.", f);
            return c;
        }
        Properties p = new Properties();
        try (FileInputStream in = new FileInputStream(f)) {
            p.load(in);
            c.replay   = p.getProperty("replay", "").trim();
            c.timeline = p.getProperty("timeline", "").trim();
            c.width    = parseInt(p.getProperty("width"), 1920);
            c.height   = parseInt(p.getProperty("height"), 1080);
            c.fps      = parseInt(p.getProperty("fps"), 60);
            c.outputDir   = new File(p.getProperty("outputDir", new File(gameDir, "replay_videos").getPath()));
            c.doneMarker  = new File(p.getProperty("doneMarker", new File(c.outputDir, ".autorender_done").getPath()));
            c.quitWhenDone = Boolean.parseBoolean(p.getProperty("quitWhenDone", "true"));
            c.valid = !c.replay.isEmpty();
        } catch (Exception e) {
            AutoRenderMod.LOG.error("[AutoRender] config padhne me error", e);
        }
        return c;
    }

    private static int parseInt(String s, int def) {
        try { return Integer.parseInt(s.trim()); } catch (Exception e) { return def; }
    }
}
