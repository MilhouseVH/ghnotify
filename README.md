ghnotify
========

Sends an automatic summary email of all new commits and/or pull requests for Github repository branches that you wish to monitor. This script is especially useful when monitoring infrequently updated repositories, saving you the time of manually checking for updates.

Configure the repositories to be monitored in `~/ghnotify.conf` (owner, repository and branch, plus a "display" name that will appear in the email) :

######Example:
```
#owner/repository/branch        display name
MilhouseVH/ghnotify/master      GitHub Notify (master)
raspberrypi/firmware/master     Raspberry Pi Firmware (master)
raspberrypi/linux/rpi-3.15.y    Raspberry Pi Linux (3.15.y)
OpenELEC/OpenELEC.tv/master     OpenELEC (master)
xbmc/xbmc/master                XBMC (master)
popcornmix/xbmc/newclock3       Popcornmix (newclock3)
Pulse-Eight/libcec/master       libcec (master)
sahlberg/libnfs/master          libnfs (master)
```

Including the ghnotify repository is a handy way to be notified of any updates!

Github authentication is necessary to bypass [GitHub rate limiting](https://developer.github.com/v3/rate_limit/). If you don't plan on running this script very often, eg. one or twice an hour, then it may not be necessary to include authentication.

If you exceeded the hourly data access limit, configure your github username and password in `~/.git.conf` to enable much greater limits:
```
GIT_USERNAME="your_username"
GIT_PASSWORD="your_password"
```

A suitable email address will be determined from the MAILTO= property in /etc/crontab (if available), otherwise configure your "to" email address in `~/.git.conf`:
```
EMAILTO="your.email@address.com"
```

The `~/.git.conf` file is not required if you don't require authentication and your email address can be determined automatically.

Whenever the script is run succesfully, it will record the latest commit SHA for each monitored repository in `~/ghnotify.commits`, and the latest pull request number in `~/ghnotify.pulls`.

The script has been tested with the msmtp MTA. Other MTAs may work (eg. sendmail, ssmtp) but are untested - patches welcome.

##Arguments

When run with no arguments, both commits and pulls will be processed, and an email will be sent to the configured email address.

`debug` - see Debugging section below  
`diags` - view web equest/response/result details  
`noemail` - don't send the email (create email.html instead)  
`commits` - process only commits  
`pulls` - process only pull requests  

Specifying `commits` or `pulls` might be useful if you want to be notified of commits often (eg. scheduling the script to run every 30 minutes) but only want to be notified of pull rquests once or twice a day, in which case create two cron entries, one for commits and one for pulls. Otherwise commit and pull request notifications will be sent in the same email.

##Debugging

Interactively run the script with the `noemail` parameter to avoid sending an email, and instead a file called `email.html` will be created which can be loaded in your web browser. The `ghnotify.dat` file will not be updated unless an email is sent successfully.

Use the `debug` option to output additional information. Data for each repository/branch that has at least one commit or pull request will be dumped into a file prefixed with `dbg_commits_` or `dbg_pulls_` for subsequent analysis. `debug` implies `noemail`.

When run without any parameters, an email will be sent only if there has been at least one new commit or pull request.

##Dependencies

If it is not already installed on your system, you will need to install the `qprint` utility (`apt-get install qprint`) to encode quoted-printable text.

You will require a Mail Transfer Agent, configured with your email account details. The script has been tested with `msmtp`.

`python` (v2.7+) and `curl` are required.

The script does *not* require the `git` utility to be installed - it communicates with github.com using the GitHub web services API.

##Sample Output

![sample](http://i225.photobucket.com/albums/dd119/MilhouseVH/ghnotify_zpsb0448750.png)
