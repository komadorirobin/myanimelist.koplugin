# MyAnimeList Manga Sync for KOReader

Synchronizes manga volumes marked as finished in KOReader or Bookshelf with
the corresponding manga entry on MyAnimeList.

## Behavior

- A local volume marked `complete` updates `num_volumes_read` on MyAnimeList.
- The remote status becomes `reading`, or `completed` when the known final
  volume is reached.
- Progress never decreases automatically. Remote progress, previously synced
  progress and queued local progress are merged using the highest value.
- Failed updates remain in a persistent queue and can be retried later.
- Series are linked once through a MyAnimeList search. Unlinked finished
  series are collected under **Link pending manga**.
- KOReader's regular status controls, SimpleUI status controls and Bookshelf's
  own edit dialog are supported.

## Setup

1. Install `myanimelist.koplugin` in `koreader/plugins/` and restart KOReader.
2. Create an API client at <https://myanimelist.net/apiconfig/create>.
3. In **Tools > MyAnimeList Manga Sync > Account**, enter its client ID,
   optional client secret and exact redirect URI.
4. Choose **Start authorization**, approve access in the browser, return to
   KOReader, then choose **Finish authorization** and paste the callback URL
   or its `code` value.
5. Mark a manga volume finished. Link the series when prompted.

The default manga root is `/storage/emulated/0/ePubs/Manga` and can be changed
in the plugin menu. OAuth tokens are stored in KOReader's settings file, like
credentials used by other KOReader synchronization plugins.

## OTA updates

Use **Tools > MyAnimeList Manga Sync > Check for plugin update**. Stable
releases include a `myanimelist.koplugin.zip` asset that the plugin installs
directly.

## API

The plugin uses the official [MyAnimeList API v2](https://myanimelist.net/apiconfig/references/api/v2),
including `PUT /manga/{id}/my_list_status` with `num_volumes_read`.
