package com.k2fsa.sherpa.onnx;

public class OfflineTtsMatchaModelConfig {
    public String acousticModel = "", vocoder = "", lexicon = "", tokens = "", dataDir = "", dictDir = "";
    public float noiseScale = 1.0f, lengthScale = 1.0f;
}
