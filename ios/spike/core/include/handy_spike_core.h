// Ручной заголовок C ABI ядра handy_spike_core (см. core/src/lib.rs).
#ifndef HANDY_SPIKE_CORE_H
#define HANDY_SPIKE_CORE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Непрозрачный контекст: модель и сессия распознавания.
typedef struct SpikeCtx SpikeCtx;

// Загружает модель. use_gpu = true -> строго Metal, false -> CPU с ускорением (CpuAccel).
// При ошибке возвращает NULL и пишет текст в *err_out (освободить spike_free_string).
SpikeCtx *_Nullable spike_load(const char *_Nonnull model_path,
                               bool use_gpu,
                               char *_Nullable *_Nullable err_out);

// Какой бэкенд реально используется. Строку освободить spike_free_string.
char *_Nullable spike_backend_name(SpikeCtx *_Nullable ctx);

// Распознаёт pcm (16 кГц, mono, float32, n отсчётов). language: "ru", "auto" или NULL.
// Возвращает текст (освободить spike_free_string) либо NULL с текстом ошибки в *err_out.
char *_Nullable spike_transcribe(SpikeCtx *_Nullable ctx,
                                 const float *_Nullable pcm,
                                 size_t n,
                                 const char *_Nullable language,
                                 char *_Nullable *_Nullable err_out);

void spike_free_string(char *_Nullable s);
void spike_free(SpikeCtx *_Nullable ctx);

#ifdef __cplusplus
}
#endif

#endif
