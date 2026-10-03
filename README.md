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
- Manga series can also be linked directly from Bookshelf: long-press a folder
  below the configured manga root and choose **Link folder to MyAnimeList...**.
  Long-pressing an already linked folder opens its existing link settings.
- A compact cached `★8.72`-style series rating is shown on linked Bookshelf folder
  cards. New links cache it immediately; **Refresh MAL ratings** updates all
  existing links. Opening the shelf never performs a network request.
- Linking a series scans its local folder for volumes that were already marked
  finished. The highest finished volume is queued immediately, so an existing
  MAL entry can move from (for example) 3/30 to 21/30 without opening the
  volumes again. Manually linked folders remain authoritative even when their
  EPUB series names differ. The scan can also be run manually per linked series.
- KOReader's regular status controls, SimpleUI status controls and Bookshelf's
  own edit dialog are supported.
- Automatic status updates honor the explicitly linked Bookshelf folder even
  when an EPUB contains a different or localized series name.
- A linked series can be marked as an omnibus edition. Its local volume number
  is multiplied by the configured number of original volumes and capped at
  MAL's official total. A 3-in-1 volume 4 therefore updates MAL to volume 12.
  A final partial omnibus or standalone volume safely lands on the official
  final volume instead of exceeding it.
- Omnibus editions with uneven mappings can instead use a cumulative ratio.
  For example, every 2 local deluxe volumes can map to 5 MAL volumes, while a
  6-volume Master Edition can map to MAL's 10 original volumes. Partial
  progress is always rounded down so MAL progress is never overstated.

## Setup

1. Install `myanimelist.koplugin` in `koreader/plugins/` and restart KOReader.
2. Create an API client at <https://myanimelist.net/apiconfig/create>.
3. In **Tools > MyAnimeList Manga Sync > Account**, enter its client ID,
   optional client secret and exact redirect URI.
4. Choose **Start authorization**, approve access in the browser, return to
   KOReader, then choose **Finish authorization** and paste the callback URL
   or its `code` value.
5. Mark a manga volume finished and link the series when prompted, or
   long-press its folder in Bookshelf and link it before reading.

Use **Scan finished volumes** in the plugin menu to repeat the local scan for
any linked series. Scans run in small UI batches and only inspect the matched
series folder; they do not scan the full library or reduce MAL progress.

Open **Linked series**, select a series and enable **This local series uses
omnibus editions**. Choose either a fixed number of original MAL volumes per
local file or a custom local-to-MAL ratio for uneven editions. The same
conversion applies to newly finished books and scans of books that were
already finished. Existing omnibus links continue to use their fixed count.

The default manga root is `/storage/emulated/0/ePubs/Manga` and can be changed
in the plugin menu. OAuth tokens are stored in KOReader's settings file, like
credentials used by other KOReader synchronization plugins.

## Authorization recovery (1.5.2)

Search, rating refresh and reading-progress sync share token renewal. They renew
an expired access token before sending a request and retry an unexpected
`invalid_token`/HTTP 401 response at most once. Rotated credentials are saved
even when the following API request fails. Account jobs are serialized across
FileManager and ReaderUI so overlapping operations cannot rotate tokens at the
same time.

The Account menu reports **token renewal pending** for expired credentials and
**authorization required** when MAL rejects renewal. A saved **connected** state
is not a live server check; requests validate it. Network errors and rate limits
do not erase credentials, linked series or pending updates.

If renewal is rejected, use **Account > Start authorization**, then
**Finish authorization** again. There is no need to unlink series or reinstall
the plugin. Correct the API client settings first if those have changed.
This also provides a workaround for older versions whose searches do not renew
tokens. See [MAL's authorization reference](https://myanimelist.net/apiconfig/references/authorization#refreshing-an-access-token).

## OTA updates

Use **Tools > MyAnimeList Manga Sync > Check for plugin update**. Stable
releases include a `myanimelist.koplugin.zip` asset that the plugin installs
directly.

## API

The plugin uses the official [MyAnimeList API v2](https://myanimelist.net/apiconfig/references/api/v2),
including `PUT /manga/{id}/my_list_status` with `num_volumes_read`.
