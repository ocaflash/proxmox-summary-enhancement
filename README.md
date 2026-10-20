# pve-mac-monitor

Мониторинг лимита MAC-адресов Hetzner для Proxmox VE. Считает активные
unicast MAC-адреса запущенных VM/CT на мостах с физическим uplink (bridge FDB),
хранит историю и выводит её в **Summary** узла:

- `Hetzner MAC Limit` — прогресс-бар `used / 32 (P%)`; янтарный с 28/32,
  красный с 31/32 (жёсткий лимит Hetzner — 32 MAC на сервер);
- `MAC peaks` — максимумы за 15 минут / 1 час / 24 часа;
- `MAC addresses (used)` — график истории под штатными графиками узла,
  следует встроенному переключателю Hour / Day / Week / Month / Year
  и Average / Max.

Проверено на PVE 8.x / 9.x. Обновление `pve-manager` перезаписывает
пропатченные файлы — после `apt upgrade` достаточно повторно запустить
установщик.

## Быстрый запуск

**Один узел** (root на самом узле, через Shell веб-интерфейса или ssh):

```bash
curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh \
  | bash -s -- --retention 168
```

`--retention 168` — хранить историю 7 суток (по умолчанию 24 часа).

**Сначала сухой прогон** (ничего не меняет, работает без root):

```bash
curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh \
  | bash -s -- --check-only
```

**Несколько узлов с одного хоста** (root-ssh до остальных должен работать):

```bash
curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install-cluster.sh \
  | bash -s -- --nodes "pve66 pve88" --retention 168 --yes
```

**Откат:**

```bash
pve-mac-monitor-uninstall               # снять только блоки pve-mac-monitor
pve-mac-monitor-uninstall --from-backup # восстановить файлы из бэкапа
```

После установки: Node → Summary → жёсткое обновление страницы (Ctrl+Shift+R).

## Требования

- Proxmox VE 8.x / 9.x, права root;
- `python3` (только стандартная библиотека), `perl`, `cron`, `flock`;
- `qm`, `pct`, `bridge` — входят в PVE;
- опционально: `node` (проверка синтаксиса JS), `curl` или `wget`
  (загрузка проекта при установке одной командой).

## Параметры установщика

### `install.sh`

| Параметр | Назначение |
|---|---|
| `--check-only` | показать состояние патчей и план действий, ничего не менять |
| `--force` | обойти проверку версии `pve-manager` |
| `--retention HOURS` | глубина истории, 1…8760 (по умолчанию 24) |
| `--ref REF` | ветка/тег/коммит для загрузки (по умолчанию `main`) |

`install.sh` работает в двух режимах:

- **автономный** (`curl … | bash` или одиночный файл): недостающие файлы
  скачиваются одним архивом с `codeload.github.com`, проверяются по
  `SHA256SUMS`, затем компилируются `bash -n` и `py_compile`;
- **из репозитория** (`./install.sh` рядом с `src/`): используются локальные
  файлы, сеть не нужна.

Переменные окружения: `MAC_REPO=<owner>/<repo>` (форк), `MAC_REF`,
`MAC_RETENTION_HOURS`.

### `install-cluster.sh`

| Параметр | Назначение |
|---|---|
| `--nodes "a b c"` | явный список узлов вместо автоопределения |
| `--yes`, `-y` | без подтверждения (обязательно для `curl \| bash`) |
| `--partial` | патчить доступные узлы, если часть недоступна по ssh |
| `--no-verify` | не выполнять проверку через `pvesh` после установки |
| `--check-only`, `--force`, `--retention`, `--ref` | как у `install.sh` |

Список узлов берётся из `pvecm nodes`. Каталоги `/etc/pve/nodes/*`, не
являющиеся членами кластера (остатки от `pvecm delnode`), пропускаются и
**не изменяются**. Перед раскаткой выполняется предполётная проверка ssh и
`pveversion` на каждом узле: недоступный узел прерывает запуск до внесения
изменений (либо пропускается с `--partial`, код возврата 6).

Подтверждение читается только из stdin: под `curl | bash` stdin занят
скриптом, поэтому требуется `--yes`.

## Что изменяется

| Путь | Изменение |
|---|---|
| `/usr/share/perl5/PVE/API2/Nodes.pm` | поля `mac`, `macstats`, `mac_current`, `mac_limit` в `status`; новый метод `GET /nodes/{node}/mac-history` |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | две строки в `PVE.node.StatusView`, высота блока 350→400; модель `pve-rrd-mac`, store и график в `PVE.node.Summary` |
| `/usr/local/bin/pve-mac-monitor` | сборщик |
| `/usr/local/lib/pve-mac-monitor/` | патчеры и `VERSION` (нужны деинсталлятору) |
| `/usr/local/sbin/pve-mac-monitor-uninstall` | деинсталлятор |
| `/etc/cron.d/pve-mac-monitor` | запуск раз в минуту (только блок между маркерами) |
| `/var/lib/pve-mac-monitor/` | `state.json`, `history.json` |
| `/var/backups/pve-mac-monitor-<timestamp>/` | копии оригиналов + `SHA256SUMS` |

Не изменяются: `/etc/pve/**` (`corosync.conf`, конфиги VM/CT, HA,
репликация), `corosync`, `pmxcfs`, `pve-cluster`, RRD и схема `pve2-node`,
`/etc/network/interfaces`, мосты, firewall, хранилища, `pvestatd`;
`proxmoxlib.js` не патчится. Перезапускаются только `pvedaemon` и `pveproxy`.

Правки заключены в маркеры `pve-mac-monitor …`; `uninstall.sh` снимает их
байт-в-байт.

## Сбор MAC-адресов

Логика соответствует `pve-mac-monitor-orig.sh`:

1. запущенные гости — `qm list`, `pct list`;
2. внешние мосты — `vmbr*`, у которых в `brif` есть порт `en*`, `eth*`,
   `bond*`;
3. гостевые порты этих мостов — `tap*`, `veth*`, `fwpr*`;
4. `bridge fdb show` по внешним мостам, фильтр: MAC нужного порта, не
   `permanent`, unicast (второй байт чётный).

Значение пишется в `state.json` (`current`) и добавляется точкой в
`history.json`.

## История и хранение

`/var/lib/pve-mac-monitor/history.json` — массив точек
`{"t": <epoch>, "v": <кол-во>}`, одна точка в минуту, запись атомарная
(`.tmp` + `rename`), от наложения запусков защищает `flock`.

- последние 24 часа — полное разрешение;
- старше — усреднение в 5-минутные бакеты (год ≈ 12 тыс. точек вместо 525 тыс.);
- глубина задаётся `--retention` и хранится в cron-строке
  (`MAC_RETENTION_HOURS`), повторный запуск установщика меняет её без
  переустановки патчей.

`state.json` содержит `current`, `limit`, `warn`, `max_15min`, `max_1h`,
`max_24h`, `samples`, `interval`, `retention_hours`, `timestamp` и объект
`diag`.

## График

`GET /nodes/{node}/mac-history?timeframe=hour|day|week|month|year&cf=AVERAGE|MAX`

- права `Sys.Audit`, `proxyto => 'node'`;
- окно по `timeframe`, консолидация до ≤800 точек (`average` или `max`);
- селектор PVE передаёт `cf` в верхнем регистре — endpoint принимает
  `AVERAGE`/`MAX` и в нижнем;
- при `retention < выбранного периода` график покажет столько, сколько
  накоплено.

## Проверка

```bash
cat /var/lib/pve-mac-monitor/state.json
pvesh get /nodes/$(hostname)/status --output-format json | grep -o '"mac"[^}]*}'
pvesh get /nodes/$(hostname)/mac-history --timeframe hour --cf AVERAGE | head -c 200
journalctl -t pve-mac-monitor --no-pager | tail
systemctl is-active cron pvedaemon pveproxy
```

Установщик выполняет обе проверки API сам и откатывается, если ответ не
содержит ожидаемых полей.

## Диагностика

### `current: 0`

Счётчик работает по четырём шагам; в `state.json` поле `diag` показывает,
какой из них дал ноль:

```json
"diag": {"bridges":"1","external":"1","uplinks":"vmbr0:eno1","running":"3",
         "guest_ports":"4","all_guest_ports":"4","fdb_lines":"37",
         "bridge_cmd":"1"}
```

| Поле | Ноль означает |
|---|---|
| `bridges` | нет ни одного `vmbr*` |
| `external` | ни у одного моста нет порта `en*/eth*/bond*` |
| `running` | нет запущенных гостей |
| `all_guest_ports` | нет портов `tap*/veth*/fwpr*` на мостах |
| `guest_ports` | порты есть, но VMID нет в списке запущенных |
| `fdb_lines` | `bridge fdb show` пуст (MAC появятся после трафика гостя) |
| `bridge_cmd` | нет бинаря `bridge` |

Подробный разбор:

```bash
MAC_VERBOSE=1 MAC_DEBUG=1 /usr/local/bin/pve-mac-monitor
```

Выводит счётчики, найденные MAC, сырой дамп FDB и число записей по каждому
порту (`tap100i0: 1`). Порт с нулём — мост ещё не выучил MAC этого гостя.

### График пуст, ось 1970

Означает, что store не получил ни одной строки. Проверка с теми же
параметрами, что отправляет селектор:

```bash
pvesh get /nodes/$(hostname)/mac-history --timeframe hour --cf AVERAGE --output-format json | head -c 300
```

- точки есть — проблема в браузере, нужно жёсткое обновление (Ctrl+Shift+R);
- `invalid value for option cf` — backend старой версии, повторить установку;
- `[]` — endpoint исправен, но окно пусто: сравнить с
  `cat /var/lib/pve-mac-monitor/history.json`.

## Отказоустойчивость

Порядок проверок при установке:

1. `pve-manager` 8.x/9.x (иначе отказ без `--force`);
2. бэкап обоих файлов с `SHA256SUMS`;
3. `perl -c Nodes.pm` → откат при ошибке;
4. `node --check pvemanagerlib.js` → откат при ошибке;
5. перезапуск `pvedaemon`/`pveproxy`; ошибка или неактивный unit → откат;
6. `pvesh get /nodes/<node>/status` без полей `mac` → откат;
7. `pvesh get /nodes/<node>/mac-history --cf AVERAGE` не отвечает → откат.

Остаточные риски:

- `node --check` проверяет только синтаксис; ошибка времени выполнения
  ломает Summary этого узла (API, VM, кластер, хранилища работают);
- обновление `pve-manager` убирает строки из UI до повторного запуска
  установщика;
- `--from-backup` нельзя использовать после обновления пакета — откатит
  файлы к старой версии.

## Структура

```
install.sh                        # установщик (сам скачивает остальное)
install-cluster.sh                # раскатка на несколько узлов
uninstall.sh                      # снятие патчей, сборщика и cron
pve-mac-monitor.sh                # сборщик (cron, раз в минуту)
src/patch-mac-backend.py           # патч Nodes.pm
src/patch-mac-frontend.py          # патч pvemanagerlib.js
patches/REFERENCE-*.patch          # якоря для ручного портирования
SHA256SUMS                         # контрольные суммы для автономной установки
VERSION
```

## Лицензия

Скрипты — MIT. Файлы Proxmox остаются под их лицензиями (AGPL-3.0);
распространяются только фрагменты патчей.
