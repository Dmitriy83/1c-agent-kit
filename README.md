# 1c-agent-kit

Личный набор для ИИ-агентов (Claude Code, Codex) в разработке на 1С: скиллы, правила и стандарты
кодирования. Сейчас это работа с EDT и EDT-MCP, запросы, БСП, формы, YAxUnit, Vanessa Automation и общие
инструменты (документы, диаграммы, расшифровка аудио); со временем добавятся скиллы для Конфигуратора
и собственные стандарты.

Имена скиллов группируются префиксом: `1c-edt-*` - EDT, `1c-cf-*` - Конфигуратор и XML-выгрузка,
`1c-*` - общее для 1С. Каталог `skills/` плоский: агенты не ищут скиллы во вложенных каталогах.
Стандарты кодирования - короткими правилами в `rules-1c/`.

Набор общий для всех проектов. Правила конкретного проекта (предметная область, выпуск релиза,
видеоинструкции) остаются в репозитории проекта: `.claude/skills/`, `.claude/commands/`, `AGENTS.md`.

## Структура

```
skills/<имя>/SKILL.md   скилл (плюс references/, scripts/, evals/)
rules-1c/               правила, на которые ссылаются скиллы (~/.claude/rules-1c/...)
install.ps1             подключение к Claude Code и Codex
```

## Подключение

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Agent All -WhatIf   # посмотреть план
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Agent All
```

Скрипт создает junction-ссылки `~/.claude/skills/<имя>` и `~/.codex/skills/<имя>` на каталоги репозитория,
для Claude еще `~/.claude/rules-1c`. Существующий обычный каталог переносится в
`<каталог агента>/skills-backup-<дата>/`, ничего не удаляется. Повторный запуск безопасен.

Для Codex каталог с собственными правками не заменяется (строка `!` в выводе): сначала слейте правки
в репозиторий, затем `install.ps1 -Agent Codex -Force`. Каталог `~/.claude/skills/synced` синхронизирует
claude.ai, он в репозиторий не входит.

## Работа

Правка скилла - сразу в репозитории (ссылки ведут сюда), затем коммит и push. На другой машине:
`git pull` и, если появились новые скиллы, `install.ps1`.

Перед коммитом проверь, что в текст не попали токены, пароли, адреса внутренних серверов и пути
конкретной машины: репозиторий может быть открыт другим людям.

## Происхождение

Большая часть скиллов взята из [Desko77/claude-code-skills-1c](https://github.com/Desko77/claude-code-skills-1c)
(лицензия MIT, текст - [LICENSE-Desko77.md](LICENSE-Desko77.md)). Собственные дополнения и доработки -
тоже MIT, [LICENSE](LICENSE).

| Скилл | Источник |
|---|---|
| `1c-edt-tools`, `1c-naparnik`, `1c-vanessa-run`, `ai-edt-tools`, `claude-env-setup`, `claude-md-bootstrap`, `composing-1c-queries` | Desko77, доработан |
| остальные | Desko77 без изменений |

## Открытые вопросы

- У Codex свои копии `1c-edt-tools`, `1c-form-patterns`, `1c-platform-docs`, `1c-query-optimization`,
  `1c-ssl-patterns`, `composing-1c-queries`, `img-grid-analysis`, `md-to-docx`, `mermaid-diagrams`,
  `powershell-windows` с правками, которых нет здесь. Слить нужное в репозиторий и подключить с `-Force`.
