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
- Linking a series scans its local folder for volumes that were already marked
  finished. The highest finished volume is queued immediately, so an existing
  MAL entry can move from (for example) 3/30 to 21/30 without opening the
  volumes again. The scan can also be run manually per linked series.
- KOReader's regular status controls, SimpleUI status controls and Bookshelf's
  own edit dialog are supported.
- A linked series can be marked as an omnibus edition. Its local volume number
  is multiplied by the configured number of original volumes and capped at
  MAL's official total. A 3-in-1 volume 4 therefore updates MAL to volume 12.
  A final partial omnibus or standalone volume safely lands on the official
  final volume instead of exceeding it.

## Setup

1. Install `myanimelist.koplugin` in `koreader/plugins/` and restart KOReader.
2. Create an API client at <https://myanimelist.net/apiconfig/create>.
3. In **Tools > MyAnimeList Manga Sync > Account**, enter its client ID,
   optional client secret and exact redirect URI.
4. Choose **Start authorization**, approve access in the browser, return to
   KOReader, then choose **Finish authorization** and paste the callback URL
   or its `code` value.
5. Mark a manga volume finished. Link the series when prompted.

Use **Scan finished volumes** in the plugin menu to repeat the local scan for
any linked series. Scans run in small UI batches and only inspect the matched
series folder; they do not scan the full library or reduce MAL progress.

Open **Linked series**, select a series and enable **This local series uses
omnibus editions** to configure how many original MAL volumes each local file
contains. The same conversion applies to newly finished books and scans of
books that were already finished.

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
