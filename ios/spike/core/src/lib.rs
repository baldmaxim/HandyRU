//! Одноразовое ядро для замеров Whisper на iPhone.
//!
//! Тонкий C ABI поверх `transcribe-cpp`: модель и сессия живут прямо в процессе
//! приложения (на iOS нет отдельного рабочего процесса, как на десктопе).
//! Каждая экспортируемая функция обёрнута в `catch_unwind`: паника не должна
//! пересекать границу FFI.

use std::any::Any;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use transcribe_cpp::{Backend, Model, ModelOptions, RunOptions, Session};

/// Контекст: загруженная модель и сессия распознавания.
pub struct SpikeCtx {
    /// Держим модель явно, хотя сессия тоже владеет ссылкой на неё.
    _model: Model,
    session: Session,
    /// Человекочитаемое имя реального бэкенда, например «metal (Metal: Apple A17 Pro)».
    backend: String,
    /// Языки, которые заявляет модель (пусто — язык не выбирается).
    languages: Vec<String>,
}

/// Превращает строку в C-строку для передачи наружу (NUL внутри заменяется пробелом).
fn to_c_string(s: &str) -> *mut c_char {
    let clean = s.replace('\0', " ");
    CString::new(clean).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn clear_err(err_out: *mut *mut c_char) {
    if !err_out.is_null() {
        // SAFETY: вызывающий передаёт указатель на свою переменную.
        unsafe { *err_out = std::ptr::null_mut() };
    }
}

fn set_err(err_out: *mut *mut c_char, msg: &str) {
    if !err_out.is_null() {
        // SAFETY: см. clear_err.
        unsafe { *err_out = to_c_string(msg) };
    }
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    let text = payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "неизвестная паника".to_string());
    format!("паника в ядре: {text}")
}

/// Читает обязательную C-строку как UTF-8.
unsafe fn read_required_str<'a>(p: *const c_char, what: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{what}: пустой указатель"));
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| format!("{what}: строка не в UTF-8"))
}

fn load_impl(model_path: &str, use_gpu: bool) -> Result<SpikeCtx, String> {
    // Выбор CPU/GPU только через запрос бэкенда при загрузке модели:
    // Metal — строго Metal (без тихого отката на CPU), CpuAccel — лучший вариант без GPU:
    // в фоне GPU может быть недоступен, поэтому важна реальная скорость CPU.
    // «Авто» здесь намеренно не используется.
    let backend = if use_gpu {
        Backend::Metal
    } else {
        Backend::CpuAccel
    };
    let model = Model::load_with(
        model_path,
        &ModelOptions {
            backend,
            device: None,
            // В 0.4.1 появилось поле no_mmap; остальное — по умолчанию (mmap включён).
            ..Default::default()
        },
    )
    .map_err(|e| format!("загрузка модели: {e}"))?;
    let session = model
        .session()
        .map_err(|e| format!("создание сессии: {e}"))?;
    let languages = model
        .capabilities()
        .map(|c| c.languages)
        .map_err(|e| format!("возможности модели: {e}"))?;

    let backend_name = match model.device() {
        Ok(d) => format!("{} ({}: {})", model.backend(), d.name, d.description),
        Err(_) => model.backend(),
    };
    Ok(SpikeCtx {
        _model: model,
        session,
        backend: backend_name,
        languages,
    })
}

/// Загружает модель. `use_gpu = true` — Metal, `false` — CPU.
/// При ошибке возвращает NULL и пишет текст в `*err_out`.
///
/// # Safety
/// `model_path` — валидная C-строка; `err_out` — NULL или указатель на `char *`.
#[no_mangle]
pub unsafe extern "C" fn spike_load(
    model_path: *const c_char,
    use_gpu: bool,
    err_out: *mut *mut c_char,
) -> *mut SpikeCtx {
    clear_err(err_out);
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let path = read_required_str(model_path, "путь к модели")?;
        load_impl(path, use_gpu)
    }));
    match outcome {
        Ok(Ok(ctx)) => Box::into_raw(Box::new(ctx)),
        Ok(Err(msg)) => {
            set_err(err_out, &msg);
            std::ptr::null_mut()
        }
        Err(p) => {
            set_err(err_out, &panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// Имя реально используемого бэкенда. Строку освободить `spike_free_string`.
///
/// # Safety
/// `ctx` — NULL или указатель, полученный из `spike_load`.
#[no_mangle]
pub unsafe extern "C" fn spike_backend_name(ctx: *mut SpikeCtx) -> *mut c_char {
    if ctx.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| to_c_string(&(*ctx).backend))).unwrap_or(std::ptr::null_mut())
}

/// Язык для запуска: как на десктопе, передаём только заявленный моделью,
/// иначе автоопределение (чтобы не получить UNSUPPORTED_LANGUAGE).
fn resolve_language(requested: Option<&str>, supported: &[String]) -> Option<String> {
    let lang = requested?.trim();
    if lang.is_empty() || lang == "auto" {
        return None;
    }
    supported.iter().find(|l| l.as_str() == lang).cloned()
}

fn transcribe_impl(
    ctx: &mut SpikeCtx,
    pcm: &[f32],
    language: Option<&str>,
) -> Result<String, String> {
    if pcm.is_empty() {
        return Err("пустое аудио".to_string());
    }
    // Остальное — значения по умолчанию, как у десктопа: он меняет только задачу и язык.
    let options = RunOptions {
        language: resolve_language(language, &ctx.languages),
        ..Default::default()
    };
    match ctx.session.run(pcm, &options) {
        Ok(t) => {
            if ctx.session.was_truncated() {
                Ok(format!(
                    "[ОБРЕЗАНО: распознавание остановилось раньше конца] {}",
                    t.text
                ))
            } else {
                Ok(t.text)
            }
        }
        // Обрыв, обрезка или зацикливание: частичный текст сохраняется, показываем его с пометкой.
        Err(e) => match e.partial() {
            Some(partial) => Ok(format!("[НЕПОЛНЫЙ РЕЗУЛЬТАТ: {e}] {}", partial.text)),
            None => Err(format!("распознавание: {e}")),
        },
    }
}

/// Распознаёт PCM (16 кГц, mono, float32). Возвращает текст; при ошибке — NULL и `*err_out`.
///
/// # Safety
/// `ctx` из `spike_load`; `pcm` указывает на `n` валидных `f32`; `language` — NULL или C-строка.
#[no_mangle]
pub unsafe extern "C" fn spike_transcribe(
    ctx: *mut SpikeCtx,
    pcm: *const f32,
    n: usize,
    language: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut c_char {
    clear_err(err_out);
    if ctx.is_null() || pcm.is_null() {
        set_err(err_out, "пустой указатель контекста или аудио");
        return std::ptr::null_mut();
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let lang = if language.is_null() {
            None
        } else {
            Some(read_required_str(language, "язык")?)
        };
        let samples = std::slice::from_raw_parts(pcm, n);
        transcribe_impl(&mut *ctx, samples, lang)
    }));
    match outcome {
        Ok(Ok(text)) => {
            let out = to_c_string(&text);
            if out.is_null() {
                set_err(err_out, "не удалось вернуть текст");
            }
            out
        }
        Ok(Err(msg)) => {
            set_err(err_out, &msg);
            std::ptr::null_mut()
        }
        Err(p) => {
            set_err(err_out, &panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// Освобождает строку, возвращённую ядром.
///
/// # Safety
/// `s` — NULL или строка из функций этого ядра (ровно один раз).
#[no_mangle]
pub unsafe extern "C" fn spike_free_string(s: *mut c_char) {
    if !s.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(s))));
    }
}

/// Освобождает контекст (сессию и модель).
///
/// # Safety
/// `ctx` — NULL или указатель из `spike_load` (ровно один раз).
#[no_mangle]
pub unsafe extern "C" fn spike_free(ctx: *mut SpikeCtx) {
    if !ctx.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(ctx))));
    }
}
