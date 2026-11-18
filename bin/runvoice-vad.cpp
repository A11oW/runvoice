#include "whisper.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cmath>
#include <algorithm>
static bool read_all(void *p, size_t n) { return fread(p,1,n,stdin)==n; }
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    whisper_log_set([](enum ggml_log_level,const char *,void *){},nullptr);
    auto cp=whisper_vad_default_context_params(); cp.use_gpu=false; cp.n_threads=2;
    auto *ctx=whisper_vad_init_from_file_with_params(argv[1],cp);
    if(!ctx) return 3;
    puts("{\"ready\":true}"); fflush(stdout);
    uint8_t h[4];
    while(read_all(h,4)) {
        uint32_t n=uint32_t(h[0])|(uint32_t(h[1])<<8)|(uint32_t(h[2])<<16)|(uint32_t(h[3])<<24);
        if(n>1048576 || n%2) break;
        std::vector<uint8_t> bytes(n); if(!read_all(bytes.data(),n)) break;
        std::vector<float> pcm(n/2);
        for(size_t i=0;i<pcm.size();++i) pcm[i]=int16_t(uint16_t(bytes[2*i])|(uint16_t(bytes[2*i+1])<<8))/32768.f;
        if(!whisper_vad_detect_speech(ctx,pcm.data(),int(pcm.size()))) { puts("{\"error\":true}"); fflush(stdout); continue; }
        auto p=whisper_vad_default_params(); p.threshold=.5f; p.min_speech_duration_ms=80;
        p.min_silence_duration_ms=100; p.speech_pad_ms=0;
        auto *s=whisper_vad_segments_from_probs(ctx,p);
        printf("{\"segments\":[");
        for(int i=0;i<whisper_vad_segments_n_segments(s);++i) {
            // whisper.cpp returns centiseconds. 16 kHz = 160 samples per centisecond.
            int start=std::max(0,int(std::lround(whisper_vad_segments_get_segment_t0(s,i)*160)));
            int end=std::min(int(pcm.size()),int(std::lround(whisper_vad_segments_get_segment_t1(s,i)*160)));
            printf("%s[%d,%d]",i?",":"",start,end);
        }
        puts("]}"); fflush(stdout); whisper_vad_free_segments(s);
    }
    whisper_vad_free(ctx); return 0;
}
