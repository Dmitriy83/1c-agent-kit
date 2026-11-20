# Поставляемые элементы справочников: начальное заполнение БСП

Как поставить в справочник или план видов характеристик элементы, на которые опирается код (виды начислений,
виды контактной информации, причины, статусы), и как получать их в коде. Сверено по исходникам ERP WE 2.5.27
(БСП 3.1): `InfobaseUpdate`, `InfobaseUpdateInternal`, `InfobaseUpdateOverridable`, справочники
`ContactInformationKinds`, `GoodsLockReasons`. Русские имена даны в скобках.

## Как не надо

- **Предопределенные элементы метаданных** для новых поставляемых данных в современных типовых почти не
  используются: они остались как наследие (например `AccrualAndDeductionKinds.Wage`). Новые типовые справочники
  описывают поставляемые элементы кодом.
- **Жестко заданный UUID** (`Catalogs.X.GetRef(New UUID("..."))`) не читается, а при отсутствии элемента молча дает
  битую ссылку `<Объект не найден>`, и код работает дальше с ней.

## Механизм

1. **Объект регистрируется** как объект с начальным заполнением: `OnDefineObjectsWithInitialFilling(Objects)`
   (`ПриОпределенииОбъектовСНачальнымЗаполнением`) подсистемы или список `Objects` в
   `InfobaseUpdateOverridable.OnDefineSettings`. Многие типовые справочники там уже есть (в ERP WE, например,
   `AccrualAndDeductionKinds`, `TaxContributionKinds`): проверить до регистрации.
2. **Настройка в модуле менеджера** `OnSetUpInitialItemsFilling(Settings)`
   (`ПриНастройкеНачальногоЗаполненияЭлементов`): `Settings.OnInitialItemFilling` (вызывать ли обработчик на
   каждый элемент) и `Settings.KeyAttributeName` (`ИмяКлючевогоРеквизита`). По умолчанию ключ
   `PredefinedDataName`; для элементов без предопределенных данных метаданных ключом служит обычный строковый
   реквизит, например `ContactInformationKinds.PredefinedKindName` (`ИмяПредопределенногоВида`).
3. **Описание элементов** в `OnInitialItemsFilling(LanguagesCodes, Items, TabularSections)`
   (`ПриНачальномЗаполненииЭлементов`): строка таблицы `Items` на элемент, колонки по реквизитам объекта, ключ,
   наименование через `NStr(..., Common.DefaultLanguageCode())`. Необязательная колонка `Ref` задает
   фиксированную ссылку, если она нужна для совместимости с уже созданными элементами.
   `OnInitialItemFilling(Object, Data, AdditionalParameters)` (`ПриНачальномЗаполненииЭлемента`) дописывает то,
   что не выражается таблицей.
4. **Создание и обновление.** В новой базе БСП заполняет элементы при первом запуске. Для существующих баз
   добавляется отложенный обработчик обновления, как в `GoodsLockReasons`:
   `Handler.Procedure = "Catalogs.X.FillItemsWithInitialData"`,
   `Handler.UpdateDataFillingProcedure = "Catalogs.X.RegisterPredefinedItemsToUpdate"`,
   `Handler.CheckProcedure = "InfobaseUpdate.DataUpdatedForNewApplicationVersion"`, объекты чтения, изменения и
   блокировки; внутри вызовы `InfobaseUpdate.RegisterPredefinedItemsToUpdate(Parameters, Metadata.Catalogs.X)`
   (`ЗарегистрироватьПредопределенныеЭлементыДляОбновления`) и
   `InfobaseUpdate.FillItemsWithInitialData(Parameters, Metadata.Catalogs.X)`
   (`ЗаполнитьЭлементыНачальнымиДанными`). Существующий элемент БСП находит сначала по `PredefinedDataName`,
   затем по ключевому реквизиту, и обновляет его, иначе создает новый.
5. **Получение в коде** по имени-ключу, а не по UUID: функция с кешем соответствия "имя -> ссылка" в модуле
   повторного использования, как `ContactsManager.ContactInformationKindByName` и
   `ContactsManagerInternalCached.ContactInformationKindsByName`. Если элемента нет, функция сообщает понятную
   ошибку. В тексте запроса ссылка передается параметром.

## В расширении для типового справочника

- Ключевой реквизит добавить в заимствованный справочник с префиксом расширения (`erlSuppliedName`).
- `OnSetUpInitialItemsFilling` и `OnInitialItemsFilling` модуля менеджера заимствовать и дополнить через `&After`:
  дописать свои строки в `Items`, ключ переключать только проверив, что типовые элементы по-прежнему находятся
  (БСП сначала ищет по `PredefinedDataName`). Для библиотечных объектов, которые нельзя менять, есть
  `InfobaseUpdateOverridable.OnSetUpInitialItemsFilling` и `OnInitialItemsFilling` с параметром `FullObjectName`.
- Обработчик обновления регистрируется в обработчиках расширения со своей версией и UUID.

## Проверка

- Новая пустая база: элементы созданы, ключ заполнен, повторный запуск не дублирует.
- Существующая база со старыми элементами: элементы сопоставлены (по `Ref` или ключу), а не созданы заново.
- Пользователь изменил наименование: обновление ведет себя по `UpdateMode` (`All`, `NewAndChanged`,
  `MultilingualStrings`), это выбирается сознательно.
