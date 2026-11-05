package com.k2fsa.sherpa.onnx;

public class OfflineTtsPocketModelConfig {
    public String lmFlow = "", lmMain = "", encoder = "", decoder = "", textConditioner = "", vocabJson = "", tokenScoresJson = "";
    public int voiceEmbeddingCacheCapacity = 50;
}
