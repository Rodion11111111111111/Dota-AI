# Подготовка Dota AI к Render

Этот backend можно разместить на Render как Web Service. Gemini API-ключ
размещается только в переменных окружения Render, а не в GitHub и не в APK.

## Что будет нужно при публикации

1. Репозиторий проекта на GitHub. Файл `.env` туда не добавлять.
2. В Render: `New` → `Web Service` → выбрать репозиторий.
3. Указать `Root Directory`: `servernaya_chast`.
4. Выбрать окружение Docker и указать путь к Dockerfile: `nastroika_docker`.
5. Добавить в Render переменные окружения:

   ```text
   GEMINI_API_KEY=ваш_настоящий_ключ_Gemini
   GEMINI_MODEL=gemini-3.6-flash
   DOTA_AI_ACCESS_KEY=длинный_секрет_для_вашего_приложения
   ```

   `PORT` вручную добавлять не нужно: его устанавливает Render.

6. Указать Health Check Path: `/health`.
7. После публикации Render даст адрес вида
   `https://nazvanie-servera.onrender.com`.

## Сборка APK для Render

После появления адреса Render собрать APK с параметрами:

```powershell
C:\development\flutter\bin\flutter.bat build apk --debug `
  --dart-define=AI_SERVER_URL=https://nazvanie-servera.onrender.com `
  --dart-define=AI_ACCESS_KEY=длинный_секрет_для_вашего_приложения
```

`AI_ACCESS_KEY` не является ключом Gemini. Он нужен, чтобы посторонний
пользователь не мог просто так обращаться к вашему backend. Он находится в
APK, поэтому это защита для личного приложения, а не полноценная авторизация.

## Ограничения бесплатного тарифа Render

Бесплатный Web Service останавливается после 15 минут без входящих запросов.
Первый запрос после остановки может ждать примерно минуту. Для постоянной
работы без ожидания потребуется платный тариф.
