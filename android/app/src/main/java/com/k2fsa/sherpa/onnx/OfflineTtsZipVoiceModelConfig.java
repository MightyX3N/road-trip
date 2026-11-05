package com.k2fsa.sherpa.onnx;

public class OfflineTtsZipVoiceModelConfig {
    public String tokens = "", encoder = "", decoder = "", vocoder = "", dataDir = "", lexicon = "";
    public float featScale = 0.1f, tShift = 0.5f, targetRms = 0.1f, guidanceScale = 1.0f;
}
