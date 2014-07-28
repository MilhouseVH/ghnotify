#Changelog

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
