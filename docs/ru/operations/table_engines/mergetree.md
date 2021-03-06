# MergeTree {#table_engines-mergetree}

Движок `MergeTree`, а также другие движки этого семейства (`*MergeTree`) — это наиболее функциональные движки таблиц ClickHousе.

!!!info
    Движок [Merge](merge.md) не относится к семейству `*MergeTree`.

Основные возможности:

- Хранит данные, отсортированные по первичному ключу.

    Это позволяет создавать разреженный индекс небольшого объёма, который позволяет быстрее находить данные.

- Позволяет оперировать партициями, если задан [ключ партиционирования](custom_partitioning_key.md).

    ClickHouse поддерживает отдельные операции с партициями, которые работают эффективнее, чем общие операции с этим же результатом над этими же данными. Также, ClickHouse автоматически отсекает данные по партициям там, где ключ партиционирования указан в запросе. Это также увеличивает эффективность выполнения запросов.

- Поддерживает репликацию данных.

    Для этого используется семейство таблиц `ReplicatedMergeTree`. Подробнее читайте в разделе [Репликация данных](replication.md).

- Поддерживает сэмплирование данных.

    При необходимости можно задать способ сэмплирования данных в таблице.


## Создание таблицы {#table_engine-mergetree-creating-a-table}

```sql
CREATE TABLE [IF NOT EXISTS] [db.]table_name [ON CLUSTER cluster]
(
    name1 [type1] [DEFAULT|MATERIALIZED|ALIAS expr1],
    name2 [type2] [DEFAULT|MATERIALIZED|ALIAS expr2],
    ...
    INDEX index_name1 expr1 TYPE type1(...) GRANULARITY value1,
    INDEX index_name2 expr2 TYPE type2(...) GRANULARITY value2
) ENGINE = MergeTree()
[PARTITION BY expr]
[ORDER BY expr]
[PRIMARY KEY expr]
[SAMPLE BY expr]
[SETTINGS name=value, ...]
```

Описание параметров запроса смотрите в [описании запроса](../../query_language/create.md).

**Секции запроса**

- `ENGINE` — Имя и параметры движка. `ENGINE = MergeTree()`. Движок `MergeTree` не имеет параметров.

- `PARTITION BY` — [ключ партиционирования](custom_partitioning_key.md).

    Для партиционирования по месяцам используйте выражение `toYYYYMM(date_column)`, где `date_column` — столбец с датой типа [Date](../../data_types/date.md). В этом случае имена партиций имеют формат `"YYYYMM"`.

- `ORDER BY` — ключ сортировки.

    Кортеж столбцов или произвольных выражений. Пример: `ORDER BY (CounerID, EventDate)`.  

- `PRIMARY KEY` - первичный ключ, если он [отличается от ключа сортировки](mergetree.md).

    По умолчанию первичный ключ совпадает с ключом сортировки (который задаётся секцией `ORDER BY`). Поэтому
    в большинстве случаев секцию `PRIMARY KEY` отдельно указывать не нужно.

- `SAMPLE BY` — выражение для сэмплирования.

    Если используется выражение для сэмплирования, то первичный ключ должен содержать его. Пример:  
    `SAMPLE BY intHash32(UserID) ORDER BY (CounerID, EventDate, intHash32(UserID))`.

- `SETTINGS` — дополнительные параметры, регулирующие поведение `MergeTree`:

    - `index_granularity` — гранулярность индекса. Число строк данных между «засечками» индекса. По умолчанию — 8192.

**Пример задания секций**

```
ENGINE MergeTree() PARTITION BY toYYYYMM(EventDate) ORDER BY (CounterID, EventDate, intHash32(UserID)) SAMPLE BY intHash32(UserID) SETTINGS index_granularity=8192
```

В примере мы устанавливаем партиционирование по месяцам.

Также мы задаем выражение для сэмплирования в виде хэша по идентификатору посетителя. Это позволяет псевдослучайным образом перемешать данные в таблице для каждого `CounterID` и `EventDate`. Если при выборке данных задать секцию [SAMPLE](../../query_language/select.md#sample], то ClickHouse вернёт равномерно-псевдослучайную выборку данных для подмножества посетителей.
`index_granularity` можно было не указывать, поскольку 8192 — это значение по умолчанию.

<details markdown="1"><summary>Устаревший способ создания таблицы</summary>

!!! attention
    Не используйте этот способ в новых проектах и по возможности переведите старые проекты на способ описанный выше.

```sql
CREATE TABLE [IF NOT EXISTS] [db.]table_name [ON CLUSTER cluster]
(
    name1 [type1] [DEFAULT|MATERIALIZED|ALIAS expr1],
    name2 [type2] [DEFAULT|MATERIALIZED|ALIAS expr2],
    ...
) ENGINE [=] MergeTree(date-column [, sampling_expression], (primary, key), index_granularity)
```

**Параметры MergeTree()**

- `date-column` — имя столбца с типом [Date](../../data_types/date.md). На основе этого столбца ClickHouse автоматически создаёт партиции по месяцам. Имена партиций имеют формат `"YYYYMM"`.
- `sampling_expression` — выражение для сэмплирования.
- `(primary, key)` — первичный ключ. Тип — [Tuple()](../../data_types/tuple.md- `index_granularity` — гранулярность индекса. Число строк данных между «засечками» индекса. Для большинства задач подходит значение 8192.

**Пример**

```
MergeTree(EventDate, intHash32(UserID), (CounterID, EventDate, intHash32(UserID)), 8192)
```

Движок `MergeTree` сконфигурирован таким же образом, как и в примере выше для основного способа конфигурирования движка.
</details>

## Хранение данных

Таблица состоит из *кусков* данных (data parts), отсортированных по первичному ключу.

При вставке в таблицу создаются отдельные куски данных, каждый из которых лексикографически отсортирован по первичному ключу. Например, если первичный ключ — `(CounterID, Date)`, то данные в куске будут лежать в порядке `CounterID`, а для каждого `CounterID` в порядке `Date`.

Данные, относящиеся к разным партициям, разбиваются на разные куски. В фоновом режиме ClickHouse выполняет слияния (merge) кусков данных для более эффективного хранения. Куски, относящиеся к разным партициям не объединяются. Механизм слияния не гарантирует, что все строки с одинаковым первичным ключом окажутся в одном куске.

Для каждого куска данных ClickHouse создаёт индексный файл, который содержит значение первичного ключа для каждой индексной строки («засечка»). Номера индексных строк определяются как `n * index_granularity`, а максимальное значение `n` равно целой части от деления общего количества строк на `index_granularity`. Для каждого столбца также пишутся «засечки» для тех же индексных строк, что и для первичного ключа, эти «засечки»  позволяют находить непосредственно данные в столбцах.

Вы можете использовать одну большую таблицу, постоянно добавляя в неё данные пачками, именно для этого предназначен движок `MergeTree`.

## Первичные ключи и индексы в запросах

Рассмотрим первичный ключ — `(CounterID, Date)`, в этом случае, сортировку и индекс можно проиллюстрировать следующим образом:

```
Whole data:     [-------------------------------------------------------------------------]
CounterID:      [aaaaaaaaaaaaaaaaaabbbbcdeeeeeeeeeeeeefgggggggghhhhhhhhhiiiiiiiiikllllllll]
Date:           [1111111222222233331233211111222222333211111112122222223111112223311122333]
Marks:           |      |      |      |      |      |      |      |      |      |      |
                a,1    a,2    a,3    b,3    e,2    e,3    g,1    h,2    i,1    i,3    l,3
Marks numbers:   0      1      2      3      4      5      6      7      8      9      10
```

Если в запросе к данным указать:

- `CounterID IN ('a', 'h')`, то сервер читает данные в диапазонах засечек `[0, 3)` и `[6, 8)`.
- `CounterID IN ('a', 'h') AND Date = 3`, то сервер читает данные в диапазонах засечек `[1, 3)` и `[7, 8)`.
- `Date = 3`, то сервер читает данные в диапазоне засечек `[1, 10]`.

Примеры выше показывают, что использование индекса всегда эффективнее, чем full scan.

Разреженный индекс допускает чтение лишних строк. При чтении одного диапазона первичного ключа, может быть прочитано до `index_granularity * 2` лишних строк в каждом блоке данных. В большинстве случаев ClickHouse не теряет производительности при `index_granularity = 8192`.

Разреженность индекса позволяет работать даже с очень большим количеством строк в таблицах, поскольку такой индекс всегда помещается в оперативную память компьютера.

ClickHouse не требует уникального первичного ключа. Можно вставить много строк с одинаковым первичным ключом.

### Выбор первичного ключа

Количество столбцов в первичном ключе не ограничено явным образом. В зависимости от структуры данных в первичный ключ можно включать больше или меньше столбцов. Это может:

- Увеличить эффективность индекса.

    Пусть первичный ключ — `(a, b)`, тогда добавление ещё одного столбца `c` повысит эффективность, если выполнены условия:

    - Есть запросы с условием на столбец `c`.
    - Часто встречаются достаточно длинные (в несколько раз больше `index_granularity`) диапазоны данных с одинаковыми значениями `(a, b)`. Иначе говоря, когда добавление ещё одного столбца позволит пропускать достаточно длинные диапазоны данных.

- Улучшить сжатие данных.

    ClickHouse сортирует данные по первичному ключу, поэтому чем выше однородность, тем лучше сжатие.

- Обеспечить дополнительную логику при слиянии кусков данных в движках [CollapsingMergeTree](collapsingmergetree.md#table_engine-collapsingmergetree) и [SummingMergeTree](summingmergetree.md).

    В этом случае имеет смысл задать отдельный *ключ сортировки*, отличающийся от первичного ключа.

Длинный первичный ключ будет негативно влиять на производительность вставки и потребление памяти, однако на производительность ClickHouse при запросах `SELECT` лишние столбцы в первичном ключе не влияют.


### Первичный ключ, отличный от ключа сортировки

Существует возможность задать первичный ключ (выражение, значения которого будут записаны в индексный файл для
каждой засечки), отличный от ключа сортировки (выражения, по которому будут упорядочены строки в кусках
данных). Кортеж выражения первичного ключа при этом должен быть префиксом кортежа выражения ключа
сортировки.

Данная возможность особенно полезна при использовании движков [SummingMergeTree](summingmergetree.md)
и [AggregatingMergeTree](aggregatingmergetree.md). В типичном сценарии использования этих движков таблица
содержит столбцы двух типов: *измерения* (dimensions) и *меры* (measures). Типичные запросы агрегируют
значения столбцов-мер с произвольной группировкой и фильтрацией по измерениям. Так как SummingMergeTree
и AggregatingMergeTree производят фоновую агрегацию строк с одинаковым значением ключа сортировки, приходится
добавлять в него все столбцы-измерения. В результате выражение ключа содержит большой список столбцов,
который приходится постоянно расширять при добавлении новых измерений.

В этом сценарии имеет смысл оставить в первичном ключе всего несколько столбцов, которые обеспечат эффективную
фильтрацию по индексу, а остальные столбцы-измерения добавить в выражение ключа сортировки.

[ALTER ключа сортировки](../../query_language/alter.md) — легкая операция, так как при одновременном добавлении нового столбца в таблицу и ключ сортировки не нужно изменять
данные кусков (они остаются упорядоченными и по новому выражению ключа).

### Использование индексов и партиций в запросах

Для запросов `SELECT` ClickHouse анализирует возможность использования индекса. Индекс может использоваться, если в секции `WHERE/PREWHERE`, в качестве одного из элементов конъюнкции, или целиком, есть выражение, представляющее операции сравнения на равенства, неравенства, а также `IN` или `LIKE` с фиксированным префиксом, над столбцами или выражениями, входящими в первичный ключ или ключ партиционирования, либо над некоторыми частично монотонными функциями от этих столбцов, а также логические связки над такими выражениями.

Таким образом, обеспечивается возможность быстро выполнять запросы по одному или многим диапазонам первичного ключа. Например, в указанном примере будут быстро работать запросы для конкретного счётчика; для конкретного счётчика и диапазона дат; для конкретного счётчика и даты, для нескольких счётчиков и диапазона дат и т. п.

Рассмотрим движок сконфигурированный следующим образом:

```
ENGINE MergeTree() PARTITION BY toYYYYMM(EventDate) ORDER BY (CounterID, EventDate) SETTINGS index_granularity=8192
```

В этом случае в запросах:

``` sql
SELECT count() FROM table WHERE EventDate = toDate(now()) AND CounterID = 34
SELECT count() FROM table WHERE EventDate = toDate(now()) AND (CounterID = 34 OR CounterID = 42)
SELECT count() FROM table WHERE ((EventDate >= toDate('2014-01-01') AND EventDate <= toDate('2014-01-31')) OR EventDate = toDate('2014-05-01')) AND CounterID IN (101500, 731962, 160656) AND (CounterID = 101500 OR EventDate != toDate('2014-05-01'))
```

ClickHouse будет использовать индекс по первичному ключу для отсечения не подходящих данных, а также ключ партиционирования по месяцам для отсечения партиций, которые находятся в не подходящих диапазонах дат.

Запросы выше показывают, что индекс используется даже для сложных выражений. Чтение из таблицы организовано так, что использование индекса не может быть медленнее, чем full scan.

В примере ниже индекс не может использоваться.

``` sql
SELECT count() FROM table WHERE CounterID = 34 OR URL LIKE '%upyachka%'
```

Чтобы проверить, сможет ли ClickHouse использовать индекс при выполнении запроса, используйте настройки [force_index_by_date](../settings/settings.md#settings-force_index_by_date) и [force_primary_key](../settings/settings.md).

Ключ партиционирования по месяцам обеспечивает чтение только тех блоков данных, которые содержат даты из нужного диапазона. При этом блок данных может содержать данные за многие даты (до целого месяца). В пределах одного блока данные упорядочены по первичному ключу, который может не содержать дату в качестве первого столбца. В связи с этим, при использовании запроса с указанием условия только на дату, но не на префикс первичного ключа, будет читаться данных больше, чем за одну дату.

### Дополнительные индексы

Для таблиц семейства `*MergeTree` можно задать дополнительные индексы в секции столбцов.

Индексы аггрегируют для заданного выражения некоторые данные, а потом при `SELECT` запросе используют для пропуска боков данных (пропускаемый блок состоих из гранул данных в количестве равном гранулярности данного индекса), на которых секция `WHERE` не может быть выполнена, тем самым уменьшая объем данных читаемых с диска.

Пример
```sql
CREATE TABLE table_name
(
    u64 UInt64,
    i32 Int32,
    s String,
    ...
    INDEX a (u64 * i32, s) TYPE minmax GRANULARITY 3,
    INDEX b (u64 * length(s), i32) TYPE unique GRANULARITY 4
) ENGINE = MergeTree()
...
```

Эти индексы смогут использоваться для оптимизации следующих запросов
```sql
SELECT count() FROM table WHERE s < 'z'
SELECT count() FROM table WHERE u64 * i32 == 10 AND u64 * length(s) >= 1234
```

#### Доступные индексы

* `minmax`
Хранит минимум и максимум выражения (если выражение - `tuple`, то для каждого элемента `tuple`), используя их для пропуска блоков аналогично первичному ключу.

* `unique(max_rows)`
Хранит уникальные значения выражения на блоке в количестве не более `max_rows`, используя их для пропуска блоков, оценивая выполнимость `WHERE` выражения на хранимых данных.
Если `max_rows=0`, то хранит значения выражения без ограничений. Если параметров не передано, то полагается `max_rows=0`.


Примеры
```sql
INDEX b (u64 * length(str), i32 + f64 * 100, date, str) TYPE minmax GRANULARITY 4
INDEX b (u64 * length(str), i32 + f64 * 100, date, str) TYPE unique GRANULARITY 4
INDEX b (u64 * length(str), i32 + f64 * 100, date, str) TYPE unique(100) GRANULARITY 4
```


## Конкурентный доступ к данным

Для конкурентного доступа к таблице используется мультиверсионность. То есть, при одновременном чтении и обновлении таблицы, данные будут читаться из набора кусочков, актуального на момент запроса. Длинных блокировок нет. Вставки никак не мешают чтениям.

Чтения из таблицы автоматически распараллеливаются.

[Оригинальная статья](https://clickhouse.yandex/docs/ru/operations/table_engines/mergetree/) <!--hide-->
