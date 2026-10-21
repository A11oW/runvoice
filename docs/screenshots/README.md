# Скриншоты Runvoice

Сняты встроенным отладочным рендером приложения (`--snapshot-states` и `--snapshot`),
поэтому не требуют разрешения Screen Recording. Тёмная тема.

## Состояния HUD

| Состояние | Что показывает |
|---|---|
| ![](hud-preparing.png) | `preparing` — «Готовлю микрофон…» |
| ![](hud-recording.png) | `recording` — «Слушаю…», таймер и уровень микрофона |
| ![](hud-transcribing.png) | `transcribing` — «Распознаю…» |
| ![](hud-fixing.png) | `fixing` — «Обрабатываю текст…» |
| ![](hud-done.png) | `done` — «Готово», зелёная галочка |
| ![](hud-info.png) | `info` — «запись не идёт», синяя иконка |
| ![](hud-error.png) | `error` — «речь не распознана (тишина?)», оранжевая иконка |
| ![](hud-improve.png) | `improve` — «Улучшаю текст…», искры |
| ![](hud-improve-copied.png) | `improve-copied` — «Улучшено и скопировано», синяя иконка |

## Настройки

| Вкладка | Файл |
|---|---|
| Основные (язык, микрофон, автозапуск, HUD, диагностика) | [settings-general.png](settings-general.png) |
| Распознавание (модели Whisper, скачивание, папки) | [settings-models.png](settings-models.png) |
| Провайдеры (профили, модели, ключи, проверка) | [settings-providers.png](settings-providers.png) |
| Постобработка (выбор провайдеров, промпты) | [settings-ai.png](settings-ai.png) |
| Постобработка → улучшение выделенного текста | [settings-improve.png](settings-improve.png) |
| История (список, копирование, лимиты) | [settings-history.png](settings-history.png) |
| Хоткеи (диктовка, улучшение, конфликты macOS) | [settings-hotkeys.png](settings-hotkeys.png) |

## Как переснять

```sh
# состояния HUD
open -a /Applications/Runvoice.app --args --snapshot-states

# вкладки настроек
open -a /Applications/Runvoice.app --args --snapshot
```

Файлы появятся в `/tmp/runvoice-state-*.png` и `/tmp/runvoice-settings*.png`.
