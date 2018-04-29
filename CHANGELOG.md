# Changelog

## Version 0.2.3 (29/04/2018)
* Fix: tag url
* Fix: utf-8 encoding
* Fix: improve git recovery when history is rewritten

## Version 0.2.2 (07/12/2017)
* Add: Support notification of new tags (releases)

## Version 0.2.1 (25/09/2017)
* Add: Support git repositories via local clones

## Version 0.2.0 (27/06/2017)
* Chg: Switch multithreaded processing

## Version 0.1.9 (15/12/2015)
* Add: Minimal url escaping to workaround branch names such as K+++

## Version 0.1.8 (18/04/2015)
* Chg: Revert connect timeout to 30 seconds, now retry 6 times instead

## Version 0.1.7 (18/04/2015)
* Chg: Centralise web requests
* Chg: Add --location option to curl and follow github redirects
* Chg: Increase curl connect timeout to 60 seconds
* Add: View request/response/result with `diags` option

## Version 0.1.6 (07/02/2015)
* Fix: Avoid processing pull requests for the same repo multiple times when different branches are configured - just ignore subsequent branches.

## Version 0.1.5 (20/09/2014)
* Fix: Ensure commit and pull details for newly added repositories are added to control files
* Fix: Store 0 as last pull request when no pull requests are available

## Version 0.1.4 (07/09/2014)
* Fix: Failure to display email in Sailfish email viewer

## Version 0.1.3 (17/08/2014)
* Fix: Bug

## Version 0.1.2 (17/08/2014)
* Add: Support pull requests.

## Version 0.1.1 (13/08/2014)
* Chg: Use full sha rather than first 7 chars when performing comparison, to avoid collisions.

## Version 0.1.0 (10/08/2014)
* Add: Include summary of updated repos in header

## Version 0.0.9 (04/08/2014)
* Add: Support pull request links in commit descriptions

## Version 0.0.8 (01/08/2014)
* Fix: Support UTF-8 encoding of usernames containing non-ASCII characters

## Version 0.0.7 (31/07/2014)
* Chg: Use UTC date when calculating time deltas
* Add: Extra debugging for `debug` option (more output, dumping data into dbg* files, not sending email). Change original `debug` option to `noemail`.

## Version 0.0.6 (29/07/2014)
* Fix: Author/commit dates more than 30 days ago, or in a different year, need their own format
* Chg: Disable gravatar support, seems to be a bit flakey

## Version 0.0.5 (29/07/2014)
* Chg: Default location for ghnotify.conf and ghnotify.dat is now ~, ie. `~/ghnotify.conf`. If not found in ~, then look in script directory.

## Version 0.0.4 (28/07/2014)
* Chg: Eliminate dependency on external HTML template files, now included inside main script
* Chg: Determine default EMAILTO address from /etc/crontab MAILTO property. Overridden by ~/.git.conf if loaded and EMAILTO is present.
* Fix: Update gravatar handling due to recent github backend changes.

## Version 0.0.3 (27/07/2014)
* Chg: HTML sanitise all input/output fields

## Version 0.0.2 (27/07/2014)
* Add: Include script summary (processed #, unavailable #, unavailable repos) in footer

## Version 0.0.1 (26/07/2014)
* Initial release
