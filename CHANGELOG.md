#Changelog

##Version 0.1.3 (17/08/2014)
* Fix: Bug

##Version 0.1.2 (17/08/2014)
* Add: Support pull requests.

##Version 0.1.1 (13/08/2014)
* Chg: Use full sha rather than first 7 chars when performing comparison, to avoid collisions.

##Version 0.1.0 (10/08/2014)
* Add: Include summary of updated repos in header

##Version 0.0.9 (04/08/2014)
* Add: Support pull request links in commit descriptions

##Version 0.0.8 (01/08/2014)
* Fix: Support UTF-8 encoding of usernames containing non-ASCII characters

##Version 0.0.7 (31/07/2014)
* Chg: Use UTC date when calculating time deltas
* Add: Extra debugging for `debug` option (more output, dumping data into dbg* files, not sending email). Change original `debug` option to `noemail`.

##Version 0.0.6 (29/07/2014)
* Fix: Author/commit dates more than 30 days ago, or in a different year, need their own format
* Chg: Disable gravatar support, seems to be a bit flakey

##Version 0.0.5 (29/07/2014)
* Chg: Default location for ghnotify.conf and ghnotify.dat is now ~, ie. `~/ghnotify.conf`. If not found in ~, then look in script directory.

##Version 0.0.4 (28/07/2014)
* Chg: Eliminate dependency on external HTML template files, now included inside main script
* Chg: Determine default EMAILTO address from /etc/crontab MAILTO property. Overridden by ~/.git.conf if loaded and EMAILTO is present.
* Fix: Update gravatar handling due to recent github backend changes.

##Version 0.0.3 (27/07/2014)
* Chg: HTML sanitise all input/output fields

##Version 0.0.2 (27/07/2014)
* Add: Include script summary (processed #, unavailable #, unavailable repos) in footer

##Version 0.0.1 (26/07/2014)
* Initial release
